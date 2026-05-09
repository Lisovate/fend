use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::qemu::RuntimeArtifacts;

const UBUNTU_BASE: &str = "https://cloud-images.ubuntu.com/releases/noble/release/unpacked";
const KERNEL_FILE: &str = "ubuntu-24.04-server-cloudimg-amd64-vmlinuz-generic";
const INITRD_FILE: &str = "ubuntu-24.04-server-cloudimg-amd64-initrd-generic";
const CLAUDE_DIST: &str =
    "https://storage.googleapis.com/claude-code-dist-86c565f3-f756-42ad-8dfa-d59b1c096819/claude-code-releases";
const DOCKER_PLATFORM: &str = "linux/amd64";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapOptions {
    pub runtime_dir: PathBuf,
    pub work_dir: PathBuf,
    pub tools_dir: PathBuf,
    pub rebuild_rootfs: bool,
    pub force_downloads: bool,
    pub skip_claude: bool,
    pub verbose: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct BootstrapReport {
    pub artifacts: RuntimeArtifacts,
    pub metadata_path: PathBuf,
    pub bootstrapped: bool,
}

pub fn default_work_dir(fend_home: &Path) -> PathBuf {
    fend_home.join("tmp/build-linux-x86_64-runtime")
}

pub fn default_claude_dir(tools_dir: &Path) -> PathBuf {
    tools_dir.join("claude-linux-x64")
}

pub fn runtime_missing(runtime_dir: &Path) -> bool {
    let artifacts = RuntimeArtifacts::from_runtime_dir(runtime_dir);
    !artifacts.kernel.is_file() || !artifacts.initrd.is_file() || !artifacts.rootfs.is_file()
}

pub fn ensure_linux_runtime(options: &BootstrapOptions) -> Result<BootstrapReport, String> {
    let artifacts = RuntimeArtifacts::from_runtime_dir(&options.runtime_dir);
    let metadata_path = options.runtime_dir.join("metadata.env");
    let needs_setup =
        runtime_missing(&options.runtime_dir) || options.rebuild_rootfs || options.force_downloads;

    if !needs_setup {
        return Ok(BootstrapReport {
            artifacts,
            metadata_path,
            bootstrapped: false,
        });
    }

    fs::create_dir_all(&options.runtime_dir).map_err(|error| error.to_string())?;
    fs::create_dir_all(&options.work_dir).map_err(|error| error.to_string())?;

    status(
        options,
        "preparing Linux runtime in",
        &options.runtime_dir.display().to_string(),
    );

    ensure_host_command("curl", "install curl before running `fend`")?;
    ensure_host_command("docker", "install Docker before running `fend`")?;
    ensure_host_command("strings", "install binutils before running `fend`")?;
    ensure_docker_daemon()?;

    let sha_sums_path = options.work_dir.join("SHA256SUMS");
    ensure_ubuntu_sums(&sha_sums_path, options.force_downloads)?;
    download_ubuntu_artifact(
        KERNEL_FILE,
        &artifacts.kernel,
        &sha_sums_path,
        options.force_downloads,
        options,
        "kernel",
    )?;
    download_ubuntu_artifact(
        INITRD_FILE,
        &artifacts.initrd,
        &sha_sums_path,
        options.force_downloads,
        options,
        "initrd",
    )?;

    let fendd_bin = resolve_fendd_binary()?;
    maybe_download_claude(options)?;
    build_rootfs(options, &artifacts.rootfs, &artifacts.kernel, &fendd_bin)?;
    write_metadata(&metadata_path, &artifacts)?;

    Ok(BootstrapReport {
        artifacts,
        metadata_path,
        bootstrapped: true,
    })
}

pub fn resolve_fendd_binary() -> Result<PathBuf, String> {
    if let Some(path) = std::env::var_os("FENDD_BIN")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
    {
        if path.is_file() {
            return Ok(path);
        }
        return Err(format!(
            "FENDD_BIN points to a missing file: {}",
            path.display()
        ));
    }

    for candidate in packaged_fendd_candidates() {
        if candidate.is_file() {
            return Ok(candidate);
        }
    }

    Err(
        "packaged guest agent was not found; reinstall the Linux npm package or set FENDD_BIN"
            .to_string(),
    )
}

fn packaged_fendd_candidates() -> Vec<PathBuf> {
    let mut candidates = Vec::new();

    if let Ok(exe) = std::env::current_exe() {
        if let Some(bin_dir) = exe.parent() {
            if let Some(package_root) = bin_dir.parent() {
                candidates.push(package_root.join("libexec/fendd"));
            }
            candidates.push(bin_dir.join("fendd"));
        }

        let mut cursor = exe.parent();
        while let Some(dir) = cursor {
            let repo_fendd = dir.join("fendd/target/x86_64-unknown-linux-musl/release/fendd");
            if repo_fendd.is_file() {
                candidates.push(repo_fendd);
            }
            let repo_root = dir.join("fendd/Cargo.toml");
            if repo_root.is_file() {
                candidates.push(dir.join("fendd/target/x86_64-unknown-linux-musl/release/fendd"));
                break;
            }
            cursor = dir.parent();
        }
    }

    if let Ok(cwd) = std::env::current_dir() {
        candidates.push(cwd.join("packages/cli-linux-x64/libexec/fendd"));
        candidates.push(cwd.join("fendd/target/x86_64-unknown-linux-musl/release/fendd"));
    }

    candidates
}

fn maybe_download_claude(options: &BootstrapOptions) -> Result<(), String> {
    if options.skip_claude {
        return Ok(());
    }

    let claude_dir = default_claude_dir(&options.tools_dir);
    let claude_path = claude_dir.join("claude");
    if claude_path.is_file() {
        return Ok(());
    }

    status(options, "downloading optional Claude Code guest tool", "");
    fs::create_dir_all(&claude_dir).map_err(|error| error.to_string())?;
    let latest_url = format!("{CLAUDE_DIST}/latest");
    let latest = run_capture("curl", vec!["-fsSL".to_string(), latest_url], None)?;
    let version = String::from_utf8_lossy(&latest).trim().to_string();
    if version.is_empty() {
        return Ok(());
    }

    let url = format!("{CLAUDE_DIST}/{version}/linux-x64/claude");
    if let Err(error) = run_capture(
        "curl",
        vec![
            "-fsSL".to_string(),
            "-o".to_string(),
            claude_path.display().to_string(),
            url,
        ],
        None,
    ) {
        let _ = fs::remove_file(&claude_path);
        if options.verbose {
            eprintln!("fend: optional Claude download skipped: {error}");
        }
        return Ok(());
    }

    make_executable(&claude_path)?;
    Ok(())
}

fn build_rootfs(
    options: &BootstrapOptions,
    rootfs_path: &Path,
    kernel_path: &Path,
    fendd_bin: &Path,
) -> Result<(), String> {
    if rootfs_path.is_file() && !options.rebuild_rootfs && !options.force_downloads {
        return Ok(());
    }
    if rootfs_path.exists() {
        let _ = fs::remove_file(rootfs_path);
    }

    status(options, "building guest rootfs with Docker", "");
    let rootfs_build = options.work_dir.join("rootfs_build");
    let rootfs_tar = options.work_dir.join("rootfs.tar");
    let _ = fs::remove_dir_all(&rootfs_build);
    let _ = fs::remove_file(&rootfs_tar);
    fs::create_dir_all(&rootfs_build).map_err(|error| error.to_string())?;
    fs::copy(fendd_bin, rootfs_build.join("fendd")).map_err(|error| error.to_string())?;

    let kernel_version = detect_kernel_version(kernel_path)?;
    let dockerfile = rootfs_build.join("Dockerfile");
    fs::write(&dockerfile, rootfs_dockerfile(kernel_version.as_deref()))
        .map_err(|error| error.to_string())?;

    run_capture(
        "docker",
        vec![
            "build".to_string(),
            "--platform".to_string(),
            DOCKER_PLATFORM.to_string(),
            "--build-arg".to_string(),
            format!("KERNEL_VERSION={}", kernel_version.unwrap_or_default()),
            "-t".to_string(),
            "fend-linux-x86_64-rootfs-builder".to_string(),
            rootfs_build.display().to_string(),
        ],
        None,
    )?;

    let container_id = String::from_utf8_lossy(&run_capture(
        "docker",
        vec![
            "create".to_string(),
            "--platform".to_string(),
            DOCKER_PLATFORM.to_string(),
            "fend-linux-x86_64-rootfs-builder".to_string(),
            "/bin/true".to_string(),
        ],
        None,
    )?)
    .trim()
    .to_string();

    run_capture(
        "docker",
        vec![
            "export".to_string(),
            "-o".to_string(),
            rootfs_tar.display().to_string(),
            container_id.clone(),
        ],
        None,
    )?;
    let _ = run_capture("docker", vec!["rm".to_string(), container_id], None);

    let mkfs_dockerfile = rootfs_build.join("Dockerfile.mkfs");
    fs::write(
        &mkfs_dockerfile,
        "FROM ubuntu:24.04\nRUN apt-get update && apt-get install -y --no-install-recommends e2fsprogs && rm -rf /var/lib/apt/lists/*\n",
    )
    .map_err(|error| error.to_string())?;
    run_capture(
        "docker",
        vec![
            "build".to_string(),
            "--platform".to_string(),
            DOCKER_PLATFORM.to_string(),
            "-t".to_string(),
            "fend-linux-x86_64-mkfs".to_string(),
            "-f".to_string(),
            mkfs_dockerfile.display().to_string(),
            rootfs_build.display().to_string(),
        ],
        None,
    )?;

    let tar_size_mib = size_mib(&rootfs_tar)?;
    let mut img_size_mib = tar_size_mib + tar_size_mib / 5;
    if img_size_mib < 1024 {
        img_size_mib = 1024;
    }

    let mkfs_script = format!(
        "set -euo pipefail\n\
         mkdir -p /rootfs_dir\n\
         tar -xf /rootfs.tar -C /rootfs_dir\n\
         rm -rf /rootfs_dir/.dockerenv /rootfs_dir/proc/* /rootfs_dir/sys/* /rootfs_dir/dev/*\n\
         mkdir -p /rootfs_dir/proc /rootfs_dir/sys /rootfs_dir/dev /rootfs_dir/dev/pts /rootfs_dir/run /rootfs_dir/tmp\n\
         chmod 1777 /rootfs_dir/tmp\n\
         if [ -f /rootfs_dir/etc/hosts.fend ]; then cp /rootfs_dir/etc/hosts.fend /rootfs_dir/etc/hosts; rm /rootfs_dir/etc/hosts.fend; fi\n\
         mke2fs -t ext4 -d /rootfs_dir -L fend-rootfs -m 1 -N 100000 /output/rootfs.img {img_size_mib}M\n"
    );
    run_capture(
        "docker",
        vec![
            "run".to_string(),
            "--rm".to_string(),
            "--platform".to_string(),
            DOCKER_PLATFORM.to_string(),
            "-v".to_string(),
            format!("{}:/rootfs.tar:ro", rootfs_tar.display()),
            "-v".to_string(),
            format!("{}:/output", options.runtime_dir.display()),
            "fend-linux-x86_64-mkfs".to_string(),
            "/bin/bash".to_string(),
            "-c".to_string(),
            mkfs_script,
        ],
        None,
    )?;

    let _ = fs::remove_file(&rootfs_tar);
    let _ = fs::remove_dir_all(&rootfs_build);
    let _ = run_capture(
        "docker",
        vec![
            "rmi".to_string(),
            "fend-linux-x86_64-rootfs-builder".to_string(),
            "fend-linux-x86_64-mkfs".to_string(),
        ],
        None,
    );

    if !rootfs_path.is_file() {
        return Err("rootfs.img was not created".to_string());
    }

    Ok(())
}

fn rootfs_dockerfile(kernel_version: Option<&str>) -> String {
    let build_arg = kernel_version.unwrap_or("");
    format!(
        "FROM ubuntu:24.04 AS rootfs\n\
\n\
         ENV DEBIAN_FRONTEND=noninteractive\n\
         ARG KERNEL_VERSION={build_arg}\n\
\n\
\n\
         RUN apt-get update && apt-get install -y --no-install-recommends \\\n\
             bash \\\n\
             ca-certificates \\\n\
             curl \\\n\
             e2fsprogs \\\n\
             git \\\n\
             iproute2 \\\n\
             iputils-ping \\\n\
             isc-dhcp-client \\\n\
             kmod \\\n\
             netbase \\\n\
             openssh-client \\\n\
             && rm -rf /var/lib/apt/lists/*\n\
\n\
         RUN if [ -n \"$KERNEL_VERSION\" ]; then \\\n\
               apt-get update; \\\n\
               apt-get install -y --no-install-recommends \"linux-modules-${{KERNEL_VERSION}}\" \\\n\
                 || echo \"warning: linux-modules-${{KERNEL_VERSION}} unavailable\"; \\\n\
               rm -rf /var/lib/apt/lists/*; \\\n\
             fi\n\
\n\
         RUN if id -u 1000 >/dev/null 2>&1; then \\\n\
               existing=\"$(getent passwd 1000 | cut -d: -f1)\"; \\\n\
               usermod -l user -d /home/user -m -s /bin/bash \"$existing\"; \\\n\
               groupmod -n user \"$existing\" 2>/dev/null || true; \\\n\
             else \\\n\
               useradd -m -u 1000 -s /bin/bash user; \\\n\
             fi\n\
\n\
         COPY fendd /usr/local/bin/fendd\n\
         RUN chmod +x /usr/local/bin/fendd\n\
\n\
         RUN mkdir -p /workspace /opt/tools /home/user/.npm /home/user/.cache /home/user/.local/bin \\\n\
             /proc /sys /dev /dev/pts /run /tmp \\\n\
             && chmod 1777 /tmp \\\n\
             && chown -R 1000:1000 /home/user\n\
\n\
         RUN printf '127.0.0.1 localhost fend\\n::1 localhost ip6-localhost ip6-loopback\\n' > /etc/hosts.fend\n\
\n\
         RUN printf '#!/bin/sh\\ncase \"$1\" in\\n  bound|renew)\\n    ip addr add \"$ip/$mask\" dev \"$interface\" 2>/dev/null\\n    [ -n \"$router\" ] && ip route add default via \"$router\" dev \"$interface\" 2>/dev/null\\n    [ -n \"$dns\" ] && echo \"nameserver $dns\" > /etc/resolv.conf\\n    ;;\\nesac\\n' > /bin/simple_dhcp.sh \\\n\
             && chmod +x /bin/simple_dhcp.sh\n\
\n\
         RUN [ -f /usr/bin/env ] || ln -sf /bin/env /usr/bin/env\n"
    )
}

fn detect_kernel_version(kernel_path: &Path) -> Result<Option<String>, String> {
    let output = run_capture("strings", vec![kernel_path.display().to_string()], None)?;
    let stdout = String::from_utf8_lossy(&output);
    Ok(stdout
        .lines()
        .find_map(|line| extract_kernel_version(line.trim())))
}

fn extract_kernel_version(line: &str) -> Option<String> {
    for token in line.split(|ch: char| ch.is_whitespace() || ch == '\0') {
        if token.ends_with("-generic") {
            let core = token
                .trim_matches(|ch: char| !ch.is_ascii_alphanumeric() && ch != '.' && ch != '-');
            if core
                .chars()
                .next()
                .map(|ch| ch.is_ascii_digit())
                .unwrap_or(false)
                && core.matches('.').count() >= 2
                && core.contains('-')
            {
                return Some(core.to_string());
            }
        }
    }
    None
}

fn write_metadata(metadata_path: &Path, artifacts: &RuntimeArtifacts) -> Result<(), String> {
    let kernel_sha = sha256_file(&artifacts.kernel)?;
    let initrd_sha = sha256_file(&artifacts.initrd)?;
    let rootfs_sha = sha256_file(&artifacts.rootfs)?;
    let built_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);

    fs::write(
        metadata_path,
        format!(
            "target=linux-x86_64\nubuntu_base={UBUNTU_BASE}\nkernel_file={KERNEL_FILE}\nkernel_sha256={kernel_sha}\ninitrd_file={INITRD_FILE}\ninitrd_sha256={initrd_sha}\nrootfs_sha256={rootfs_sha}\nbuilt_at_unix={built_at}\n"
        ),
    )
    .map_err(|error| error.to_string())
}

