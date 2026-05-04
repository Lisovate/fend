use std::collections::VecDeque;
use std::env;
use std::fmt;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use crate::doctor::DoctorReport;
use crate::qemu::{LaunchConfig, LaunchPlan, NetworkMode, RuntimeArtifacts};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliCommand {
    Help(HelpTopic),
    Doctor(DoctorOptions),
    Plan(PlanOptions),
    Launch(PlanOptions),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelpTopic {
    General,
    Doctor,
    Plan,
    Launch,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DoctorOptions {
    pub runtime_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanOptions {
    pub runtime_dir: Option<PathBuf>,
    pub workspace: Option<PathBuf>,
    pub cache_dir: Option<PathBuf>,
    pub tools_dir: Option<PathBuf>,
    pub run_dir: Option<PathBuf>,
    pub guest_cid: Option<u32>,
    pub cpus: Option<u16>,
    pub memory_mib: Option<u32>,
    pub network: Option<NetworkMode>,
    pub epoch: Option<i64>,
    pub guest_workspace: String,
}

impl Default for PlanOptions {
    fn default() -> Self {
        Self {
            runtime_dir: None,
            workspace: None,
            cache_dir: None,
            tools_dir: None,
            run_dir: None,
            guest_cid: None,
            cpus: None,
            memory_mib: None,
            network: None,
            epoch: None,
            guest_workspace: "/workspace".to_string(),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanDefaults {
    pub fend_home: PathBuf,
    pub cwd: PathBuf,
    pub temp_dir: PathBuf,
    pub runtime_dir: Option<PathBuf>,
    pub cache_dir: Option<PathBuf>,
    pub tools_dir: Option<PathBuf>,
    pub run_dir: Option<PathBuf>,
    pub guest_cid: Option<u32>,
    pub cpus: Option<u16>,
    pub memory_mib: Option<u32>,
    pub network: Option<NetworkMode>,
    pub epoch: i64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliError {
    UnknownCommand(String),
    UnknownOption(String),
    MissingValue(&'static str),
    UnexpectedArgument(String),
    InvalidNetwork(String),
    InvalidNumber { option: &'static str, value: String },
    HelpRequested(HelpTopic),
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownCommand(command) => write!(f, "unknown command: {command}"),
            Self::UnknownOption(option) => write!(f, "unknown option: {option}"),
            Self::MissingValue(option) => write!(f, "missing value for {option}"),
            Self::UnexpectedArgument(argument) => write!(f, "unexpected argument: {argument}"),
            Self::InvalidNetwork(value) => {
                write!(f, "invalid network mode {value:?}; use passt, user, or off")
            }
            Self::InvalidNumber { option, value } => {
                write!(f, "invalid numeric value for {option}: {value:?}")
            }
            Self::HelpRequested(_) => write!(f, "help requested"),
        }
    }
}

impl std::error::Error for CliError {}

pub fn usage() -> &'static str {
    "usage: fend-linux <command> [options]\n\ncommands:\n  doctor      Check Linux host prerequisites and runtime artifacts.\n  plan        Print the QEMU and virtiofsd launch plan without starting a VM.\n  launch      Start virtiofsd sidecars and QEMU from the Rust Linux host path.\n\ncommon options:\n  -h, --help\n\nrun 'fend-linux doctor --help', 'fend-linux plan --help', or 'fend-linux launch --help' for command options.\n"
}

pub fn doctor_usage() -> &'static str {
    "usage: fend-linux doctor [--runtime-dir path]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n                         Default: $FEND_RUNTIME_DIR or $FEND_HOME/runtime/linux-x86_64.\n"
}

pub fn plan_usage() -> &'static str {
    "usage: fend-linux plan [workspace] [options]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n  --workspace path       Host project directory. Positional workspace is also accepted.\n  --cache-dir path       Host package-manager cache mount.\n  --tools-dir path       Host tool cache mount.\n  --run-dir path         Directory for QEMU and virtiofsd sockets/logs.\n  --cid n                Guest vsock CID. Default: 42.\n  --cpus n               vCPU count. Default: 2.\n  --memory-mib n         Memory in MiB. Default: 2048.\n  --network mode         passt, user, or off. Default: passt.\n  --epoch n              Epoch value passed to the guest.\n  --guest-workspace path Guest workspace path. Default: /workspace.\n"
}

pub fn launch_usage() -> &'static str {
    "usage: fend-linux launch [workspace] [options]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n  --workspace path       Host project directory. Positional workspace is also accepted.\n  --cache-dir path       Host package-manager cache mount.\n  --tools-dir path       Host tool cache mount.\n  --run-dir path         Directory for QEMU and virtiofsd sockets/logs.\n  --cid n                Guest vsock CID. Default: 42.\n  --cpus n               vCPU count. Default: 2.\n  --memory-mib n         Memory in MiB. Default: 2048.\n  --network mode         passt, user, or off. Default: passt.\n  --epoch n              Epoch value passed to the guest.\n  --guest-workspace path Guest workspace path. Default: /workspace.\n"
}

pub fn parse_args<I, S>(args: I) -> Result<CliCommand, CliError>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let mut args = args.into_iter().map(Into::into).collect::<VecDeque<_>>();
    let Some(command) = args.pop_front() else {
        return Ok(CliCommand::Help(HelpTopic::General));
    };

    match command.as_str() {
        "-h" | "--help" | "help" => Ok(CliCommand::Help(HelpTopic::General)),
        "doctor" => parse_doctor(args),
        "plan" => parse_plan(args),
        "launch" => parse_launch(args),
        other => Err(CliError::UnknownCommand(other.to_string())),
    }
}

pub fn plan_defaults_from_env() -> Result<PlanDefaults, CliError> {
    let fend_home = env_path("FEND_HOME")
        .or_else(|| env_path("HOME").map(|home| home.join(".fend")))
        .unwrap_or_else(|| PathBuf::from(".fend"));

    Ok(PlanDefaults {
        fend_home,
        cwd: env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        temp_dir: env::temp_dir(),
        runtime_dir: env_path("FEND_RUNTIME_DIR"),
        cache_dir: env_path("FEND_CACHE_DIR"),
        tools_dir: env_path("FEND_TOOLS_DIR"),
        run_dir: env_path("FEND_RUN_DIR"),
        guest_cid: env_number("FEND_QEMU_CID", "--cid")?,
        cpus: env_number("FEND_QEMU_CPUS", "--cpus")?,
        memory_mib: env_number("FEND_QEMU_MEMORY_MB", "--memory-mib")?,
        network: env_network("FEND_QEMU_NETWORK")?,
        epoch: current_epoch(),
    })
}

pub fn default_runtime_dir(defaults: &PlanDefaults) -> PathBuf {
    defaults.fend_home.join("runtime/linux-x86_64")
}

pub fn resolve_doctor_runtime_dir(options: &DoctorOptions, defaults: &PlanDefaults) -> PathBuf {
    options
        .runtime_dir
        .clone()
        .or_else(|| defaults.runtime_dir.clone())
        .unwrap_or_else(|| default_runtime_dir(defaults))
}

pub fn resolve_plan_runtime_dir(options: &PlanOptions, defaults: &PlanDefaults) -> PathBuf {
    options
        .runtime_dir
        .clone()
        .or_else(|| defaults.runtime_dir.clone())
        .unwrap_or_else(|| default_runtime_dir(defaults))
}

pub fn build_launch_config(options: &PlanOptions, defaults: &PlanDefaults) -> LaunchConfig {
    let runtime_dir = resolve_plan_runtime_dir(options, defaults);
    let workspace = options
        .workspace
        .clone()
        .unwrap_or_else(|| defaults.cwd.clone());
    let cache_dir = options
        .cache_dir
        .clone()
        .or_else(|| defaults.cache_dir.clone())
        .unwrap_or_else(|| defaults.fend_home.join("cache/npm"));
    let tools_dir = options
        .tools_dir
        .clone()
        .or_else(|| defaults.tools_dir.clone())
        .unwrap_or_else(|| defaults.fend_home.join("tools"));
    let run_dir = options
        .run_dir
        .clone()
        .or_else(|| defaults.run_dir.clone())
        .unwrap_or_else(|| defaults.temp_dir.join("fend-linux"));
    let mut config = LaunchConfig::new(
        RuntimeArtifacts::from_runtime_dir(runtime_dir),
        workspace,
        cache_dir,
        tools_dir,
        run_dir,
        options.epoch.unwrap_or(defaults.epoch),
    );
    config.guest_cid = options.guest_cid.or(defaults.guest_cid).unwrap_or(42);
    config.cpus = options.cpus.or(defaults.cpus).unwrap_or(2);
    config.memory_mib = options.memory_mib.or(defaults.memory_mib).unwrap_or(2048);
    config.network = options
        .network
        .or(defaults.network)
        .unwrap_or(NetworkMode::Passt);
    config.guest_workspace = options.guest_workspace.clone();
    config
}

pub fn build_supervised_launch_config(
    options: &PlanOptions,
    defaults: &PlanDefaults,
) -> LaunchConfig {
    let mut config = build_launch_config(options, defaults);
    if options.run_dir.is_none() && defaults.run_dir.is_none() {
        config.run_dir = defaults.temp_dir.join(format!(
            "fend-linux.{}.{}",
            std::process::id(),
            defaults.epoch
        ));
    }
    config
}

pub fn render_doctor_report(report: &DoctorReport) -> String {
    let mut output = String::new();
    let width = report
        .fields
        .iter()
        .map(|(label, _)| label.len())
        .max()
        .unwrap_or(0);

    writeln!(&mut output, "{}", report.title).unwrap();
    for (label, value) in &report.fields {
        writeln!(&mut output, "  {label:<width$}  {value}").unwrap();
    }

    if report.issues.is_empty() {
        writeln!(&mut output).unwrap();
        writeln!(&mut output, "{}", report.ok_message).unwrap();
    } else {
        writeln!(&mut output).unwrap();
        writeln!(&mut output, "issues").unwrap();
        for issue in &report.issues {
            writeln!(&mut output, "  - {issue}").unwrap();
        }
    }

    output
}

pub fn render_launch_plan(plan: &LaunchPlan) -> String {
    let mut output = String::new();
    writeln!(&mut output, "fend linux launch plan").unwrap();
    writeln!(&mut output).unwrap();
    writeln!(&mut output, "virtiofsd").unwrap();
    for share in &plan.shares {
        let args = share.virtiofsd_args();
        let command = shell_command(share.virtiofsd_program(), &args);
        writeln!(
            &mut output,
            "  {name:<9} {command} > {log} 2>&1",
            name = share.name,
            log = shell_quote_path(&share.log)
        )
        .unwrap();
    }

    writeln!(&mut output).unwrap();
    writeln!(&mut output, "qemu").unwrap();
    writeln!(
        &mut output,
        "  {}",
        shell_command(plan.qemu_program, &plan.qemu_args)
    )
    .unwrap();
    output
}

pub fn shell_command(program: &str, args: &[String]) -> String {
    std::iter::once(shell_quote(program))
        .chain(args.iter().map(|arg| shell_quote(arg)))
        .collect::<Vec<_>>()
        .join(" ")
}

fn parse_doctor(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    let mut options = DoctorOptions::default();
    while let Some(arg) = args.pop_front() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(CliCommand::Help(HelpTopic::Doctor)),
            "--runtime-dir" => options.runtime_dir = Some(value_path(&mut args, "--runtime-dir")?),
            other if other.starts_with('-') => return Err(CliError::UnknownOption(arg)),
            _ => return Err(CliError::UnexpectedArgument(arg)),
        }
    }
    Ok(CliCommand::Doctor(options))
}

