use std::fmt;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::tools::ResolvedVirtiofsd;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum NetworkMode {
    Passt,
    User,
    Off,
}

impl NetworkMode {
    fn qemu_args(self) -> &'static [&'static str] {
        match self {
            Self::Passt => &[
                "-netdev",
                "passt,id=net0",
                "-device",
                "virtio-net-pci,netdev=net0",
            ],
            Self::User => &[
                "-netdev",
                "user,id=net0",
                "-device",
                "virtio-net-pci,netdev=net0",
            ],
            Self::Off => &[],
        }
    }
}

impl fmt::Display for NetworkMode {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let label = match self {
            Self::Passt => "passt",
            Self::User => "user",
            Self::Off => "off",
        };
        write!(f, "{label}")
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RuntimeArtifacts {
    pub kernel: PathBuf,
    pub initrd: PathBuf,
    pub rootfs: PathBuf,
}

impl RuntimeArtifacts {
    pub fn from_runtime_dir(runtime_dir: impl AsRef<Path>) -> Self {
        let runtime_dir = runtime_dir.as_ref();
        Self {
            kernel: runtime_dir.join("vmlinuz"),
            initrd: runtime_dir.join("initrd"),
            rootfs: runtime_dir.join("rootfs.img"),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SharePlan {
    pub name: &'static str,
    pub tag: &'static str,
    pub source: PathBuf,
    pub socket: PathBuf,
    pub log: PathBuf,
    pub virtiofsd: ResolvedVirtiofsd,
}

impl SharePlan {
    pub fn virtiofsd_command(&self) -> (String, Vec<String>) {
        self.virtiofsd.command(&self.socket, &self.source)
    }

    fn qemu_chardev_arg(&self) -> String {
        format!(
            "socket,id=char-{},path={}",
            self.name,
            self.socket.display()
        )
    }

    fn qemu_device_arg(&self) -> String {
        format!(
            "vhost-user-fs-pci,chardev=char-{},tag={}",
            self.name, self.tag
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchConfig {
    pub artifacts: RuntimeArtifacts,
    pub virtiofsd: ResolvedVirtiofsd,
    pub workspace: PathBuf,
    pub cache_dir: PathBuf,
    pub tools_dir: PathBuf,
    pub run_dir: PathBuf,
    pub guest_cid: u32,
    pub cpus: u16,
    pub memory_mib: u32,
    pub network: NetworkMode,
    pub epoch: i64,
    pub guest_workspace: String,
}

impl LaunchConfig {
    pub fn new(
        artifacts: RuntimeArtifacts,
        workspace: impl Into<PathBuf>,
        cache_dir: impl Into<PathBuf>,
        tools_dir: impl Into<PathBuf>,
        run_dir: impl Into<PathBuf>,
        epoch: i64,
    ) -> Self {
        Self {
            artifacts,
            virtiofsd: ResolvedVirtiofsd::direct("virtiofsd"),
            workspace: workspace.into(),
            cache_dir: cache_dir.into(),
            tools_dir: tools_dir.into(),
            run_dir: run_dir.into(),
            guest_cid: 42,
            cpus: 2,
            memory_mib: 2048,
            network: NetworkMode::Passt,
            epoch,
            guest_workspace: "/workspace".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LaunchPlan {
    pub qemu_program: &'static str,
    pub qemu_args: Vec<String>,
    pub shares: Vec<SharePlan>,
    pub kernel_cmdline: String,
    pub run_dir: PathBuf,
    pub log_dir: PathBuf,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlanError {
    InvalidCpus(u16),
    InvalidMemoryMiB(u32),
    InvalidGuestCid(u32),
    EmptyGuestWorkspace,
}

impl fmt::Display for PlanError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidCpus(cpus) => write!(f, "QEMU CPU count must be positive, got {cpus}"),
            Self::InvalidMemoryMiB(memory) => {
                write!(f, "QEMU memory must be positive, got {memory} MiB")
            }
            Self::InvalidGuestCid(cid) => {
                write!(f, "QEMU guest CID must be greater than 2, got {cid}")
            }
            Self::EmptyGuestWorkspace => write!(f, "guest workspace path cannot be empty"),
        }
    }
}

impl std::error::Error for PlanError {}

pub fn build_launch_plan(config: &LaunchConfig) -> Result<LaunchPlan, PlanError> {
    validate(config)?;

    let log_dir = config.run_dir.join("logs");
    let shares = vec![
        share(
            "workspace",
            "workspace",
            &config.workspace,
            &config.run_dir,
            &log_dir,
            &config.virtiofsd,
        ),
        share(
            "cache",
            "cache",
            &config.cache_dir,
            &config.run_dir,
            &log_dir,
            &config.virtiofsd,
        ),
        share(
            "tools",
            "tools",
            &config.tools_dir,
            &config.run_dir,
            &log_dir,
            &config.virtiofsd,
        ),
    ];
    let kernel_cmdline = kernel_cmdline(config.epoch, &config.guest_workspace);

    let mut args = vec![
        "-machine".to_string(),
        "q35,accel=kvm".to_string(),
        "-cpu".to_string(),
        "host".to_string(),
        "-smp".to_string(),
        config.cpus.to_string(),
        "-m".to_string(),
        config.memory_mib.to_string(),
        "-object".to_string(),
        format!(
            "memory-backend-memfd,id=mem,size={}M,share=on",
            config.memory_mib
        ),
        "-numa".to_string(),
        "node,memdev=mem".to_string(),
        "-kernel".to_string(),
        config.artifacts.kernel.display().to_string(),
        "-initrd".to_string(),
        config.artifacts.initrd.display().to_string(),
        "-append".to_string(),
        kernel_cmdline.clone(),
        "-drive".to_string(),
        format!(
            "file={},if=virtio,format=raw,cache=writeback",
            config.artifacts.rootfs.display()
        ),
        "-snapshot".to_string(),
        "-device".to_string(),
        format!(
            "vhost-vsock-pci,id=fend-vsock,guest-cid={}",
            config.guest_cid
        ),
    ];

    for share in &shares {
        args.extend([
            "-chardev".to_string(),
            share.qemu_chardev_arg(),
            "-device".to_string(),
            share.qemu_device_arg(),
        ]);
    }

    args.extend(
        config
            .network
            .qemu_args()
            .iter()
            .map(|arg| (*arg).to_string()),
    );
    args.extend([
        "-nographic".to_string(),
        "-serial".to_string(),
        "mon:stdio".to_string(),
        "-no-reboot".to_string(),
    ]);

    Ok(LaunchPlan {
        qemu_program: "qemu-system-x86_64",
        qemu_args: args,
        shares,
        kernel_cmdline,
        run_dir: config.run_dir.clone(),
        log_dir,
    })
}

fn kernel_cmdline(epoch: i64, guest_workspace: &str) -> String {
    format!(
        "console=ttyS0 root=/dev/vda rootwait rw init=/usr/local/bin/fendd quiet fend.epoch={epoch} fend.cwd={}",
        base64(guest_workspace.as_bytes())
    )
}

fn validate(config: &LaunchConfig) -> Result<(), PlanError> {
    if config.cpus == 0 {
        return Err(PlanError::InvalidCpus(config.cpus));
    }
    if config.memory_mib == 0 {
        return Err(PlanError::InvalidMemoryMiB(config.memory_mib));
    }
    if config.guest_cid <= 2 {
        return Err(PlanError::InvalidGuestCid(config.guest_cid));
    }
    if config.guest_workspace.is_empty() {
        return Err(PlanError::EmptyGuestWorkspace);
    }
    Ok(())
}

fn share(
    name: &'static str,
    tag: &'static str,
    source: &Path,
    run_dir: &Path,
    log_dir: &Path,
    virtiofsd: &ResolvedVirtiofsd,
) -> SharePlan {
    SharePlan {
        name,
        tag,
        source: source.to_path_buf(),
        socket: run_dir.join(format!("{name}.sock")),
        log: log_dir.join(format!("virtiofsd-{name}.log")),
        virtiofsd: virtiofsd.clone(),
    }
}

fn base64(input: &[u8]) -> String {
    const TABLE: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);

    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;

        out.push(TABLE[((n >> 18) & 0x3f) as usize] as char);
        out.push(TABLE[((n >> 12) & 0x3f) as usize] as char);
        out.push(if chunk.len() > 1 {
            TABLE[((n >> 6) & 0x3f) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            TABLE[(n & 0x3f) as usize] as char
        } else {
            '='
        });
    }

    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn launch_plan_matches_spike_command_shape() {
        let plan = build_launch_plan(&sample_config(NetworkMode::Passt)).unwrap();

        assert_eq!(plan.qemu_program, "qemu-system-x86_64");
        assert_eq!(plan.run_dir, PathBuf::from("/tmp/fend run"));
        assert_eq!(plan.log_dir, PathBuf::from("/tmp/fend run/logs"));
        assert_eq!(
            plan.kernel_cmdline,
            "console=ttyS0 root=/dev/vda rootwait rw init=/usr/local/bin/fendd quiet fend.epoch=12345 fend.cwd=L3dvcmtzcGFjZQ=="
        );

        assert_eq!(
            plan.shares.iter().map(|s| s.name).collect::<Vec<_>>(),
            ["workspace", "cache", "tools"]
        );
        assert_eq!(
            plan.shares[0].socket,
            PathBuf::from("/tmp/fend run/workspace.sock")
        );
        assert_eq!(
            plan.shares[0].log,
            PathBuf::from("/tmp/fend run/logs/virtiofsd-workspace.log")
        );
        assert_eq!(plan.shares[0].virtiofsd.path, PathBuf::from("virtiofsd"));
        assert_eq!(
            plan.shares[0].virtiofsd_command(),
            (
                "virtiofsd".to_string(),
                vec![
                    "--socket-path=/tmp/fend run/workspace.sock".to_string(),
                    "--cache=auto".to_string(),
                    "-o".to_string(),
                    "source=/home/pawel/project with spaces".to_string(),
                ]
            )
        );

        assert_eq!(
            plan.qemu_args,
            [
                "-machine",
                "q35,accel=kvm",
                "-cpu",
                "host",
                "-smp",
                "4",
                "-m",
                "4096",
                "-object",
                "memory-backend-memfd,id=mem,size=4096M,share=on",
                "-numa",
                "node,memdev=mem",
                "-kernel",
                "/home/pawel/.fend/runtime/linux-x86_64/vmlinuz",
                "-initrd",
                "/home/pawel/.fend/runtime/linux-x86_64/initrd",
                "-append",
                &plan.kernel_cmdline,
                "-drive",
                "file=/home/pawel/.fend/runtime/linux-x86_64/rootfs.img,if=virtio,format=raw,cache=writeback",
                "-snapshot",
                "-device",
                "vhost-vsock-pci,id=fend-vsock,guest-cid=42",
                "-chardev",
                "socket,id=char-workspace,path=/tmp/fend run/workspace.sock",
                "-device",
                "vhost-user-fs-pci,chardev=char-workspace,tag=workspace",
                "-chardev",
                "socket,id=char-cache,path=/tmp/fend run/cache.sock",
                "-device",
                "vhost-user-fs-pci,chardev=char-cache,tag=cache",
                "-chardev",
                "socket,id=char-tools,path=/tmp/fend run/tools.sock",
                "-device",
                "vhost-user-fs-pci,chardev=char-tools,tag=tools",
                "-netdev",
                "passt,id=net0",
                "-device",
                "virtio-net-pci,netdev=net0",
                "-nographic",
                "-serial",
                "mon:stdio",
                "-no-reboot"
            ]
        );
    }

    #[test]
    fn network_modes_change_qemu_args() {
        let passt = build_launch_plan(&sample_config(NetworkMode::Passt)).unwrap();
        assert!(passt.qemu_args.contains(&"passt,id=net0".to_string()));

        let user = build_launch_plan(&sample_config(NetworkMode::User)).unwrap();
        assert!(user.qemu_args.contains(&"user,id=net0".to_string()));
        assert!(!user.qemu_args.contains(&"passt,id=net0".to_string()));

        let off = build_launch_plan(&sample_config(NetworkMode::Off)).unwrap();
        assert!(!off.qemu_args.contains(&"passt,id=net0".to_string()));
        assert!(!off.qemu_args.contains(&"user,id=net0".to_string()));
        assert!(!off
            .qemu_args
            .contains(&"virtio-net-pci,netdev=net0".to_string()));
    }

    #[test]
    fn kernel_command_line_base64_encodes_guest_workspace() {
        assert_eq!(
            kernel_cmdline(7, "/workspace/project a"),
            "console=ttyS0 root=/dev/vda rootwait rw init=/usr/local/bin/fendd quiet fend.epoch=7 fend.cwd=L3dvcmtzcGFjZS9wcm9qZWN0IGE="
        );
    }

    #[test]
    fn validation_rejects_invalid_values() {
        let mut config = sample_config(NetworkMode::Passt);

        config.guest_cid = 2;
        assert_eq!(
            build_launch_plan(&config).unwrap_err(),
            PlanError::InvalidGuestCid(2)
        );

        config = sample_config(NetworkMode::Passt);
        config.cpus = 0;
        assert_eq!(
            build_launch_plan(&config).unwrap_err(),
            PlanError::InvalidCpus(0)
        );

        config = sample_config(NetworkMode::Passt);
        config.memory_mib = 0;
        assert_eq!(
            build_launch_plan(&config).unwrap_err(),
            PlanError::InvalidMemoryMiB(0)
        );

        config = sample_config(NetworkMode::Passt);
        config.guest_workspace.clear();
        assert_eq!(
            build_launch_plan(&config).unwrap_err(),
            PlanError::EmptyGuestWorkspace
        );
    }

    #[test]
    fn arch_style_virtiofsd_uses_unshare_wrapper() {
        let mut config = sample_config(NetworkMode::Off);
        config.virtiofsd = ResolvedVirtiofsd {
            path: PathBuf::from("/usr/lib/virtiofsd"),
            mode: crate::tools::VirtiofsdMode::RootlessUnshare,
        };

        let plan = build_launch_plan(&config).unwrap();

        assert_eq!(
            plan.shares[0].virtiofsd_command(),
            (
                "unshare".to_string(),
                vec![
                    "-r".to_string(),
                    "--map-auto".to_string(),
                    "--".to_string(),
                    "/usr/lib/virtiofsd".to_string(),
                    "--socket-path=/tmp/fend run/workspace.sock".to_string(),
                    "--shared-dir".to_string(),
                    "/home/pawel/project with spaces".to_string(),
                    "--sandbox".to_string(),
                    "chroot".to_string(),
                ]
            )
        );
    }

    fn sample_config(network: NetworkMode) -> LaunchConfig {
        let runtime = PathBuf::from("/home/pawel/.fend/runtime/linux-x86_64");
        let mut config = LaunchConfig::new(
            RuntimeArtifacts::from_runtime_dir(runtime),
            "/home/pawel/project with spaces",
            "/home/pawel/.fend/cache/npm",
            "/home/pawel/.fend/tools",
            "/tmp/fend run",
            12345,
        );
        config.guest_cid = 42;
        config.cpus = 4;
        config.memory_mib = 4096;
        config.network = network;
        config
    }
}