fn ensure_ubuntu_sums(path: &Path, force: bool) -> Result<(), String> {
    if path.is_file() && !force {
        return Ok(());
    }
    download_to_path(&format!("{UBUNTU_BASE}/SHA256SUMS"), path)
}

fn download_ubuntu_artifact(
    file_name: &str,
    destination: &Path,
    sha_sums_path: &Path,
    force: bool,
    options: &BootstrapOptions,
    label: &str,
) -> Result<(), String> {
    if destination.is_file() && !force {
        return Ok(());
    }
    status(options, "downloading", label);
    download_to_path(&format!("{UBUNTU_BASE}/{file_name}"), destination)?;
    verify_ubuntu_checksum(file_name, destination, sha_sums_path)
}

fn download_to_path(url: &str, destination: &Path) -> Result<(), String> {
    if let Some(parent) = destination.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let temp = destination.with_extension("tmp");
    run_capture(
        "curl",
        vec![
            "-fL".to_string(),
            "--retry".to_string(),
            "3".to_string(),
            "--retry-delay".to_string(),
            "2".to_string(),
            "-o".to_string(),
            temp.display().to_string(),
            url.to_string(),
        ],
        None,
    )?;
    fs::rename(temp, destination).map_err(|error| error.to_string())
}

fn verify_ubuntu_checksum(
    file_name: &str,
    destination: &Path,
    sha_sums_path: &Path,
) -> Result<(), String> {
    let sums = fs::read_to_string(sha_sums_path).map_err(|error| error.to_string())?;
    let expected = sums.lines().find_map(|line| {
        let mut parts = line.split_whitespace();
        let sha = parts.next()?;
        let name = parts.next()?.trim_start_matches('*');
        (name == file_name).then_some(sha.to_string())
    });
    let Some(expected) = expected else {
        return Err(format!("Ubuntu SHA256SUMS did not contain {file_name}"));
    };
    let actual = sha256_file(destination)?;
    if actual == expected {
        Ok(())
    } else {
        let _ = fs::remove_file(destination);
        Err(format!("checksum mismatch for {file_name}"))
    }
}