fn parse_plan(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    match parse_plan_options(&mut args, HelpTopic::Plan) {
        Ok(options) => Ok(CliCommand::Plan(options)),
        Err(CliError::HelpRequested(topic)) => Ok(CliCommand::Help(topic)),
        Err(error) => Err(error),
    }
}

fn parse_launch(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    match parse_plan_options(&mut args, HelpTopic::Launch) {
        Ok(options) => Ok(CliCommand::Launch(options)),
        Err(CliError::HelpRequested(topic)) => Ok(CliCommand::Help(topic)),
        Err(error) => Err(error),
    }
}

fn parse_plan_options(
    args: &mut VecDeque<String>,
    help_topic: HelpTopic,
) -> Result<PlanOptions, CliError> {
    let mut options = PlanOptions::default();
    while let Some(arg) = args.pop_front() {
        match arg.as_str() {
            "-h" | "--help" => return Err(CliError::HelpRequested(help_topic)),
            "--runtime-dir" => options.runtime_dir = Some(value_path(args, "--runtime-dir")?),
            "--workspace" => options.workspace = Some(value_path(args, "--workspace")?),
            "--cache-dir" => options.cache_dir = Some(value_path(args, "--cache-dir")?),
            "--tools-dir" => options.tools_dir = Some(value_path(args, "--tools-dir")?),
            "--run-dir" => options.run_dir = Some(value_path(args, "--run-dir")?),
            "--cid" => options.guest_cid = Some(value_number(args, "--cid")?),
            "--cpus" => options.cpus = Some(value_number(args, "--cpus")?),
            "--memory-mib" => options.memory_mib = Some(value_number(args, "--memory-mib")?),
            "--network" => {
                let value = value(args, "--network")?;
                options.network = Some(network_mode_from_str(&value)?);
            }
            "--epoch" => options.epoch = Some(value_number(args, "--epoch")?),
            "--guest-workspace" => {
                options.guest_workspace = value(args, "--guest-workspace")?;
            }
            other if other.starts_with('-') => return Err(CliError::UnknownOption(arg)),
            _ => {
                if options.workspace.is_some() {
                    return Err(CliError::UnexpectedArgument(arg));
                }
                options.workspace = Some(PathBuf::from(arg));
            }
        }
    }
    Ok(options)
}

