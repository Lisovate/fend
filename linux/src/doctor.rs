use std::env;
use std::fs::OpenOptions;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::qemu::{NetworkMode, RuntimeArtifacts};
use crate::tools::{resolve_virtiofsd, ResolvedVirtiofsd};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DeviceError {
    PermissionDenied,
    NoDevice,
    Other(i32),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeviceStatus {
    pub path: PathBuf,
    pub exists: bool,
    pub readable: bool,
    pub writable: bool,
    pub error: Option<DeviceError>,
}

impl DeviceStatus {
    pub fn label(&self) -> String {
        if !self.exists {
            return "missing".to_string();
        }
        if self.readable && self.writable {
            return self.path.display().to_string();
        }
        match self.error {
            Some(DeviceError::NoDevice) => "no driver (module not loaded?)".to_string(),
            Some(DeviceError::Other(errno)) => format!("inaccessible (errno {errno})"),
            Some(DeviceError::PermissionDenied) | None => "permission denied".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostProbe {
    pub os: String,
    pub arch: String,
    pub distribution: Option<DistributionInfo>,
    pub runtime_dir: PathBuf,
    pub kernel_exists: bool,
    pub initrd_exists: bool,
    pub rootfs_exists: bool,
    pub qemu_available: bool,
    pub virtiofsd: Option<ResolvedVirtiofsd>,
    pub unshare_available: bool,
    pub subuid_configured: Option<bool>,
    pub subgid_configured: Option<bool>,
    pub passt_available: bool,
    pub curl_available: bool,
    pub strings_available: bool,
    pub docker_available: bool,
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

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DistributionInfo {
    pub id: String,
    pub version_id: Option<String>,
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
    let virtiofsd = resolve_virtiofsd();
    let rootless_virtiofsd = virtiofsd
        .as_ref()
        .map(ResolvedVirtiofsd::requires_unshare)
        .unwrap_or(false);

    HostProbe {
        os: std::env::consts::OS.to_string(),
        arch: std::env::consts::ARCH.to_string(),
        distribution: distribution_info(),
        runtime_dir,
        kernel_exists: artifacts.kernel.is_file(),
        initrd_exists: artifacts.initrd.is_file(),
        rootfs_exists: artifacts.rootfs.is_file(),
        qemu_available: command_exists("qemu-system-x86_64"),
        virtiofsd,
        unshare_available: !rootless_virtiofsd || command_exists("unshare"),
        subuid_configured: rootless_virtiofsd.then(|| subordinate_id_configured("/etc/subuid")),
        subgid_configured: rootless_virtiofsd.then(|| subordinate_id_configured("/etc/subgid")),
        passt_available: command_exists("passt"),
        curl_available: !include_builder_checks || command_exists("curl"),
        strings_available: !include_builder_checks || command_exists("strings"),
        docker_available: include_builder_checks && process_succeeds("docker", &["info"]),
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
    let require_passt = options.network == Some(NetworkMode::Passt);
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
        issues.push(package_install_issue(
            probe.distribution.as_ref(),
            PackageHint::Qemu,
            "Install qemu-system-x86_64.",
        ));
    }
    if probe.virtiofsd.is_none() {
        issues.push(package_install_issue(
            probe.distribution.as_ref(),
            PackageHint::Virtiofsd,
            "Install virtiofsd, or set FEND_VIRTIOFSD to the binary path.",
        ));
    }
    if probe
        .virtiofsd
        .as_ref()
        .map(ResolvedVirtiofsd::requires_unshare)
        .unwrap_or(false)
        && !probe.unshare_available
    {
        issues.push(package_install_issue(
            probe.distribution.as_ref(),
            PackageHint::Unshare,
            "Install unshare (usually from util-linux) for rootless virtiofsd.",
        ));
    }
    if probe
        .virtiofsd
        .as_ref()
        .map(ResolvedVirtiofsd::requires_unshare)
        .unwrap_or(false)
        && (probe.subuid_configured == Some(false) || probe.subgid_configured == Some(false))
    {
        issues.push(
            "Current user is missing /etc/subuid or /etc/subgid mappings required for rootless virtiofsd."
                .to_string(),
        );
    }
    if require_passt && !probe.passt_available {
        issues.push(package_install_issue(
            probe.distribution.as_ref(),
            PackageHint::Passt,
            "Install passt, or launch with FEND_QEMU_NETWORK=user/off.",
        ));
    }

    if !probe.kvm.exists {
        issues.push(
            "/dev/kvm is missing. Enable virtualization and load the KVM module.".to_string(),
        );
    } else if !probe.kvm.readable || !probe.kvm.writable {
        issues.push(kvm_access_issue(probe.kvm.error));
    }

    if !probe.vhost_vsock.exists {
        issues.push("/dev/vhost-vsock is missing. Try: sudo modprobe vhost_vsock.".to_string());
    } else if !probe.vhost_vsock.readable || !probe.vhost_vsock.writable {
        issues.push(vhost_vsock_access_issue(probe.vhost_vsock.error));
    }

    if artifacts_missing {
        issues.push("Run `fend setup` to prepare Linux runtime artifacts.".to_string());
        if options.include_builder_requirements && !probe.curl_available {
            issues.push(package_install_issue(
                probe.distribution.as_ref(),
                PackageHint::Curl,
                "Install curl so `fend setup` can download runtime assets.",
            ));
        }
        if options.include_builder_requirements && !probe.strings_available {
            issues.push(package_install_issue(
                probe.distribution.as_ref(),
                PackageHint::Strings,
                "Install strings (usually from binutils) so `fend setup` can detect the guest kernel version.",
            ));
        }
        if options.include_builder_requirements && !probe.docker_available {
            issues.push(
                package_install_issue(
                    probe.distribution.as_ref(),
                    PackageHint::Docker,
                    "Install Docker and start the daemon. `fend setup` currently uses Docker to build rootfs.img.",
                ),
            );
        }
    }

    let mut fields = vec![
        ("os".to_string(), probe.os.clone()),
        ("architecture".to_string(), probe.arch.clone()),
        (
            "distribution".to_string(),
            probe
                .distribution
                .as_ref()
                .map(DistributionInfo::display_value)
                .unwrap_or_else(|| "unknown".to_string()),
        ),
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
            probe
                .virtiofsd
                .as_ref()
                .map(ResolvedVirtiofsd::display_value)
                .unwrap_or_else(|| "missing".to_string()),
        ),
    ];
    if probe
        .virtiofsd
        .as_ref()
        .map(ResolvedVirtiofsd::requires_unshare)
        .unwrap_or(false)
    {
        fields.push((
            "unshare".to_string(),
            available_value(probe.unshare_available),
        ));
        fields.push((
            "subuid".to_string(),
            subordinate_id_value(probe.subuid_configured),
        ));
        fields.push((
            "subgid".to_string(),
            subordinate_id_value(probe.subgid_configured),
        ));
    }
    if let Some(network) = options.network {
        fields.push(("network".to_string(), network.to_string()));
    }
    if options.network.is_none() || require_passt {
        fields.push(("passt".to_string(), available_value(probe.passt_available)));
    }
    if options.include_builder_requirements {
        fields.push(("curl".to_string(), available_value(probe.curl_available)));
        fields.push((
            "strings".to_string(),
            available_value(probe.strings_available),
        ));
        fields.push((
            "docker".to_string(),
            available_value(probe.docker_available),
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

fn subordinate_id_value(value: Option<bool>) -> String {
    match value {
        Some(true) => "configured".to_string(),
        Some(false) => "missing".to_string(),
        None => "not checked".to_string(),
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
    if !exists {
        return DeviceStatus {
            path,
            exists,
            readable: false,
            writable: false,
            error: None,
        };
    }
    match OpenOptions::new().read(true).write(true).open(&path) {
        Ok(_) => DeviceStatus {
            path,
            exists,
            readable: true,
            writable: true,
            error: None,
        },
        Err(err) => {
            let raw = err.raw_os_error().unwrap_or(0);
            let kind = if raw == libc::EACCES || raw == libc::EPERM {
                DeviceError::PermissionDenied
            } else if raw == libc::ENODEV || raw == libc::ENXIO {
                DeviceError::NoDevice
            } else {
                DeviceError::Other(raw)
            };
            DeviceStatus {
                path,
                exists,
                readable: false,
                writable: false,
                error: Some(kind),
            }
        }
    }
}

fn kvm_access_issue(error: Option<DeviceError>) -> String {
    match error {
        Some(DeviceError::NoDevice) => {
            "/dev/kvm exists but has no driver behind it. Load the KVM module \
             (e.g. sudo modprobe kvm-intel or sudo modprobe kvm-amd). If you just \
             upgraded the kernel, reboot so modules match the running kernel."
                .to_string()
        }
        Some(DeviceError::Other(errno)) => {
            format!("/dev/kvm could not be opened (errno {errno}).")
        }
        Some(DeviceError::PermissionDenied) | None => {
            "Current user cannot access /dev/kvm. Add the user to the kvm group and log in again."
                .to_string()
        }
    }
}

fn vhost_vsock_access_issue(error: Option<DeviceError>) -> String {
    match error {
        Some(DeviceError::NoDevice) => {
            "/dev/vhost-vsock exists but has no driver behind it. Load the module: \
             sudo modprobe vhost_vsock. If you just upgraded the kernel, reboot so \
             modules match the running kernel."
                .to_string()
        }
        Some(DeviceError::Other(errno)) => {
            format!("/dev/vhost-vsock could not be opened (errno {errno}).")
        }
        Some(DeviceError::PermissionDenied) | None => {
            "Current user cannot access /dev/vhost-vsock. Check device permissions or group membership."
                .to_string()
        }
    }
}

fn subordinate_id_configured(path: impl AsRef<Path>) -> bool {
    let Some(user) = current_user_name() else {
        return false;
    };
    let Ok(contents) = std::fs::read_to_string(path) else {
        return false;
    };
    contents
        .lines()
        .any(|line| line.starts_with(&format!("{user}:")))
}

fn current_user_name() -> Option<String> {
    env::var("USER")
        .ok()
        .filter(|value| !value.is_empty())
        .or_else(|| env::var("LOGNAME").ok().filter(|value| !value.is_empty()))
}

fn distribution_info() -> Option<DistributionInfo> {
    let content = std::fs::read_to_string("/etc/os-release").ok()?;
    let mut id = None;
    let mut version_id = None;

    for line in content.lines() {
        let Some((key, raw_value)) = line.split_once('=') else {
            continue;
        };
        let value = raw_value.trim().trim_matches('"').to_string();
        match key {
            "ID" => id = Some(value),
            "VERSION_ID" => version_id = Some(value),
            _ => {}
        }
    }

    Some(DistributionInfo {
        id: id?,
        version_id,
    })
}

impl DistributionInfo {
    fn display_value(&self) -> String {
        match &self.version_id {
            Some(version_id) if !version_id.is_empty() => format!("{} {}", self.id, version_id),
            _ => self.id.clone(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum PackageHint {
    Qemu,
    Virtiofsd,
    Passt,
    Docker,
    Unshare,
    Curl,
    Strings,
}

fn package_install_issue(
    distribution: Option<&DistributionInfo>,
    hint: PackageHint,
    base: &str,
) -> String {
    match package_install_command(distribution, hint) {
        Some(command) => format!("{base} Try: {command}"),
        None => base.to_string(),
    }
}

fn package_install_command(
    distribution: Option<&DistributionInfo>,
    hint: PackageHint,
) -> Option<String> {
    let distribution = distribution?;
    match distribution.id.as_str() {
        "arch" => Some(match hint {
            PackageHint::Qemu => "sudo pacman -S --needed qemu-system-x86".to_string(),
            PackageHint::Virtiofsd => "sudo pacman -S --needed virtiofsd".to_string(),
            PackageHint::Passt => "sudo pacman -S --needed passt".to_string(),
            PackageHint::Docker => {
                "sudo pacman -S --needed docker && sudo systemctl enable --now docker".to_string()
            }
            PackageHint::Unshare => "sudo pacman -S --needed util-linux".to_string(),
            PackageHint::Curl => "sudo pacman -S --needed curl".to_string(),
            PackageHint::Strings => "sudo pacman -S --needed binutils".to_string(),
        }),
        "ubuntu" | "debian" => Some(match hint {
            PackageHint::Qemu => "sudo apt install qemu-system-x86".to_string(),
            PackageHint::Virtiofsd => "sudo apt install virtiofsd".to_string(),
            PackageHint::Passt => "sudo apt install passt".to_string(),
            PackageHint::Docker => {
                "sudo apt install docker.io && sudo systemctl enable --now docker".to_string()
            }
            PackageHint::Unshare => "sudo apt install util-linux".to_string(),
            PackageHint::Curl => "sudo apt install curl".to_string(),
            PackageHint::Strings => "sudo apt install binutils".to_string(),
        }),
        _ => None,
    }
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
        assert_eq!(field(&report, "virtiofsd"), Some("/usr/bin/virtiofsd"));
        assert_eq!(field(&report, "/dev/kvm"), Some("/dev/kvm"));
        assert_eq!(field(&report, "distribution"), Some("arch"));
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
        probe.virtiofsd = None;
        probe.passt_available = false;
        probe.curl_available = false;
        probe.strings_available = false;
        probe.cpu_virtualization_available = Some(false);
        probe.kvm = DeviceStatus {
            path: PathBuf::from("/dev/kvm"),
            exists: true,
            readable: false,
            writable: false,
            error: Some(DeviceError::PermissionDenied),
        };
        probe.vhost_vsock = DeviceStatus {
            path: PathBuf::from("/dev/vhost-vsock"),
            exists: false,
            readable: false,
            writable: false,
            error: None,
        };

        let report = evaluate(&probe);

        assert_contains(&report.issues, "Linux spike currently requires x86_64.");
        assert_contains(
            &report.issues,
            "CPU virtualization flags are missing. Enable VT-x/AMD-V or nested virtualization.",
        );
        assert_contains(
            &report.issues,
            "Install qemu-system-x86_64. Try: sudo pacman -S --needed qemu-system-x86",
        );
        assert_contains(
            &report.issues,
            "Install virtiofsd, or set FEND_VIRTIOFSD to the binary path. Try: sudo pacman -S --needed virtiofsd",
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
            "Run `fend setup` to prepare Linux runtime artifacts.",
        );
        assert_contains(
            &report.issues,
            "Install curl so `fend setup` can download runtime assets. Try: sudo pacman -S --needed curl",
        );
        assert_contains(
            &report.issues,
            "Install strings (usually from binutils) so `fend setup` can detect the guest kernel version. Try: sudo pacman -S --needed binutils",
        );
        assert_contains(
            &report.issues,
            "Install Docker and start the daemon. `fend setup` currently uses Docker to build rootfs.img. Try: sudo pacman -S --needed docker && sudo systemctl enable --now docker",
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
            "Install passt, or launch with FEND_QEMU_NETWORK=user/off. Try: sudo pacman -S --needed passt",
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
        probe.curl_available = false;
        probe.strings_available = false;

        let report = evaluate_launch(&probe, NetworkMode::User);

        assert_contains(
            &report.issues,
            "Run `fend setup` to prepare Linux runtime artifacts.",
        );
        assert!(!report.issues.iter().any(|issue| issue.contains("Docker")));
        assert_eq!(field(&report, "docker"), None);
        assert_eq!(field(&report, "curl"), None);
    }

    #[test]
    fn missing_kvm_device_gets_distinct_message() {
        let mut probe = linux_probe();
        probe.kvm = DeviceStatus {
            path: PathBuf::from("/dev/kvm"),
            exists: false,
            readable: false,
            writable: false,
            error: None,
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
            error: Some(DeviceError::PermissionDenied),
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

    #[test]
    fn vhost_vsock_no_device_suggests_module_load_or_reboot() {
        let mut probe = linux_probe();
        probe.vhost_vsock = DeviceStatus {
            path: PathBuf::from("/dev/vhost-vsock"),
            exists: true,
            readable: false,
            writable: false,
            error: Some(DeviceError::NoDevice),
        };

        let report = evaluate_launch(&probe, NetworkMode::Off);

        assert_contains(
            &report.issues,
            "/dev/vhost-vsock exists but has no driver behind it. Load the module: \
             sudo modprobe vhost_vsock. If you just upgraded the kernel, reboot so \
             modules match the running kernel.",
        );
        assert_eq!(
            field(&report, "/dev/vhost-vsock"),
            Some("no driver (module not loaded?)")
        );
    }

    #[test]
    fn kvm_no_device_suggests_module_load_or_reboot() {
        let mut probe = linux_probe();
        probe.kvm = DeviceStatus {
            path: PathBuf::from("/dev/kvm"),
            exists: true,
            readable: false,
            writable: false,
            error: Some(DeviceError::NoDevice),
        };

        let report = evaluate(&probe);

        assert_contains(
            &report.issues,
            "/dev/kvm exists but has no driver behind it. Load the KVM module \
             (e.g. sudo modprobe kvm-intel or sudo modprobe kvm-amd). If you just \
             upgraded the kernel, reboot so modules match the running kernel.",
        );
        assert_eq!(
            field(&report, "/dev/kvm"),
            Some("no driver (module not loaded?)")
        );
    }

    #[test]
    fn device_with_unknown_errno_reports_raw_errno() {
        let mut probe = linux_probe();
        probe.vhost_vsock = DeviceStatus {
            path: PathBuf::from("/dev/vhost-vsock"),
            exists: true,
            readable: false,
            writable: false,
            error: Some(DeviceError::Other(5)),
        };

        let report = evaluate_launch(&probe, NetworkMode::Off);

        assert_contains(
            &report.issues,
            "/dev/vhost-vsock could not be opened (errno 5).",
        );
        assert_eq!(
            field(&report, "/dev/vhost-vsock"),
            Some("inaccessible (errno 5)")
        );
    }

    #[test]
    fn rootless_virtiofsd_requires_unshare_and_subordinate_ids() {
        let mut probe = linux_probe();
        probe.virtiofsd = Some(ResolvedVirtiofsd {
            path: PathBuf::from("/usr/lib/virtiofsd"),
            mode: crate::tools::VirtiofsdMode::RootlessUnshare,
        });
        probe.unshare_available = false;
        probe.subuid_configured = Some(false);
        probe.subgid_configured = Some(true);

        let report = evaluate_launch(&probe, NetworkMode::User);

        assert_contains(
            &report.issues,
            "Install unshare (usually from util-linux) for rootless virtiofsd. Try: sudo pacman -S --needed util-linux",
        );
        assert_contains(
            &report.issues,
            "Current user is missing /etc/subuid or /etc/subgid mappings required for rootless virtiofsd.",
        );
        assert_eq!(
            field(&report, "virtiofsd"),
            Some("/usr/lib/virtiofsd (rootless via unshare)")
        );
        assert_eq!(field(&report, "unshare"), Some("missing"));
        assert_eq!(field(&report, "subuid"), Some("missing"));
        assert_eq!(field(&report, "subgid"), Some("configured"));
    }

    fn linux_probe() -> HostProbe {
        HostProbe {
            os: "linux".to_string(),
            arch: "x86_64".to_string(),
            distribution: Some(DistributionInfo {
                id: "arch".to_string(),
                version_id: None,
            }),
            runtime_dir: PathBuf::from("/home/user/.fend/runtime/linux-x86_64"),
            kernel_exists: true,
            initrd_exists: true,
            rootfs_exists: true,
            qemu_available: true,
            virtiofsd: Some(ResolvedVirtiofsd::direct("/usr/bin/virtiofsd")),
            unshare_available: true,
            subuid_configured: None,
            subgid_configured: None,
            passt_available: true,
            curl_available: true,
            strings_available: true,
            docker_available: true,
            kvm: DeviceStatus {
                path: PathBuf::from("/dev/kvm"),
                exists: true,
                readable: true,
                writable: true,
                error: None,
            },
            vhost_vsock: DeviceStatus {
                path: PathBuf::from("/dev/vhost-vsock"),
                exists: true,
                readable: true,
                writable: true,
                error: None,
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