fn sha256_file(path: &Path) -> Result<String, String> {
    if let Ok(output) = run_capture("sha256sum", vec![path.display().to_string()], None) {
        return parse_checksum_output(&output);
    }
    let output = run_capture(
        "shasum",
        vec![
            "-a".to_string(),
            "256".to_string(),
            path.display().to_string(),
        ],
        None,
    )?;
    parse_checksum_output(&output)
}

fn parse_checksum_output(output: &[u8]) -> Result<String, String> {
    String::from_utf8_lossy(output)
        .split_whitespace()
        .next()
        .map(|value| value.to_string())
        .ok_or_else(|| "checksum command returned empty output".to_string())
}

fn size_mib(path: &Path) -> Result<u64, String> {
    let bytes = fs::metadata(path).map_err(|error| error.to_string())?.len();
    Ok(bytes.div_ceil(1024 * 1024))
}

fn ensure_host_command(program: &str, guidance: &str) -> Result<(), String> {
    let status = Command::new("sh")
        .args(["-lc", &format!("command -v {program} >/dev/null 2>&1")])
        .status()
        .map_err(|error| format!("failed to check {program}: {error}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(guidance.to_string())
    }
}

fn ensure_docker_daemon() -> Result<(), String> {
    if run_capture("docker", vec!["info".to_string()], None).is_ok() {
        Ok(())
    } else {
        Err("Docker is installed but the daemon is not running".to_string())
    }
}

fn run_capture(program: &str, args: Vec<String>, cwd: Option<&Path>) -> Result<Vec<u8>, String> {
    let mut command = Command::new(program);
    command.args(&args);
    if let Some(cwd) = cwd {
        command.current_dir(cwd);
    }
    let output = command.output().map_err(|error| {
        if error.kind() == std::io::ErrorKind::NotFound {
            format!("required host tool {program:?} was not found in PATH")
        } else {
            format!("failed to start {program:?}: {error}")
        }
    })?;

    if output.status.success() {
        Ok(output.stdout)
    } else {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        if stderr.is_empty() {
            Err(format!("{program:?} exited with status {}", output.status))
        } else {
            Err(format!("{program:?} failed: {stderr}"))
        }
    }
}

fn make_executable(path: &Path) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let mut permissions = fs::metadata(path)
            .map_err(|error| error.to_string())?
            .permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).map_err(|error| error.to_string())
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Ok(())
    }
}