fn value(args: &mut VecDeque<String>, option: &'static str) -> Result<String, CliError> {
    args.pop_front().ok_or(CliError::MissingValue(option))
}

fn value_path(args: &mut VecDeque<String>, option: &'static str) -> Result<PathBuf, CliError> {
    Ok(PathBuf::from(value(args, option)?))
}

fn value_number<T>(args: &mut VecDeque<String>, option: &'static str) -> Result<T, CliError>
where
    T: std::str::FromStr,
{
    let value = value(args, option)?;
    value.parse().map_err(|_| CliError::InvalidNumber {
        option,
        value: value.clone(),
    })
}

fn env_path(name: &str) -> Option<PathBuf> {
    env::var_os(name)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn env_number<T>(name: &str, option: &'static str) -> Result<Option<T>, CliError>
where
    T: std::str::FromStr,
{
    let Some(value) = env::var_os(name).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    let value = value.to_string_lossy().to_string();
    value
        .parse()
        .map(Some)
        .map_err(|_| CliError::InvalidNumber {
            option,
            value: value.clone(),
        })
}

fn env_network(name: &str) -> Result<Option<NetworkMode>, CliError> {
    let Some(value) = env::var_os(name).filter(|value| !value.is_empty()) else {
        return Ok(None);
    };
    network_mode_from_str(&value.to_string_lossy()).map(Some)
}

fn network_mode_from_str(value: &str) -> Result<NetworkMode, CliError> {
    match value {
        "passt" => Ok(NetworkMode::Passt),
        "user" => Ok(NetworkMode::User),
        "off" => Ok(NetworkMode::Off),
        _ => Err(CliError::InvalidNetwork(value.to_string())),
    }
}

fn current_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs() as i64)
        .unwrap_or(0)
}

fn shell_quote_path(path: &Path) -> String {
    shell_quote(&path.display().to_string())
}

fn shell_quote(value: &str) -> String {
    if value.is_empty() {
        return "''".to_string();
    }
    if value.bytes().all(|byte| {
        byte.is_ascii_alphanumeric()
            || matches!(byte, b'_' | b'-' | b'.' | b'/' | b':' | b'=' | b',' | b'+')
    }) {
        return value.to_string();
    }
    format!("'{}'", value.replace('\'', "'\\''"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::doctor::{DeviceStatus, HostProbe};
    use crate::qemu::build_launch_plan;

    #[test]
    fn parses_plan_with_positional_workspace_and_overrides() {
        let command = parse_args([
            "plan",
            "/repo/app",
            "--runtime-dir",
            "/runtime",
            "--cache-dir",
            "/cache",
            "--tools-dir",
            "/tools",
            "--run-dir",
            "/run",
            "--cid",
            "55",
            "--cpus",
            "6",
            "--memory-mib",
            "8192",
            "--network",
            "user",
            "--epoch",
            "99",
            "--guest-workspace",
            "/workspace/app",
        ])
        .unwrap();

        let CliCommand::Plan(options) = command else {
            panic!("expected plan command");
        };
        assert_eq!(options.workspace, Some(PathBuf::from("/repo/app")));
        assert_eq!(options.runtime_dir, Some(PathBuf::from("/runtime")));
        assert_eq!(options.cache_dir, Some(PathBuf::from("/cache")));
        assert_eq!(options.tools_dir, Some(PathBuf::from("/tools")));
        assert_eq!(options.run_dir, Some(PathBuf::from("/run")));
        assert_eq!(options.guest_cid, Some(55));
        assert_eq!(options.cpus, Some(6));
        assert_eq!(options.memory_mib, Some(8192));
        assert_eq!(options.network, Some(NetworkMode::User));
        assert_eq!(options.epoch, Some(99));
        assert_eq!(options.guest_workspace, "/workspace/app");
    }

    #[test]
    fn parses_launch_with_command_specific_help() {
        assert_eq!(
            parse_args(["launch", "--help"]).unwrap(),
            CliCommand::Help(HelpTopic::Launch)
        );

        let command = parse_args(["launch", "/repo/app", "--network", "off"]).unwrap();
        let CliCommand::Launch(options) = command else {
            panic!("expected launch command");
        };
        assert_eq!(options.workspace, Some(PathBuf::from("/repo/app")));
        assert_eq!(options.network, Some(NetworkMode::Off));
    }

    #[test]
    fn rejects_invalid_cli_values() {
        assert_eq!(
            parse_args(["plan", "--network", "bridge"]).unwrap_err(),
            CliError::InvalidNetwork("bridge".to_string())
        );
        assert_eq!(
            parse_args(["plan", "--cpus", "many"]).unwrap_err(),
            CliError::InvalidNumber {
                option: "--cpus",
                value: "many".to_string()
            }
        );
        assert_eq!(
            parse_args(["doctor", "--runtime-dir"]).unwrap_err(),
            CliError::MissingValue("--runtime-dir")
        );
    }

    #[test]
    fn builds_launch_config_from_options_and_defaults() {
        let defaults = sample_defaults();
        let options = PlanOptions {
            workspace: Some(PathBuf::from("/repo/app")),
            network: Some(NetworkMode::Off),
            ..PlanOptions::default()
        };

        let config = build_launch_config(&options, &defaults);

        assert_eq!(
            config.artifacts,
            RuntimeArtifacts::from_runtime_dir("/home/user/.fend/runtime/linux-x86_64")
        );
        assert_eq!(config.workspace, PathBuf::from("/repo/app"));
        assert_eq!(
            config.cache_dir,
            PathBuf::from("/home/user/.fend/cache/npm")
        );
        assert_eq!(config.tools_dir, PathBuf::from("/home/user/.fend/tools"));
        assert_eq!(config.run_dir, PathBuf::from("/tmp/fend-linux"));
        assert_eq!(config.guest_cid, 42);
        assert_eq!(config.cpus, 2);
        assert_eq!(config.memory_mib, 2048);
        assert_eq!(config.network, NetworkMode::Off);
        assert_eq!(config.epoch, 1234);
    }

    #[test]
    fn resolves_plan_runtime_dir_with_option_env_then_default_precedence() {
        let defaults = PlanDefaults {
            runtime_dir: Some(PathBuf::from("/env/runtime")),
            ..sample_defaults()
        };

        assert_eq!(
            resolve_plan_runtime_dir(
                &PlanOptions {
                    runtime_dir: Some(PathBuf::from("/option/runtime")),
                    ..PlanOptions::default()
                },
                &defaults
            ),
            PathBuf::from("/option/runtime")
        );
        assert_eq!(
            resolve_plan_runtime_dir(&PlanOptions::default(), &defaults),
            PathBuf::from("/env/runtime")
        );
        assert_eq!(
            resolve_plan_runtime_dir(&PlanOptions::default(), &sample_defaults()),
            PathBuf::from("/home/user/.fend/runtime/linux-x86_64")
        );
    }

    #[test]
    fn supervised_launch_config_uses_unique_run_dir_by_default() {
        let defaults = sample_defaults();
        let config = build_supervised_launch_config(&PlanOptions::default(), &defaults);

        assert_eq!(
            config.run_dir,
            PathBuf::from(format!("/tmp/fend-linux.{}.1234", std::process::id()))
        );
    }

    #[test]
    fn renders_doctor_report_with_actionable_issues() {
        let report = crate::doctor::evaluate(&HostProbe {
            os: "linux".to_string(),
            arch: "x86_64".to_string(),
            runtime_dir: PathBuf::from("/runtime"),
            kernel_exists: false,
            initrd_exists: true,
            rootfs_exists: true,
            qemu_available: true,
            virtiofsd_available: true,
            passt_available: false,
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
        });

        let rendered = render_doctor_report(&report);

        assert!(rendered.contains("fend linux doctor"));
        assert!(rendered.contains("passt"));
        assert!(rendered.contains("Install passt"));
        assert!(!rendered.contains("Run scripts/prepare-linux_x86_64-runtime.sh"));
        assert!(rendered.contains("Run scripts/prepare-linux-x86_64-runtime.sh"));
    }

    #[test]
    fn renders_launch_plan_with_shell_quoted_paths() {
        let defaults = sample_defaults();
        let options = PlanOptions {
            workspace: Some(PathBuf::from("/repo/app with spaces")),
            run_dir: Some(PathBuf::from("/tmp/fend run")),
            epoch: Some(7),
            ..PlanOptions::default()
        };
        let config = build_launch_config(&options, &defaults);
        let plan = build_launch_plan(&config).unwrap();

        let rendered = render_launch_plan(&plan);

        assert!(rendered.contains("fend linux launch plan"));
        assert!(rendered.contains("'--socket-path=/tmp/fend run/workspace.sock'"));
        assert!(rendered.contains("'source=/repo/app with spaces'"));
        assert!(rendered.contains("qemu-system-x86_64"));
        assert!(rendered.contains("'socket,id=char-workspace,path=/tmp/fend run/workspace.sock'"));
    }

    #[test]
    fn shell_quote_keeps_safe_args_readable_and_quotes_spaces() {
        assert_eq!(shell_quote("qemu-system-x86_64"), "qemu-system-x86_64");
        assert_eq!(shell_quote("/tmp/fend run"), "'/tmp/fend run'");
        assert_eq!(shell_quote("it's"), "'it'\\''s'");
    }

    fn sample_defaults() -> PlanDefaults {
        PlanDefaults {
            fend_home: PathBuf::from("/home/user/.fend"),
            cwd: PathBuf::from("/repo/default"),
            temp_dir: PathBuf::from("/tmp"),
            runtime_dir: None,
            cache_dir: None,
            tools_dir: None,
            run_dir: None,
            guest_cid: None,
            cpus: None,
            memory_mib: None,
            network: None,
            epoch: 1234,
        }
    }
}
