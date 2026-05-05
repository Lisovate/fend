use std::env;
use std::fs::{File, OpenOptions};
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::qemu::{NetworkMode, RuntimeArtifacts};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceStatus {
    pub path: PathBuf,
    pub exists: bool,
    pub readable: bool,
    pub writable: bool,
}

impl DeviceStatus {
    pub fn label(&self) -> String {
        if !self.exists {
            return "missing".to_string();
        }
        if self.readable && self.writable {
            return self.path.display().to_string();
        }
        "permission denied".to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostProbe {
    pub os: String,
    pub arch: String,
    pub runtime_dir: PathBuf,
    pub kernel_exists: bool,
    pub initrd_exists: bool,
    pub rootfs_exists: bool,
    pub qemu_available: bool,
    pub virtiofsd_available: bool,
    pub passt_available: bool,
    pub docker_available: bool,
    pub rust_musl_target_installed: bool,
    pub kvm: DeviceStatus,
    pub vhost_vsock: DeviceStatus,
    pub cpu_virtualization_available: Option<bool>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DoctorReport {
    pub title: &'static str,
    pub ok_message: &'static str,
    pub fields: Vec<(String, String)>,
    pub issues: Vec<String>,
}

pub fn current_probe(runtime_dir: impl AsRef<Path>) -> HostProbe {
    current_probe_with_builder_checks(runtime_dir, true)
}

pub fn current_launch_probe(runtime_dir: impl AsRef<Path>) -> HostProbe {
    current_probe_with_builder_checks(runtime_dir, false)
}

fn current_probe_with_builder_checks(
    runtime_dir: impl AsRef<Path>,
    include_builder_checks: bool,
) -> HostProbe {
    let runtime_dir = runtime_dir.as_ref().to_path_buf();
    let artifacts = RuntimeArtifacts::from_runtime_dir(&runtime_dir);

    HostProbe {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        runtime_dir,
        kernel_exists: artifacts.kernel.is_file(),
        initrd_exists: artifacts.initrd.is_file(),
        rootfs_exists: artifacts.rootfs.is_file(),
        qemu_available: command_exists("qemu-system-x86_64"),
        virtiofsd_available: command_exists("virtiofsd"),
        passt_available: command_exists("passt"),
        docker_available: include_builder_checks && process_succeeds("docker", &["info"]),
        rust_musl_target_installed: include_builder_checks
            && rust_target_installed("x86_64-unknown-linux-musl"),
        kvm: device_status("/dev/kvm"),
        vhost_vsock: device_status("/dev/vhost-vsock"),
        cpu_virtualization_available: cpu_virtualization_available(),
    }
}

pub fn evaluate(probe: &HostProbe) -> DoctorReport {
    evaluate_with_options(
        probe,
        ReportOptions {
            title: "fend linux doctor",
            ok_message: "ok  linux backend prerequisites look ready",
            network: None,
            include_builder_requirements: true,
        },
    )
}

pub fn evaluate_launch(probe: &HostProbe, network: NetworkMode) -> DoctorReport {
    evaluate_with_options(
        probe,
        ReportOptions {
            title: "fend linux launch preflight",
            ok_message: "ok  linux launch prerequisites look ready",
            network: Some(network),
            include_builder_requirements: false,
        },
    )
}

#[derive(Debug, Clone, Copy)]
struct ReportOptions {
    title: &'static str,
    ok_message: &'static str,
    network: Option<NetworkMode>,
    include_builder_requirements: bool,
}

fn evaluate_with_options(probe: &HostProbe, options: ReportOptions) -> DoctorReport {
    let artifacts = RuntimeArtifacts::from_runtime_dir(&probe.runtime_dir);
    let artifacts_missing = !probe.kernel_exists || !probe.initrd_exists || !probe.rootfs_exists;
    let require_passt = options.network.unwrap_or(NetworkMode::Passt) == NetworkMode::Passt;
    let mut issues = Vec::new();

    if probe.os != "linux" {
        issues.push("Linux host backend must run on Linux.".to_string());
    }
    if probe.arch != "x86_64" {
        issues.push("Linux spike currently requires x86_64.".to_string());
    }
    if probe.cpu_virtualization_available == Some(false) {
        issues.push(
            "CPU virtualization flags are missing. Enable VT-x/AMD-V or nested virtualization."
                .to_string(),
        );
    }
    if !probe.qemu_available {
        issues.push("Install qemu-system-x86_64, for example Arch package qemu-full.".to_string());
    }
    if !probe.virtiofsd_available {
        issues.push("Install virtiofsd.".to_string());
    }
    if require_passt && !probe.passt_available {
        issues.push("Install passt, or launch with FEND_QEMU_NETWORK=user/off.".to_string());
    }

    if !probe.kvm.exists {
        issues.push(
            "/dev/kvm is missing. Enable virtualization and load the KVM module.".to_string(),
        );
    } else if !probe.kvm.readable || !probe.kvm.writable {
        issues.push(
            "Current user cannot access /dev/kvm. Add the user to the kvm group and log in again."
                .to_string(),
        );
    }

    if !probe.vhost_vsock.exists {
        issues.push("/dev/vhost-vsock is missing. Try: sudo modprobe vhost_vsock.".to_string());
    } else if !probe.vhost_vsock.readable || !probe.vhost_vsock.writable {
        issues.push(
            "Current user cannot access /dev/vhost-vsock. Check device permissions or group membership."
                .to_string(),
        );
    }

    if artifacts_missing {
        issues.push(
            "Run scripts/prepare-linux-x86_64-runtime.sh to build Linux runtime artifacts."
                .to_string(),
        );
        if options.include_builder_requirements && !probe.docker_available {
            issues.push("Docker is required by the current Linux runtime builder.".to_string());
        }
        if options.include_builder_requirements && !probe.rust_musl_target_installed {
            issues.push(
                "Install Rust target x86_64-unknown-linux-musl before building fendd.".to_string(),
            );
        }
    }

    let mut fields = vec![
        ("os".to_string(), probe.os.clone()),
        ("architecture".to_string(), probe.arch.clone()),
        (
            "runtime".to_string(),
            probe.runtime_dir.display().to_string(),
        ),
        (
            "kernel".to_string(),
            artifact_value(&artifacts.kernel, probe.kernel_exists),
        ),
        (
            "initrd".to_string(),
            artifact_value(&artifacts.initrd, probe.initrd_exists),
        ),
        (
            "rootfs".to_string(),
            artifact_value(&artifacts.rootfs, probe.rootfs_exists),
        ),
        ("qemu".to_string(), available_value(probe.qemu_available)),
        (
            "virtiofsd".to_string(),
            available_value(probe.virtiofsd_available),
        ),
    ];
    if let Some(network) = options.network {
        fields.push(("network".to_string(), network_value(network).to_string()));
    }
    if options.network.is_none() || require_passt {
        fields.push(("passt".to_string(), available_value(probe.passt_available)));
    }
    if options.include_builder_requirements {
        fields.push((
            "docker".to_string(),
            available_value(probe.docker_available),
        ));
        fields.push((
            "rust target".to_string(),
            if probe.rust_musl_target_installed {
                "installed".to_string()
            } else {
                "missing".to_string()
            },
        ));
    }
    fields.extend([
        ("/dev/kvm".to_string(), probe.kvm.label()),
        ("/dev/vhost-vsock".to_string(), probe.vhost_vsock.label()),
        (
            "cpu virt".to_string(),
            match probe.cpu_virtualization_available {
                Some(true) => "available".to_string(),
                Some(false) => "missing".to_string(),
                None => "not checked".to_string(),
            },
        ),
    ]);

    DoctorReport {
        title: options.title,
        ok_message: options.ok_message,
        fields,
        issues,
    }
}

fn network_value(network: NetworkMode) -> &'static str {
    match network {
        NetworkMode::Passt => "passt",
        NetworkMode::User => "user",
        NetworkMode::Off => "off",
    }
}

fn artifact_value(path: &Path, exists: bool) -> String {
    if exists {
        path.display().to_string()
    } else {
        "missing".to_string()
    }
}

fn available_value(value: bool) -> String {
    if value {
        "available".to_string()
    } else {
        "missing".to_string()
    }
}

fn command_exists(name: &str) -> bool {
    let Some(path) = env::var_os("PATH") else {
        return false;
    };
    env::split_paths(&path).any(|dir| dir.join(name).is_file())
}

fn process_succeeds(program: &str, args: &[&str]) -> bool {
    Command::new(program)
        .args(args)
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map(|status| status.success())
        .unwrap_or(false)
}

fn device_status(path: impl AsRef<Path>) -> DeviceStatus {
    let path = path.as_ref().to_path_buf();
    let exists = path.exists();
    DeviceStatus {
        readable: exists && File::open(&path).is_ok(),
        writable: exists && OpenOptions::new().write(true).open(&path).is_ok(),
        path,
        exists,
    }
}

fn rust_target_installed(target: &str) -> bool {
    let Ok(output) = Command::new("rustup")
        .args(["target", "list", "--installed"])
        .output()
    else {
        return false;
    };
    if !output.status.success() {
        return false;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.lines().any(|line| line.trim() == target)
}

fn cpu_virtualization_available() -> Option<bool> {
    #[cfg(target_os = "linux")]
    {
        let cpuinfo = std::fs::read_to_string("/proc/cpuinfo").ok()?;
        Some(cpuinfo.contains(" vmx ") || cpuinfo.contains(" svm "))
    }
    #[cfg(not(target_os = "linux"))]
    {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn report_passes_when_linux_prerequisites_are_present() {
        let probe = linux_probe();
        let report = evaluate(&probe);

        assert!(report.issues.is_empty());
        assert_eq!(field(&report, "qemu"), Some("available"));
        assert_eq!(field(&report, "/dev/kvm"), Some("/dev/kvm"));
        assert_eq!(field(&report, "rust target"), Some("installed"));
        assert_eq!(
            field(&report, "kernel"),
            Some("/home/user/.fend/runtime/linux-x86_64/vmlinuz")
        );
    }

    #[test]
    fn report_explains_missing_kvm_permissions_and_runtime_artifacts() {
        let mut probe = linux_probe();
        probe.arch = "aarch64".to_string();
        probe.kernel_exists = false;
        probe.initrd_exists = false;
        probe.rootfs_exists = false;
        probe.docker_available = false;
        probe.qemu_available = false;
        probe.virtiofsd_available = false;
        probe.passt_available = false;
        probe.rust_musl_target_installed = false;
        probe.cpu_virtualization_available = Some(false);
        probe.kvm = DeviceStatus {
            path: PathBuf::from("/dev/kvm"),
            exists: true,
            readable: false,
            writable: false,
        };
        probe.vhost_vsock = DeviceStatus {
            path: PathBuf::from("/dev/vhost-vsock"),
            exists: false,
            readable: false,
            writable: false,
        };

        let report = evaluate(&probe);

        assert_contains(&report.issues, "Linux spike currently requires x86_64.");
        assert_contains(
            &report.issues,
            "CPU virtualization flags are missing. Enable VT-x/AMD-V or nested virtualization.",
        );
        assert_contains(
            &report.issues,
            "Install qemu-system-x86_64, for example Arch package qemu-full.",
        );
        assert_contains(&report.issues, "Install virtiofsd.");
        assert_contains(
            &report.issues,
            "Install passt, or launch with FEND_QEMU_NETWORK=user/off.",
        );
        assert_contains(
            &report.issues,
            "Current user cannot access /dev/kvm. Add the user to the kvm group and log in again.",
        );
        assert_contains(
            &report.issues,
            "/dev/vhost-vsock is missing. Try: sudo modprobe vhost_vsock.",
        );
        assert_contains(
            &report.issues,
            "Run scripts/prepare-linux-x86_64-runtime.sh to build Linux runtime artifacts.",
        );
        assert_contains(
            &report.issues,
            "Docker is required by the current Linux runtime builder.",
        );
        assert_contains(
            &report.issues,
            "Install Rust target x86_64-unknown-linux-musl before building fendd.",
        );
    }

    #[test]
    fn report_warns_when_host_is_not_linux() {
        let mut probe = linux_probe();
        probe.os = "macos".to_string();

        let report = evaluate(&probe);

        assert_contains(&report.issues, "Linux host backend must run on Linux.");
    }

    #[test]
    fn launch_preflight_only_requires_passt_for_passt_networking() {
        let mut probe = linux_probe();
        probe.passt_available = false;

        let off_report = evaluate_launch(&probe, NetworkMode::Off);
        assert!(off_report.issues.is_empty());
        assert_eq!(off_report.title, "fend linux launch preflight");
        assert_eq!(
            off_report.ok_message,
            "ok  linux launch prerequisites look ready"
        );
        assert_eq!(field(&off_report, "network"), Some("off"));
        assert_eq!(field(&off_report, "passt"), None);

        let passt_report = evaluate_launch(&probe, NetworkMode::Passt);
        assert_contains(
            &passt_report.issues,
            "Install passt, or launch with FEND_QEMU_NETWORK=user/off.",
        );
        assert_eq!(field(&passt_report, "network"), Some("passt"));
        assert_eq!(field(&passt_report, "passt"), Some("missing"));
    }

    #[test]
    fn launch_preflight_does_not_require_builder_tools() {
        let mut probe = linux_probe();
        probe.kernel_exists = false;
        probe.initrd_exists = false;
        probe.rootfs_exists = false;
        probe.docker_available = false;
        probe.rust_musl_target_installed = false;

        let report = evaluate_launch(&probe, NetworkMode::User);

        assert_contains(
            &report.issues,
            "Run scripts/prepare-linux-x86_64-runtime.sh to build Linux runtime artifacts.",
        );
        assert!(!report.issues.iter().any(|issue| issue.contains("Docker")));
        assert!(!report
            .issues
            .iter()
            .any(|issue| issue.contains("Rust target")));
        assert_eq!(field(&report, "docker"), None);
        assert_eq!(field(&report, "rust target"), None);
    }

    #[test]
    fn missing_kvm_device_gets_distinct_message() {
        let mut probe = linux_probe();
        probe.kvm = DeviceStatus {
            path: PathBuf::from("/dev/kvm"),
            exists: false,
            readable: false,
            writable: false,
        };

        let report = evaluate(&probe);

        assert_contains(
            &report.issues,
            "/dev/kvm is missing. Enable virtualization and load the KVM module.",
        );
        assert_eq!(field(&report, "/dev/kvm"), Some("missing"));
    }

    #[test]
    fn vhost_vsock_permission_denied_is_a_launch_issue() {
        let mut probe = linux_probe();
        probe.vhost_vsock = DeviceStatus {
            path: PathBuf::from("/dev/vhost-vsock"),
            exists: true,
            readable: false,
            writable: false,
        };

        let report = evaluate_launch(&probe, NetworkMode::Off);

        assert_contains(
            &report.issues,
            "Current user cannot access /dev/vhost-vsock. Check device permissions or group membership.",
        );
        assert_eq!(
            field(&report, "/dev/vhost-vsock"),
            Some("permission denied")
        );
    }

    fn linux_probe() -> HostProbe {
        HostProbe {
            os: "linux".to_string(),
            arch: "x86_64".to_string(),
            runtime_dir: PathBuf::from("/home/user/.fend/runtime/linux-x86_64"),
            kernel_exists: true,
            initrd_exists: true,
            rootfs_exists: true,
            qemu_available: true,
            virtiofsd_available: true,
            passt_available: true,
            docker_available: true,
            rust_musl_target_installed: true,
            kvm: DeviceStatus {
                path: PathBuf::from("/dev/kvm"),
                exists: true,
                readable: true,
                writable: true,
            },
            vhost_vsock: DeviceStatus {
                path: PathBuf::from("/dev/vhost-vsock"),
                exists: true,
                readable: true,
                writable: true,
            },
            cpu_virtualization_available: Some(true),
        }
    }

    fn field<'a>(report: &'a DoctorReport, name: &str) -> Option<&'a str> {
        report
            .fields
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }

    fn assert_contains(items: &[String], expected: &str) {
        assert!(
            items.iter().any(|item| item == expected),
            "missing {expected:?} in {items:#?}"
        );
    }
}
