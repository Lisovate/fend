use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

pub const GUEST_TOOL_PATH_PREPEND_ENV: &str = "FEND_TOOL_PATH_PREPEND";
const NODE_INDEX_URL: &str = "https://nodejs.org/dist/index.json";
const BUN_RELEASES_URL: &str = "https://api.github.com/repos/oven-sh/bun/releases?per_page=100";
const NODE_PLATFORM_SUFFIX: &str = "linux-x64";
const BUN_PLATFORM_SUFFIX: &str = "linux-x64";
const GUEST_TOOLS_ROOT: &str = "/opt/tools";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PreparedGuestCommand {
    pub command: Vec<String>,
    pub env: BTreeMap<String, String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ResolvedRuntime {
    version: String,
    dir_name: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum GuestTool {
    Node,
    Bun,
    Claude,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
struct RuntimePins {
    node: Option<String>,
    bun: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct NodeRelease {
    version: String,
    is_lts: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct BunRelease {
    version: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
struct SemVer {
    major: u64,
    minor: u64,
    patch: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct PartialSemVer {
    major: u64,
    minor: Option<u64>,
    patch: Option<u64>,
}

impl PartialSemVer {
    fn lower_bound(&self) -> SemVer {
        SemVer {
            major: self.major,
            minor: self.minor.unwrap_or(0),
            patch: self.patch.unwrap_or(0),
        }
    }
}

pub fn prepare_guest_command(
    command: &[String],
    workspace: &Path,
    tools_dir: &Path,
) -> Result<PreparedGuestCommand, String> {
    if command.is_empty() {
        return Ok(PreparedGuestCommand {
            command: Vec::new(),
            env: BTreeMap::new(),
        });
    }

    let Some(tool) = guest_tool_for_command(&command[0]) else {
        return Ok(PreparedGuestCommand {
            command: command.to_vec(),
            env: BTreeMap::new(),
        });
    };

    match tool {
        GuestTool::Node => prepare_node_command(command, workspace, tools_dir),
        GuestTool::Bun => prepare_bun_command(command, workspace, tools_dir),
        GuestTool::Claude => {
            if guest_tool_exists(tools_dir, "claude") {
                Ok(PreparedGuestCommand {
                    command: command.to_vec(),
                    env: BTreeMap::new(),
                })
            } else {
                Err(format!(
                    "guest tool \"claude\" is not available in {}",
                    tools_dir.display()
                ))
            }
        }
    }
}

fn prepare_node_command(
    command: &[String],
    workspace: &Path,
    tools_dir: &Path,
) -> Result<PreparedGuestCommand, String> {
    let runtime = ensure_node_runtime(workspace, tools_dir)?;
    let guest_bin = format!("{GUEST_TOOLS_ROOT}/{}/bin", runtime.dir_name);
    let guest_root = format!("{GUEST_TOOLS_ROOT}/{}", runtime.dir_name);
    let guest_node = format!("{guest_bin}/node");
    let host_root = tools_dir.join(&runtime.dir_name);
    let rewritten = match command[0].as_str() {
        "node" => {
            let mut args = vec![guest_node.clone()];
            args.extend(command.iter().skip(1).cloned());
            args
        }
        "npm" => {
            ensure_host_runtime_script(
                &host_root,
                "lib/node_modules/npm/bin/npm-cli.js",
                "npm",
                &runtime.version,
            )?;
            let mut args = vec![
                guest_node.clone(),
                format!("{guest_root}/lib/node_modules/npm/bin/npm-cli.js"),
            ];
            args.extend(command.iter().skip(1).cloned());
            args
        }
        "npx" => {
            ensure_host_runtime_script(
                &host_root,
                "lib/node_modules/npm/bin/npx-cli.js",
                "npx",
                &runtime.version,
            )?;
            let mut args = vec![
                guest_node.clone(),
                format!("{guest_root}/lib/node_modules/npm/bin/npx-cli.js"),
            ];
            args.extend(command.iter().skip(1).cloned());
            args
        }
        "pnpm" | "pnpx" | "yarn" => {
            ensure_host_runtime_script(
                &host_root,
                "lib/node_modules/corepack/dist/corepack.js",
                "corepack",
                &runtime.version,
            )?;
            let mut args = vec![
                guest_node,
                format!("{guest_root}/lib/node_modules/corepack/dist/corepack.js"),
                command[0].clone(),
            ];
            args.extend(command.iter().skip(1).cloned());
            args
        }
        _ => command.to_vec(),
    };

    Ok(PreparedGuestCommand {
        command: rewritten,
        env: BTreeMap::from([(GUEST_TOOL_PATH_PREPEND_ENV.to_string(), guest_bin)]),
    })
}

fn ensure_host_runtime_script(
    runtime_root: &Path,
    relative: &str,
    tool_name: &str,
    version: &str,
) -> Result<(), String> {
    if host_runtime_entry_exists(runtime_root.to_path_buf(), relative) {
        Ok(())
    } else {
        Err(format!(
            "Node.js v{version} does not include {tool_name}; cannot run it inside the guest"
        ))
    }
}

fn prepare_bun_command(
    command: &[String],
    workspace: &Path,
    tools_dir: &Path,
) -> Result<PreparedGuestCommand, String> {
    let runtime = ensure_bun_runtime(workspace, tools_dir)?;
    let guest_dir = format!("{GUEST_TOOLS_ROOT}/{}", runtime.dir_name);
    let bun = format!("{guest_dir}/bun");
    let rewritten = match command[0].as_str() {
        "bun" => {
            let mut args = vec![bun];
            args.extend(command.iter().skip(1).cloned());
            args
        }
        "bunx" => {
            let mut args = vec![bun, "x".to_string()];
            args.extend(command.iter().skip(1).cloned());
            args
        }
        _ => command.to_vec(),
    };

    Ok(PreparedGuestCommand {
        command: rewritten,
        env: BTreeMap::from([(GUEST_TOOL_PATH_PREPEND_ENV.to_string(), guest_dir)]),
    })
}

fn ensure_node_runtime(workspace: &Path, tools_dir: &Path) -> Result<ResolvedRuntime, String> {
    let installed = installed_runtimes(tools_dir, "node-", NODE_PLATFORM_SUFFIX);

    if let Some(requested) = load_runtime_pins(workspace).node {
        return ensure_node_requirement(&requested, tools_dir, &installed);
    }

    for file in [".node-version", ".nvmrc"] {
        let path = workspace.join(file);
        if let Ok(content) = std::fs::read_to_string(path) {
            let requested = content.trim();
            if !requested.is_empty() {
                return ensure_node_requirement(requested, tools_dir, &installed);
            }
        }
    }

    if let Some(requirement) = node_engine_requirement(workspace) {
        if let Some(host) = host_node_version() {
            if let Some(version) = SemVer::parse(&host) {
                if version_satisfies(&version, &requirement) {
                    return ensure_node_version(&host, tools_dir);
                }
            }
        }
        if let Some(runtime) = select_latest_installed_runtime(&installed, &requirement) {
            return Ok(runtime);
        }
        let version = resolve_latest_node_version(&requirement, true)?;
        return ensure_node_version(&version, tools_dir);
    }

    if let Some(host) = host_node_version() {
        return ensure_node_version(&host, tools_dir);
    }

    if let Some(runtime) = latest_installed_runtime(&installed) {
        return Ok(runtime);
    }

    let version = resolve_latest_node_version(">=0", true)?;
    eprintln!("fend: no project Node.js version found, using latest LTS v{version}");
    ensure_node_version(&version, tools_dir)
}

fn ensure_node_requirement(
    requirement: &str,
    tools_dir: &Path,
    installed: &[ResolvedRuntime],
) -> Result<ResolvedRuntime, String> {
    if let Some(runtime) = select_latest_installed_runtime(installed, requirement) {
        return Ok(runtime);
    }
    let version = resolve_concrete_node_version(requirement)?;
    ensure_node_version(&version, tools_dir)
}

fn ensure_node_version(version: &str, tools_dir: &Path) -> Result<ResolvedRuntime, String> {
    let version = normalize_version(version);
    let dir_name = format!("node-{version}-{NODE_PLATFORM_SUFFIX}");
    let runtime = ResolvedRuntime {
        version: version.clone(),
        dir_name,
    };
    if host_runtime_entry_exists(tools_dir.join(&runtime.dir_name), "bin/node") {
        return Ok(runtime);
    }

    std::fs::create_dir_all(tools_dir).map_err(|error| error.to_string())?;
    eprintln!(
        "fend: downloading Node.js v{} for {}...",
        runtime.version, NODE_PLATFORM_SUFFIX
    );
    download_node(&runtime, tools_dir)?;
    eprintln!("fend: Node.js v{} ready", runtime.version);
    Ok(runtime)
}

fn ensure_bun_runtime(workspace: &Path, tools_dir: &Path) -> Result<ResolvedRuntime, String> {
    let installed = installed_runtimes(tools_dir, "bun-", BUN_PLATFORM_SUFFIX);

    if let Some(requested) = load_runtime_pins(workspace).bun {
        return ensure_bun_requirement(&requested, tools_dir, &installed);
    }

    if let Some(host) = host_bun_version() {
        return ensure_bun_version(&host, tools_dir);
    }

    if let Some(runtime) = latest_installed_runtime(&installed) {
        return Ok(runtime);
    }

    let version = resolve_latest_bun_version(">=0")?;
    eprintln!("fend: no project Bun version found, using latest stable v{version}");
    ensure_bun_version(&version, tools_dir)
}

fn ensure_bun_requirement(
    requirement: &str,
    tools_dir: &Path,
    installed: &[ResolvedRuntime],
) -> Result<ResolvedRuntime, String> {
    if let Some(runtime) = select_latest_installed_runtime(installed, requirement) {
        return Ok(runtime);
    }
    let version = resolve_concrete_bun_version(requirement)?;
    ensure_bun_version(&version, tools_dir)
}

fn ensure_bun_version(version: &str, tools_dir: &Path) -> Result<ResolvedRuntime, String> {
    let version = normalize_version(version);
    let dir_name = format!("bun-{version}-{BUN_PLATFORM_SUFFIX}");
    let runtime = ResolvedRuntime {
        version: version.clone(),
        dir_name,
    };
    if host_runtime_entry_exists(tools_dir.join(&runtime.dir_name), "bun") {
        return Ok(runtime);
    }

    std::fs::create_dir_all(tools_dir).map_err(|error| error.to_string())?;
    eprintln!(
        "fend: downloading Bun v{} for {}...",
        runtime.version, BUN_PLATFORM_SUFFIX
    );
    download_bun(&runtime, tools_dir)?;
    eprintln!("fend: Bun v{} ready", runtime.version);
    Ok(runtime)
}

fn guest_tool_for_command(command: &str) -> Option<GuestTool> {
    if command.contains('/') {
        return None;
    }
    match command {
        "node" | "npm" | "npx" | "pnpm" | "pnpx" | "yarn" => Some(GuestTool::Node),
        "bun" | "bunx" => Some(GuestTool::Bun),
        "claude" => Some(GuestTool::Claude),
        _ => None,
    }
}

fn guest_tool_exists(tools_dir: &Path, name: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(tools_dir) else {
        return false;
    };
    entries.flatten().any(|entry| {
        host_runtime_entry_exists(entry.path(), &format!("bin/{name}"))
            || host_runtime_entry_exists(entry.path(), name)
    })
}

fn installed_runtimes(
    tools_dir: &Path,
    prefix: &str,
    platform_suffix: &str,
) -> Vec<ResolvedRuntime> {
    let Ok(entries) = std::fs::read_dir(tools_dir) else {
        return Vec::new();
    };

    let mut runtimes = entries
        .flatten()
        .filter_map(|entry| {
            let file_name = entry.file_name();
            let name = file_name.to_string_lossy();
            parse_runtime_entry(&name, prefix, platform_suffix).map(|version| ResolvedRuntime {
                version,
                dir_name: name.to_string(),
            })
        })
        .collect::<Vec<_>>();
    runtimes.sort_by(|left, right| {
        let left_semver = SemVer::parse(&left.version);
        let right_semver = SemVer::parse(&right.version);
        left_semver.cmp(&right_semver)
    });
    runtimes
}

fn parse_runtime_entry(name: &str, prefix: &str, platform_suffix: &str) -> Option<String> {
    let version = name.strip_prefix(prefix)?;

    let version = version
        .strip_suffix(&format!("-{platform_suffix}"))
        .unwrap_or(version);
    let normalized = normalize_version(version);
    SemVer::parse(&normalized).map(|_| normalized)
}

fn latest_installed_runtime(installed: &[ResolvedRuntime]) -> Option<ResolvedRuntime> {
    installed.last().cloned()
}

fn select_latest_installed_runtime(
    installed: &[ResolvedRuntime],
    requirement: &str,
) -> Option<ResolvedRuntime> {
    installed
        .iter()
        .filter_map(|runtime| {
            let version = SemVer::parse(&runtime.version)?;
            version_satisfies(&version, requirement).then_some(runtime.clone())
        })
        .max_by(|left, right| {
            let left_semver = SemVer::parse(&left.version);
            let right_semver = SemVer::parse(&right.version);
            left_semver.cmp(&right_semver)
        })
}

fn load_runtime_pins(workspace: &Path) -> RuntimePins {
    let Ok(content) = std::fs::read_to_string(workspace.join(".fend.toml")) else {
        return RuntimePins::default();
    };

    let mut section = String::new();
    let mut pins = RuntimePins::default();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }

        if trimmed.starts_with('[') && trimmed.ends_with(']') {
            section = trimmed
                .trim_start_matches('[')
                .trim_end_matches(']')
                .trim()
                .to_string();
            continue;
        }

        let Some((key, raw_value)) = trimmed.split_once('=') else {
            continue;
        };
        if section != "runtime" {
            continue;
        }

        let key = key.trim();
        let mut value = strip_inline_comment(raw_value.trim()).trim().to_string();
        if value.starts_with('"') && value.ends_with('"') && value.len() >= 2 {
            value = value[1..value.len() - 1].to_string();
        }
        if value.is_empty() {
            continue;
        }

        match key {
            "node" => pins.node = Some(value),
            "bun" => pins.bun = Some(value),
            _ => {}
        }
    }

    pins
}

fn strip_inline_comment(value: &str) -> String {
    let mut in_quotes = false;
    for (idx, ch) in value.char_indices() {
        match ch {
            '"' => in_quotes = !in_quotes,
            '#' if !in_quotes => return value[..idx].to_string(),
            _ => {}
        }
    }
    value.to_string()
}

fn node_engine_requirement(workspace: &Path) -> Option<String> {
    let data = std::fs::read(workspace.join("package.json")).ok()?;
    let json: serde_json::Value = serde_json::from_slice(&data).ok()?;
    let requirement = json
        .get("engines")?
        .get("node")?
        .as_str()?
        .trim()
        .to_string();
    (!requirement.is_empty()).then_some(requirement)
}

fn host_node_version() -> Option<String> {
    for command in ["node", "nodejs"] {
        if let Some(version) = binary_version(command, &["--version"]) {
            return Some(version);
        }
    }
    None
}

fn host_bun_version() -> Option<String> {
    if let Some(version) = binary_version("bun", &["--version"]) {
        return Some(version);
    }

    let home = std::env::var_os("HOME").map(PathBuf::from)?;
    for path in [
        home.join(".bun/bin/bun"),
        PathBuf::from("/usr/local/bin/bun"),
    ] {
        if path.exists() {
            if let Some(version) = binary_version(path.to_string_lossy().as_ref(), &["--version"]) {
                return Some(version);
            }
        }
    }
    None
}

fn binary_version(program: &str, args: &[&str]) -> Option<String> {
    let output = Command::new(program).args(args).output().ok()?;
    if !output.status.success() {
        return None;
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let version = normalize_version(stdout.trim());
    (!version.is_empty()).then_some(version)
}

fn resolve_concrete_node_version(requirement: &str) -> Result<String, String> {
    let normalized = normalize_version(requirement);
    if SemVer::is_full(&normalized) {
        return Ok(normalized);
    }
    resolve_latest_node_version(&normalized, false)
}

fn resolve_concrete_bun_version(requirement: &str) -> Result<String, String> {
    let normalized = normalize_version(requirement);
    if SemVer::is_full(&normalized) {
        return Ok(normalized);
    }
    resolve_latest_bun_version(&normalized)
}

fn resolve_latest_node_version(requirement: &str, prefer_lts: bool) -> Result<String, String> {
    let releases = fetch_node_releases()?;
    select_latest_node_version(requirement, &releases, prefer_lts)
        .ok_or_else(|| format!("no Node.js release matches requirement {requirement:?}"))
}

fn resolve_latest_bun_version(requirement: &str) -> Result<String, String> {
    let releases = fetch_bun_releases()?;
    select_latest_bun_version(requirement, &releases)
        .ok_or_else(|| format!("no Bun release matches requirement {requirement:?}"))
}

fn fetch_node_releases() -> Result<Vec<NodeRelease>, String> {
    let output = run_host_command("curl", &["-fsSL", NODE_INDEX_URL], None)?;
    let json: serde_json::Value =
        serde_json::from_slice(&output).map_err(|error| error.to_string())?;
    let array = json
        .as_array()
        .ok_or_else(|| "node index response was not an array".to_string())?;

    Ok(array
        .iter()
        .filter_map(|entry| {
            let version = normalize_version(entry.get("version")?.as_str()?);
            let is_lts = match entry.get("lts") {
                Some(serde_json::Value::String(value)) => !value.is_empty(),
                Some(serde_json::Value::Bool(value)) => *value,
                _ => false,
            };
            SemVer::parse(&version).map(|_| NodeRelease { version, is_lts })
        })
        .collect())
}

fn fetch_bun_releases() -> Result<Vec<BunRelease>, String> {
    let output = run_host_command(
        "curl",
        &[
            "-fsSL",
            "-H",
            "Accept: application/vnd.github+json",
            BUN_RELEASES_URL,
        ],
        None,
    )?;
    let json: serde_json::Value =
        serde_json::from_slice(&output).map_err(|error| error.to_string())?;
    let array = json
        .as_array()
        .ok_or_else(|| "bun release response was not an array".to_string())?;

    Ok(array
        .iter()
        .filter_map(|entry| {
            if entry.get("draft").and_then(serde_json::Value::as_bool) == Some(true) {
                return None;
            }
            if entry.get("prerelease").and_then(serde_json::Value::as_bool) == Some(true) {
                return None;
            }
            let tag = entry.get("tag_name")?.as_str()?;
            let version = normalize_version(tag.trim_start_matches("bun-"));
            if version.contains('-') {
                return None;
            }
            SemVer::parse(&version).map(|_| BunRelease { version })
        })
        .collect())
}

fn select_latest_node_version(
    requirement: &str,
    releases: &[NodeRelease],
    prefer_lts: bool,
) -> Option<String> {
    let matches = releases
        .iter()
        .filter_map(|release| {
            let version = SemVer::parse(&release.version)?;
            version_satisfies(&version, requirement).then_some((release, version))
        })
        .collect::<Vec<_>>();

    let preferred = if prefer_lts {
        matches
            .iter()
            .copied()
            .filter(|(release, _)| release.is_lts)
            .collect::<Vec<_>>()
    } else {
        Vec::new()
    };
    let candidates = if preferred.is_empty() {
        matches
    } else {
        preferred
    };

    candidates
        .into_iter()
        .max_by(|(_, left), (_, right)| left.cmp(right))
        .map(|(release, _)| release.version.clone())
}

fn select_latest_bun_version(requirement: &str, releases: &[BunRelease]) -> Option<String> {
    releases
        .iter()
        .filter_map(|release| {
            let version = SemVer::parse(&release.version)?;
            version_satisfies(&version, requirement).then_some((release, version))
        })
        .max_by(|(_, left), (_, right)| left.cmp(right))
        .map(|(release, _)| release.version.clone())
}

fn download_node(runtime: &ResolvedRuntime, tools_dir: &Path) -> Result<(), String> {
    let archive_name = format!("node-v{}-{NODE_PLATFORM_SUFFIX}", runtime.version);
    let url = format!(
        "https://nodejs.org/dist/v{}/{}.tar.xz",
        runtime.version, archive_name
    );
    let temp_dir = create_temp_dir(tools_dir, "node")?;
    let archive_path = temp_dir.join(format!("{archive_name}.tar.xz"));
    run_host_command(
        "curl",
        &["-fsSL", "-o", archive_path.to_string_lossy().as_ref(), &url],
        None,
    )?;
    run_host_command(
        "tar",
        &[
            "xf",
            archive_path.to_string_lossy().as_ref(),
            "-C",
            temp_dir.to_string_lossy().as_ref(),
        ],
        None,
    )?;
    let extracted = temp_dir.join(&archive_name);
    finalize_runtime_install(extracted, tools_dir.join(&runtime.dir_name), &temp_dir)
}

fn download_bun(runtime: &ResolvedRuntime, tools_dir: &Path) -> Result<(), String> {
    let archive_name = format!("bun-{BUN_PLATFORM_SUFFIX}");
    let url = format!(
        "https://github.com/oven-sh/bun/releases/download/bun-v{}/{}.zip",
        runtime.version, archive_name
    );
    let temp_dir = create_temp_dir(tools_dir, "bun")?;
    let archive_path = temp_dir.join(format!("{archive_name}.zip"));
    run_host_command(
        "curl",
        &["-fsSL", "-o", archive_path.to_string_lossy().as_ref(), &url],
        None,
    )?;
    run_host_command(
        "unzip",
        &[
            "-q",
            archive_path.to_string_lossy().as_ref(),
            "-d",
            temp_dir.to_string_lossy().as_ref(),
        ],
        None,
    )?;
    let extracted = temp_dir.join(&archive_name);
    let bunx = extracted.join("bunx");
    if extracted.join("bun").exists() && !bunx.exists() {
        std::os::unix::fs::symlink("bun", &bunx).map_err(|error| error.to_string())?;
    }
    finalize_runtime_install(extracted, tools_dir.join(&runtime.dir_name), &temp_dir)
}

fn create_temp_dir(parent: &Path, name: &str) -> Result<PathBuf, String> {
    let epoch = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    let path = parent.join(format!(
        ".fend-runtime-{name}-{}-{epoch}",
        std::process::id()
    ));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).map_err(|error| error.to_string())?;
    Ok(path)
}

fn finalize_runtime_install(
    extracted: PathBuf,
    destination: PathBuf,
    temp_dir: &Path,
) -> Result<(), String> {
    if destination.exists() {
        let _ = std::fs::remove_dir_all(temp_dir);
        return Ok(());
    }
    std::fs::rename(&extracted, &destination).map_err(|error| error.to_string())?;
    let _ = std::fs::remove_dir_all(temp_dir);
    Ok(())
}

fn run_host_command(program: &str, args: &[&str], cwd: Option<&Path>) -> Result<Vec<u8>, String> {
    let mut command = Command::new(program);
    command.args(args);
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

fn host_runtime_entry_exists(base: PathBuf, relative: &str) -> bool {
    base.join(relative).exists()
}

fn normalize_version(value: &str) -> String {
    value
        .trim()
        .trim_start_matches('v')
        .trim_start_matches('V')
        .to_string()
}

impl SemVer {
    fn parse(raw: &str) -> Option<Self> {
        let normalized = normalize_version(raw);
        if normalized.contains('-') {
            return None;
        }
        let core = normalized.split('+').next()?;
        let mut parts = core.split('.');
        let major = parts.next()?.parse().ok()?;
        let minor = parts.next().unwrap_or("0").parse().ok()?;
        let patch = parts.next().unwrap_or("0").parse().ok()?;
        if parts.next().is_some() {
            return None;
        }
        Some(Self {
            major,
            minor,
            patch,
        })
    }

    fn is_full(raw: &str) -> bool {
        let normalized = normalize_version(raw);
        let mut parts = normalized.split('.');
        parts
            .next()
            .and_then(|part| part.parse::<u64>().ok())
            .is_some()
            && parts
                .next()
                .and_then(|part| part.parse::<u64>().ok())
                .is_some()
            && parts
                .next()
                .and_then(|part| part.parse::<u64>().ok())
                .is_some()
            && parts.next().is_none()
    }
}

fn version_satisfies(version: &SemVer, requirement: &str) -> bool {
    requirement.split("||").any(|clause| {
        let tokens = comparator_tokens(clause);
        !tokens.is_empty()
            && tokens
                .iter()
                .all(|token| comparator_accepts(token, version))
    })
}

fn comparator_tokens(clause: &str) -> Vec<String> {
    let raw = clause
        .split_whitespace()
        .map(str::to_string)
        .collect::<Vec<_>>();
    let mut tokens = Vec::new();
    let mut idx = 0;
    while idx < raw.len() {
        if matches!(raw[idx].as_str(), ">=" | "<=" | ">" | "<" | "=") && idx + 1 < raw.len() {
            tokens.push(format!("{}{}", raw[idx], raw[idx + 1]));
            idx += 2;
        } else {
            tokens.push(raw[idx].clone());
            idx += 1;
        }
    }
    tokens
}

fn comparator_accepts(token: &str, version: &SemVer) -> bool {
    let token = normalize_version(token);
    if token.is_empty() || token == "*" {
        return true;
    }

    if let Some(rest) = token.strip_prefix('^') {
        let Some(base) = parse_partial_semver(rest) else {
            return false;
        };
        let lower = base.lower_bound();
        let upper = if base.major > 0 {
            SemVer {
                major: base.major + 1,
                minor: 0,
                patch: 0,
            }
        } else if let Some(minor) = base.minor {
            SemVer {
                major: 0,
                minor: minor + 1,
                patch: 0,
            }
        } else {
            SemVer {
                major: 0,
                minor: 0,
                patch: base.patch.unwrap_or(0) + 1,
            }
        };
        return *version >= lower && *version < upper;
    }

    if let Some(rest) = token.strip_prefix('~') {
        let Some(base) = parse_partial_semver(rest) else {
            return false;
        };
        let lower = base.lower_bound();
        let upper = if base.minor.is_none() {
            SemVer {
                major: base.major + 1,
                minor: 0,
                patch: 0,
            }
        } else {
            SemVer {
                major: base.major,
                minor: base.minor.unwrap_or(0) + 1,
                patch: 0,
            }
        };
        return *version >= lower && *version < upper;
    }

    for operator in [">=", "<=", ">", "<", "="] {
        if let Some(rest) = token.strip_prefix(operator) {
            let Some(bound) = parse_partial_semver(rest).map(|value| value.lower_bound()) else {
                return false;
            };
            return match operator {
                ">=" => version >= &bound,
                "<=" => version <= &bound,
                ">" => version > &bound,
                "<" => version < &bound,
                "=" => version == &bound,
                _ => false,
            };
        }
    }

    let Some(expected) = parse_partial_semver(&token) else {
        return false;
    };
    if version.major != expected.major {
        return false;
    }
    if let Some(minor) = expected.minor {
        if version.minor != minor {
            return false;
        }
    }
    if let Some(patch) = expected.patch {
        if version.patch != patch {
            return false;
        }
    }
    true
}

fn parse_partial_semver(raw: &str) -> Option<PartialSemVer> {
    let normalized = normalize_version(raw);
    if normalized.is_empty() {
        return None;
    }
    let core = normalized.split('+').next()?;
    let parts = core.split('.').collect::<Vec<_>>();
    if parts.is_empty() || parts.len() > 3 {
        return None;
    }

    let major = parse_partial_part(parts[0])??;
    let minor = if parts.len() > 1 {
        parse_partial_part(parts[1])?
    } else {
        None
    };
    let patch = if parts.len() > 2 {
        parse_partial_part(parts[2])?
    } else {
        None
    };

    Some(PartialSemVer {
        major,
        minor,
        patch,
    })
}

fn parse_partial_part(raw: &str) -> Option<Option<u64>> {
    match raw.to_ascii_lowercase().as_str() {
        "x" | "*" => Some(None),
        _ => raw.parse::<u64>().ok().map(Some),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guest_tool_detection_ignores_absolute_commands() {
        assert_eq!(guest_tool_for_command("/bin/sh"), None);
    }

    #[test]
    fn guest_tool_detection_covers_node_and_bun_families() {
        assert_eq!(guest_tool_for_command("npm"), Some(GuestTool::Node));
        assert_eq!(guest_tool_for_command("bunx"), Some(GuestTool::Bun));
        assert_eq!(guest_tool_for_command("git"), None);
    }

    #[test]
    fn parses_runtime_pins_from_fend_toml() {
        let temp = TempDir::new("pins");
        std::fs::write(
            temp.path.join(".fend.toml"),
            "[runtime]\nnode = \"22\"\nbun = \"1.2\"\n",
        )
        .unwrap();

        let pins = load_runtime_pins(&temp.path);
        assert_eq!(pins.node.as_deref(), Some("22"));
        assert_eq!(pins.bun.as_deref(), Some("1.2"));
    }

    #[test]
    fn reads_package_json_engine_requirement() {
        let temp = TempDir::new("package-json");
        std::fs::write(
            temp.path.join("package.json"),
            r#"{"engines":{"node":">=20 <23"}}"#,
        )
        .unwrap();

        assert_eq!(
            node_engine_requirement(&temp.path).as_deref(),
            Some(">=20 <23")
        );
    }

    #[test]
    fn selects_latest_node_version_for_major_only() {
        let releases = vec![
            NodeRelease {
                version: "22.0.0".to_string(),
                is_lts: false,
            },
            NodeRelease {
                version: "22.11.1".to_string(),
                is_lts: true,
            },
            NodeRelease {
                version: "23.0.0".to_string(),
                is_lts: false,
            },
        ];

        assert_eq!(
            select_latest_node_version("22", &releases, false).as_deref(),
            Some("22.11.1")
        );
    }

    #[test]
    fn selects_latest_node_version_for_engine_range() {
        let releases = vec![
            NodeRelease {
                version: "18.20.5".to_string(),
                is_lts: true,
            },
            NodeRelease {
                version: "20.11.1".to_string(),
                is_lts: true,
            },
            NodeRelease {
                version: "22.14.0".to_string(),
                is_lts: true,
            },
            NodeRelease {
                version: "23.0.0".to_string(),
                is_lts: false,
            },
        ];

        assert_eq!(
            select_latest_node_version(">=20 <23", &releases, false).as_deref(),
            Some("22.14.0")
        );
    }

    #[test]
    fn prefers_lts_node_releases_when_requested() {
        let releases = vec![
            NodeRelease {
                version: "22.14.0".to_string(),
                is_lts: true,
            },
            NodeRelease {
                version: "24.2.0".to_string(),
                is_lts: false,
            },
            NodeRelease {
                version: "25.0.0".to_string(),
                is_lts: false,
            },
        ];

        assert_eq!(
            select_latest_node_version(">=20", &releases, true).as_deref(),
            Some("22.14.0")
        );
    }

    #[test]
    fn prepares_pnpm_through_corepack_with_selected_runtime() {
        let temp = TempDir::new("pnpm");
        let runtime_root = temp.path.join("tools").join("node-22.11.0-linux-x64");
        let node_dir = runtime_root.join("bin");
        let corepack_dir = runtime_root.join("lib/node_modules/corepack/dist");
        std::fs::create_dir_all(&node_dir).unwrap();
        std::fs::create_dir_all(&corepack_dir).unwrap();
        std::fs::write(node_dir.join("node"), b"").unwrap();
        std::fs::write(corepack_dir.join("corepack.js"), b"").unwrap();
        std::fs::write(
            temp.path.join(".fend.toml"),
            "[runtime]\nnode = \"22.11.0\"\n",
        )
        .unwrap();

        let prepared = prepare_guest_command(
            &["pnpm".to_string(), "install".to_string()],
            &temp.path,
            &temp.path.join("tools"),
        )
        .unwrap();

        assert_eq!(
            prepared.command,
            vec![
                "/opt/tools/node-22.11.0-linux-x64/bin/node".to_string(),
                "/opt/tools/node-22.11.0-linux-x64/lib/node_modules/corepack/dist/corepack.js"
                    .to_string(),
                "pnpm".to_string(),
                "install".to_string()
            ]
        );
        assert_eq!(
            prepared
                .env
                .get(GUEST_TOOL_PATH_PREPEND_ENV)
                .map(String::as_str),
            Some("/opt/tools/node-22.11.0-linux-x64/bin")
        );
    }

    #[test]
    fn prepares_npm_through_node_entrypoint_script() {
        let temp = TempDir::new("npm");
        let runtime_root = temp.path.join("tools").join("node-22.11.0-linux-x64");
        let node_dir = runtime_root.join("bin");
        let npm_dir = runtime_root.join("lib/node_modules/npm/bin");
        std::fs::create_dir_all(&node_dir).unwrap();
        std::fs::create_dir_all(&npm_dir).unwrap();
        std::fs::write(node_dir.join("node"), b"").unwrap();
        std::fs::write(npm_dir.join("npm-cli.js"), b"").unwrap();
        std::fs::write(
            temp.path.join(".fend.toml"),
            "[runtime]\nnode = \"22.11.0\"\n",
        )
        .unwrap();

        let prepared = prepare_guest_command(
            &["npm".to_string(), "install".to_string()],
            &temp.path,
            &temp.path.join("tools"),
        )
        .unwrap();

        assert_eq!(
            prepared.command,
            vec![
                "/opt/tools/node-22.11.0-linux-x64/bin/node".to_string(),
                "/opt/tools/node-22.11.0-linux-x64/lib/node_modules/npm/bin/npm-cli.js".to_string(),
                "install".to_string()
            ]
        );
    }

    #[test]
    fn prepares_bunx_through_bun_binary() {
        let temp = TempDir::new("bunx");
        let bun_dir = temp.path.join("tools").join("bun-1.2.0-linux-x64");
        std::fs::create_dir_all(&bun_dir).unwrap();
        std::fs::write(bun_dir.join("bun"), b"").unwrap();
        std::fs::write(temp.path.join(".fend.toml"), "[runtime]\nbun = \"1.2.0\"\n").unwrap();

        let prepared = prepare_guest_command(
            &["bunx".to_string(), "cowsay".to_string()],
            &temp.path,
            &temp.path.join("tools"),
        )
        .unwrap();

        assert_eq!(
            prepared.command,
            vec![
                "/opt/tools/bun-1.2.0-linux-x64/bun".to_string(),
                "x".to_string(),
                "cowsay".to_string()
            ]
        );
        assert_eq!(
            prepared
                .env
                .get(GUEST_TOOL_PATH_PREPEND_ENV)
                .map(String::as_str),
            Some("/opt/tools/bun-1.2.0-linux-x64")
        );
    }

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(name: &str) -> Self {
            let epoch = SystemTime::now()
                .duration_since(UNIX_EPOCH)
                .map(|duration| duration.as_secs())
                .unwrap_or(0);
            let path = PathBuf::from("/tmp").join(format!(
                "fend-linux-runtime-{name}-{}-{epoch}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&path);
            std::fs::create_dir_all(&path).unwrap();
            Self { path }
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.path);
        }
    }
}