fn status(options: &BootstrapOptions, action: &str, detail: &str) {
    if options.verbose {
        if detail.is_empty() {
            eprintln!("fend: {action}");
        } else {
            eprintln!("fend: {action} {detail}");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_missing_runtime_artifacts() {
        let runtime_dir = PathBuf::from("/tmp/fend-bootstrap-test-missing");
        let _ = fs::remove_dir_all(&runtime_dir);
        fs::create_dir_all(&runtime_dir).unwrap();
        assert!(runtime_missing(&runtime_dir));
        let _ = fs::remove_dir_all(&runtime_dir);
    }

    #[test]
    fn extracts_kernel_version_tokens() {
        assert_eq!(
            extract_kernel_version("Linux version 6.8.0-106-generic (buildd)"),
            Some("6.8.0-106-generic".to_string())
        );
        assert_eq!(extract_kernel_version("garbage"), None);
    }

    #[test]
    fn computes_rootfs_size_with_padding_and_floor() {
        let temp = PathBuf::from(format!(
            "/tmp/fend-bootstrap-size-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .unwrap()
                .as_secs()
        ));
        fs::write(&temp, vec![0_u8; 2 * 1024 * 1024]).unwrap();
        assert_eq!(size_mib(&temp).unwrap(), 2);
        let _ = fs::remove_file(temp);
    }
}
