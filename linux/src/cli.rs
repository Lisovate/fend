use std::collections::{BTreeMap, VecDeque};
use std::env;
use std::fmt;
use std::fmt::Write as _;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use crate::bootstrap::{default_work_dir, BootstrapOptions};
use crate::doctor::DoctorReport;
use crate::qemu::{LaunchConfig, LaunchPlan, NetworkMode, RuntimeArtifacts};
use crate::smoke::{
    SmokeConfig, DEFAULT_MAX_OUTPUT_BYTES, DEFAULT_SMOKE_TIMEOUT, DEFAULT_VSOCK_PORT,
};
use crate::tools::resolve_virtiofsd;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CliCommand {
    Help(HelpTopic),
    Doctor(DoctorOptions),
    Setup(SetupOptions),
    Plan(PlanOptions),
    Launch(PlanOptions),
    Run(RunOptions),
    Stop(StopOptions),
    Smoke(SmokeOptions),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelpTopic {
    General,
    Doctor,
    Setup,
    Plan,
    Launch,
    Run,
    Stop,
    Smoke,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct DoctorOptions {
    pub runtime_dir: Option<PathBuf>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct SetupOptions {
    pub runtime_dir: Option<PathBuf>,
    pub work_dir: Option<PathBuf>,
    pub rebuild_rootfs: bool,
    pub force_downloads: bool,
    pub skip_claude: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct StopOptions {
    pub run_dir: Option<PathBuf>,
    pub timeout_secs: Option<u64>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CommandNetworkMode {
    On,
    Off,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct RunOptions {
    pub runtime_dir: Option<PathBuf>,
    pub workspace: Option<PathBuf>,
    pub cache_dir: Option<PathBuf>,
    pub tools_dir: Option<PathBuf>,
    pub run_dir: Option<PathBuf>,
    pub guest_cid: Option<u32>,
    pub cpus: Option<u16>,
    pub memory_mib: Option<u32>,
    pub vm_network: Option<NetworkMode>,
    pub timeout_secs: Option<u64>,
    pub cwd: Option<String>,
    pub env: BTreeMap<String, String>,
    pub network: Option<CommandNetworkMode>,
    pub command: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmokeOptions {
    pub cid: Option<u32>,
    pub port: Option<u32>,
    pub timeout_secs: Option<u64>,
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    pub command: Vec<String>,
}

impl Default for SmokeOptions {
    fn default() -> Self {
        Self {
            cid: None,
            port: None,
            timeout_secs: None,
            cwd: "/workspace".to_string(),
            env: BTreeMap::new(),
            command: Vec::new(),
        }
    }
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
    MissingCommand,
    UnexpectedArgument(String),
    InvalidEnv(String),
    InvalidNetwork(String),
    InvalidCommandNetwork(String),
    InvalidNumber { option: &'static str, value: String },
    HelpRequested(HelpTopic),
}

impl fmt::Display for CliError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::UnknownCommand(command) => write!(f, "unknown command: {command}"),
            Self::UnknownOption(option) => write!(f, "unknown option: {option}"),
            Self::MissingValue(option) => write!(f, "missing value for {option}"),
            Self::MissingCommand => write!(f, "no command specified"),
            Self::UnexpectedArgument(argument) => write!(f, "unexpected argument: {argument}"),
            Self::InvalidEnv(value) => write!(f, "invalid env value {value:?}; use KEY=VALUE"),
            Self::InvalidNetwork(value) => {
                write!(f, "invalid network mode {value:?}; use passt, user, or off")
            }
            Self::InvalidCommandNetwork(value) => {
                write!(f, "invalid command network mode {value:?}; use on or off")
            }
            Self::InvalidNumber { option, value } => {
                write!(f, "invalid numeric value for {option}: {value:?}")
            }
            Self::HelpRequested(_) => write!(f, "help requested"),
        }
    }
}

impl std::error::Error for CliError {}

pub fn usage() -> String {
    usage_for("fend-linux")
}

pub fn usage_for(program: &str) -> String {
    format!(
        "usage: {program} <subcommand> [options]\n       {program} [run options] -- <command> [args...]\n       {program} [run options] <command> [args...]\n\nsubcommands:\n  doctor      Check Linux host prerequisites and runtime artifacts.\n  setup       Prepare Linux runtime artifacts in ~/.fend/runtime.\n  plan        Print the QEMU and virtiofsd launch plan without starting a VM.\n  launch      Start virtiofsd sidecars and QEMU from the Rust Linux host path.\n  run         Launch a disposable VM, run one command, and tear it down.\n  stop        Stop a running QEMU/virtiofsd stack from its run dir.\n  smoke       Verify host-to-fendd vsock command execution after a VM boots.\n\ncommon options:\n  -h, --help\n\nIf no subcommand is given, {program} treats the remaining arguments as a sandboxed command to run.\n"
    )
}

pub fn doctor_usage() -> String {
    doctor_usage_for("fend-linux")
}

pub fn doctor_usage_for(program: &str) -> String {
    format!(
        "usage: {program} doctor [--runtime-dir path]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n                         Default: $FEND_RUNTIME_DIR or $FEND_HOME/runtime/linux-x86_64.\n"
    )
}

pub fn setup_usage() -> String {
    setup_usage_for("fend-linux")
}

pub fn setup_usage_for(program: &str) -> String {
    format!(
        "usage: {program} setup [options]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n  --work-dir path        Temporary work dir for downloads and Docker build context.\n  --rebuild-rootfs       Rebuild rootfs.img even if it already exists.\n  --force-downloads      Re-download kernel/initrd even if they already exist.\n  --skip-claude          Skip the optional Claude guest tool download.\n\nThis is usually automatic on first run; use it when you want to prewarm or debug Linux setup.\n"
    )
}

pub fn plan_usage() -> String {
    plan_usage_for("fend-linux")
}

pub fn plan_usage_for(program: &str) -> String {
    format!(
        "usage: {program} plan [workspace] [options]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n  --workspace path       Host project directory. Positional workspace is also accepted.\n  --cache-dir path       Host package-manager cache mount.\n  --tools-dir path       Host tool cache mount.\n  --run-dir path         Directory for QEMU and virtiofsd sockets/logs.\n  --cid n                Guest vsock CID. Default: 42.\n  --cpus n               vCPU count. Default: 2.\n  --memory-mib n         Memory in MiB. Default: 2048.\n  --network mode         passt, user, or off. Default: passt.\n  --epoch n              Epoch value passed to the guest.\n  --guest-workspace path Guest workspace path. Default: /workspace.\n"
    )
}

pub fn launch_usage() -> String {
    launch_usage_for("fend-linux")
}

pub fn launch_usage_for(program: &str) -> String {
    format!(
        "usage: {program} launch [workspace] [options]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n  --workspace path       Host project directory. Positional workspace is also accepted.\n  --cache-dir path       Host package-manager cache mount.\n  --tools-dir path       Host tool cache mount.\n  --run-dir path         Directory for QEMU and virtiofsd sockets/logs.\n  --cid n                Guest vsock CID. Default: 42.\n  --cpus n               vCPU count. Default: 2.\n  --memory-mib n         Memory in MiB. Default: 2048.\n  --network mode         passt, user, or off. Default: passt.\n  --epoch n              Epoch value passed to the guest.\n  --guest-workspace path Guest workspace path. Default: /workspace.\n"
    )
}

pub fn run_usage() -> String {
    run_usage_for("fend-linux")
}

pub fn run_usage_for(program: &str) -> String {
    format!(
        "usage: {program} run [options] -- <command> [args...]\n       {program} [options] <command> [args...]\n\noptions:\n  --runtime-dir path     Runtime dir containing vmlinuz, initrd, rootfs.img.\n  --workspace path       Host project directory to mount. Default: current directory.\n  --cache-dir path       Host package-manager cache mount.\n  --tools-dir path       Host tool cache mount.\n  --run-dir path         Directory for QEMU and virtiofsd sockets/logs.\n  --cid n                Guest vsock CID. Default: autogenerated per run.\n  --cpus n               vCPU count. Default: 2.\n  --memory-mib n         Memory in MiB. Default: 2048.\n  --vm-network mode      passt, user, or off. Default: passt.\n  --network mode         Command network policy: on or off. Default: on.\n  --timeout sec          Wait for fendd session startup. Default: 30.\n  --cwd path             Guest working directory. Default: /workspace.\n  --env KEY=VALUE        Extra environment variable for the guest command.\n\nThis path is disposable: it boots a VM, runs one command with live output, forwards guest ports to localhost, and tears the VM down when the command exits.\n"
    )
}

pub fn stop_usage() -> String {
    stop_usage_for("fend-linux")
}

pub fn stop_usage_for(program: &str) -> String {
    format!(
        "usage: {program} stop [options]\n\noptions:\n  --run-dir path         Directory containing qemu.pid and virtiofsd pid files.\n                         Default: $FEND_RUN_DIR or /tmp/fend-linux.\n  --timeout sec          Grace period before SIGKILL. Default: 3.\n\nIf launch used an autogenerated run dir, pass the path printed in launch output.\n"
    )
}

pub fn smoke_usage() -> String {
    smoke_usage_for("fend-linux")
}

pub fn smoke_usage_for(program: &str) -> String {
    format!(
        "usage: {program} smoke [options] [-- command [args...]]\n\noptions:\n  --cid n          Guest vsock CID. Default: $FEND_QEMU_CID or 42.\n  --port n         fendd command vsock port. Default: 1024.\n  --timeout sec    Wait for fendd to become reachable. Default: 30.\n  --cwd path       Guest working directory. Default: /workspace.\n  --env KEY=VALUE  Extra environment variable for the smoke command.\n\nIf command is omitted, {program} runs: /bin/echo fend-linux-ok\n"
    )
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
        "setup" => parse_setup(args),
        "plan" => parse_plan(args),
        "launch" => parse_launch(args),
        "run" => parse_run(args),
        "stop" => parse_stop(args),
        "smoke" => parse_smoke(args),
        _ => {
            args.push_front(command);
            parse_run(args)
        }
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

fn default_runtime_dir(defaults: &PlanDefaults) -> PathBuf {
    defaults.fend_home.join("runtime/linux-x86_64")
}

pub fn resolve_doctor_runtime_dir(options: &DoctorOptions, defaults: &PlanDefaults) -> PathBuf {
    options
        .runtime_dir
        .clone()
        .or_else(|| defaults.runtime_dir.clone())
        .unwrap_or_else(|| default_runtime_dir(defaults))
}

pub fn resolve_setup_runtime_dir(options: &SetupOptions, defaults: &PlanDefaults) -> PathBuf {
    options
        .runtime_dir
        .clone()
        .or_else(|| defaults.runtime_dir.clone())
        .unwrap_or_else(|| default_runtime_dir(defaults))
}

pub fn build_bootstrap_options(
    options: &SetupOptions,
    defaults: &PlanDefaults,
) -> BootstrapOptions {
    let runtime_dir = resolve_setup_runtime_dir(options, defaults);
    let tools_dir = defaults
        .tools_dir
        .clone()
        .unwrap_or_else(|| defaults.fend_home.join("tools"));

    BootstrapOptions {
        runtime_dir,
        work_dir: options
            .work_dir
            .clone()
            .unwrap_or_else(|| default_work_dir(&defaults.fend_home)),
        tools_dir,
        rebuild_rootfs: options.rebuild_rootfs,
        force_downloads: options.force_downloads,
        skip_claude: options.skip_claude,
        verbose: true,
    }
}

pub fn resolve_plan_runtime_dir(options: &PlanOptions, defaults: &PlanDefaults) -> PathBuf {
    options
        .runtime_dir
        .clone()
        .or_else(|| defaults.runtime_dir.clone())
        .unwrap_or_else(|| default_runtime_dir(defaults))
}

pub fn resolve_stop_run_dir(options: &StopOptions, defaults: &PlanDefaults) -> PathBuf {
    options
        .run_dir
        .clone()
        .or_else(|| defaults.run_dir.clone())
        .unwrap_or_else(|| defaults.temp_dir.join("fend-linux"))
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
    if let Some(virtiofsd) = resolve_virtiofsd() {
        config.virtiofsd = virtiofsd;
    }
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

pub fn build_run_launch_config(options: &RunOptions, defaults: &PlanDefaults) -> LaunchConfig {
    let plan_options = PlanOptions {
        runtime_dir: options.runtime_dir.clone(),
        workspace: options.workspace.clone(),
        cache_dir: options.cache_dir.clone(),
        tools_dir: options.tools_dir.clone(),
        run_dir: options.run_dir.clone(),
        guest_cid: options.guest_cid,
        cpus: options.cpus,
        memory_mib: options.memory_mib,
        network: options.vm_network,
        epoch: None,
        guest_workspace: "/workspace".to_string(),
    };
    let mut config = build_supervised_launch_config(&plan_options, defaults);
    if options.guest_cid.is_none() && defaults.guest_cid.is_none() {
        config.guest_cid = autogenerated_guest_cid(defaults.epoch, std::process::id());
    }
    config
}

fn autogenerated_guest_cid(epoch: i64, pid: u32) -> u32 {
    const BASE: u32 = 10_000;
    const SPAN: u32 = 50_000;

    let seed = (epoch as u64)
        .wrapping_mul(1_103_515_245)
        .wrapping_add(pid as u64);
    BASE + (seed % SPAN as u64) as u32
}

pub fn build_run_smoke_config(options: &RunOptions, config: &LaunchConfig) -> SmokeConfig {
    let mut env = options.env.clone();
    if matches!(options.network, Some(CommandNetworkMode::Off)) {
        env.insert("FEND_NETWORK_MODE".to_string(), "off".to_string());
    }

    SmokeConfig {
        cid: config.guest_cid,
        port: DEFAULT_VSOCK_PORT,
        timeout: options
            .timeout_secs
            .map(Duration::from_secs)
            .unwrap_or(DEFAULT_SMOKE_TIMEOUT),
        max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
        cwd: options
            .cwd
            .clone()
            .unwrap_or_else(|| config.guest_workspace.clone()),
        env,
        command: options.command.clone(),
    }
}

pub fn build_smoke_config(options: &SmokeOptions, defaults: &PlanDefaults) -> SmokeConfig {
    let command = if options.command.is_empty() {
        vec!["/bin/echo".to_string(), "fend-linux-ok".to_string()]
    } else {
        options.command.clone()
    };

    SmokeConfig {
        cid: options.cid.or(defaults.guest_cid).unwrap_or(42),
        port: options.port.unwrap_or(DEFAULT_VSOCK_PORT),
        timeout: options
            .timeout_secs
            .map(Duration::from_secs)
            .unwrap_or(DEFAULT_SMOKE_TIMEOUT),
        max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
        cwd: options.cwd.clone(),
        env: options.env.clone(),
        command,
    }
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
        let (program, args) = share.virtiofsd_command();
        let command = shell_command(&program, &args);
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

pub fn render_launch_summary(config: &LaunchConfig) -> String {
    let runtime_dir = config
        .artifacts
        .kernel
        .parent()
        .unwrap_or_else(|| Path::new("."));
    let mut output = String::new();
    writeln!(&mut output, "fend linux launch").unwrap();
    writeln!(&mut output, "  workspace  {}", config.workspace.display()).unwrap();
    writeln!(&mut output, "  runtime    {}", runtime_dir.display()).unwrap();
    writeln!(&mut output, "  run dir    {}", config.run_dir.display()).unwrap();
    writeln!(
        &mut output,
        "  logs       {}",
        config.run_dir.join("logs").display()
    )
    .unwrap();
    writeln!(&mut output, "  cid        {}", config.guest_cid).unwrap();
    writeln!(&mut output, "  network    {}", config.network).unwrap();
    writeln!(
        &mut output,
        "  stop       fend-linux stop --run-dir {}",
        shell_quote_path(&config.run_dir)
    )
    .unwrap();
    output
}

fn shell_command(program: &str, args: &[String]) -> String {
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

fn parse_setup(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    let mut options = SetupOptions::default();
    while let Some(arg) = args.pop_front() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(CliCommand::Help(HelpTopic::Setup)),
            "--runtime-dir" => options.runtime_dir = Some(value_path(&mut args, "--runtime-dir")?),
            "--work-dir" => options.work_dir = Some(value_path(&mut args, "--work-dir")?),
            "--rebuild-rootfs" => options.rebuild_rootfs = true,
            "--force-downloads" => options.force_downloads = true,
            "--skip-claude" => options.skip_claude = true,
            other if other.starts_with('-') => return Err(CliError::UnknownOption(arg)),
            _ => return Err(CliError::UnexpectedArgument(arg)),
        }
    }
    Ok(CliCommand::Setup(options))
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

fn parse_run(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    let mut options = RunOptions::default();
    while let Some(arg) = args.pop_front() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(CliCommand::Help(HelpTopic::Run)),
            "--runtime-dir" => options.runtime_dir = Some(value_path(&mut args, "--runtime-dir")?),
            "--workspace" => options.workspace = Some(value_path(&mut args, "--workspace")?),
            "--cache-dir" => options.cache_dir = Some(value_path(&mut args, "--cache-dir")?),
            "--tools-dir" => options.tools_dir = Some(value_path(&mut args, "--tools-dir")?),
            "--run-dir" => options.run_dir = Some(value_path(&mut args, "--run-dir")?),
            "--cid" => options.guest_cid = Some(value_number(&mut args, "--cid")?),
            "--cpus" => options.cpus = Some(value_number(&mut args, "--cpus")?),
            "--memory-mib" => options.memory_mib = Some(value_number(&mut args, "--memory-mib")?),
            "--vm-network" => {
                let value = value(&mut args, "--vm-network")?;
                options.vm_network = Some(network_mode_from_str(&value)?);
            }
            "--network" => {
                let value = value(&mut args, "--network")?;
                options.network = Some(command_network_mode_from_str(&value)?);
            }
            "--timeout" => options.timeout_secs = Some(value_number(&mut args, "--timeout")?),
            "--cwd" => options.cwd = Some(value(&mut args, "--cwd")?),
            "--env" => {
                let item = value(&mut args, "--env")?;
                let (key, value) = item
                    .split_once('=')
                    .ok_or_else(|| CliError::InvalidEnv(item.clone()))?;
                if key.is_empty() {
                    return Err(CliError::InvalidEnv(item));
                }
                options.env.insert(key.to_string(), value.to_string());
            }
            "--" => {
                options.command.extend(args);
                break;
            }
            other if other.starts_with('-') => return Err(CliError::UnknownOption(arg)),
            _ => {
                options.command.push(arg);
                options.command.extend(args);
                break;
            }
        }
    }

    if options.command.is_empty() {
        return Err(CliError::MissingCommand);
    }

    Ok(CliCommand::Run(options))
}

fn parse_stop(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    let mut options = StopOptions::default();
    while let Some(arg) = args.pop_front() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(CliCommand::Help(HelpTopic::Stop)),
            "--run-dir" => options.run_dir = Some(value_path(&mut args, "--run-dir")?),
            "--timeout" => options.timeout_secs = Some(value_number(&mut args, "--timeout")?),
            other if other.starts_with('-') => return Err(CliError::UnknownOption(arg)),
            _ => return Err(CliError::UnexpectedArgument(arg)),
        }
    }
    Ok(CliCommand::Stop(options))
}

fn parse_smoke(mut args: VecDeque<String>) -> Result<CliCommand, CliError> {
    let mut options = SmokeOptions::default();
    while let Some(arg) = args.pop_front() {
        match arg.as_str() {
            "-h" | "--help" => return Ok(CliCommand::Help(HelpTopic::Smoke)),
            "--cid" => options.cid = Some(value_number(&mut args, "--cid")?),
            "--port" => options.port = Some(value_number(&mut args, "--port")?),
            "--timeout" => options.timeout_secs = Some(value_number(&mut args, "--timeout")?),
            "--cwd" => options.cwd = value(&mut args, "--cwd")?,
            "--env" => {
                let item = value(&mut args, "--env")?;
                let (key, value) = item
                    .split_once('=')
                    .ok_or_else(|| CliError::InvalidEnv(item.clone()))?;
                if key.is_empty() {
                    return Err(CliError::InvalidEnv(item));
                }
                options.env.insert(key.to_string(), value.to_string());
            }
            "--" => {
                options.command.extend(args);
                break;
            }
            other if other.starts_with('-') => return Err(CliError::UnknownOption(arg)),
            _ => {
                options.command.push(arg);
                options.command.extend(args);
                break;
            }
        }
    }
    Ok(CliCommand::Smoke(options))
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

fn command_network_mode_from_str(value: &str) -> Result<CommandNetworkMode, CliError> {
    match value {
        "on" => Ok(CommandNetworkMode::On),
        "off" => Ok(CommandNetworkMode::Off),
        _ => Err(CliError::InvalidCommandNetwork(value.to_string())),
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
    fn parses_default_run_command_with_options() {
        let command = parse_args([
            "--network",
            "off",
            "--vm-network",
            "user",
            "--timeout",
            "9",
            "--env",
            "KEY=VALUE",
            "npm",
            "install",
        ])
        .unwrap();

        let CliCommand::Run(options) = command else {
            panic!("expected run command");
        };

        assert_eq!(options.network, Some(CommandNetworkMode::Off));
        assert_eq!(options.vm_network, Some(NetworkMode::User));
        assert_eq!(options.timeout_secs, Some(9));
        assert_eq!(options.env.get("KEY").map(String::as_str), Some("VALUE"));
        assert_eq!(options.command, ["npm", "install"]);
    }

    #[test]
    fn parses_explicit_run_help() {
        assert_eq!(
            parse_args(["run", "--help"]).unwrap(),
            CliCommand::Help(HelpTopic::Run)
        );
    }

    #[test]
    fn parses_stop_with_options() {
        assert_eq!(
            parse_args(["stop", "--help"]).unwrap(),
            CliCommand::Help(HelpTopic::Stop)
        );

        let command = parse_args([
            "stop",
            "--run-dir",
            "/tmp/fend-linux-debug",
            "--timeout",
            "9",
        ])
        .unwrap();
        let CliCommand::Stop(options) = command else {
            panic!("expected stop command");
        };

        assert_eq!(
            options.run_dir,
            Some(PathBuf::from("/tmp/fend-linux-debug"))
        );
        assert_eq!(options.timeout_secs, Some(9));
    }

    #[test]
    fn parses_smoke_with_options_and_command_separator() {
        assert_eq!(
            parse_args(["smoke", "--help"]).unwrap(),
            CliCommand::Help(HelpTopic::Smoke)
        );

        let command = parse_args([
            "smoke",
            "--cid",
            "55",
            "--port",
            "2024",
            "--timeout",
            "5",
            "--cwd",
            "/workspace/app",
            "--env",
            "FEND_NETWORK_MODE=off",
            "--",
            "/bin/echo",
            "ok",
        ])
        .unwrap();
        let CliCommand::Smoke(options) = command else {
            panic!("expected smoke command");
        };

        assert_eq!(options.cid, Some(55));
        assert_eq!(options.port, Some(2024));
        assert_eq!(options.timeout_secs, Some(5));
        assert_eq!(options.cwd, "/workspace/app");
        assert_eq!(
            options.env.get("FEND_NETWORK_MODE").map(String::as_str),
            Some("off")
        );
        assert_eq!(options.command, ["/bin/echo", "ok"]);
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
        assert_eq!(
            parse_args(["smoke", "--env", "NOPE"]).unwrap_err(),
            CliError::InvalidEnv("NOPE".to_string())
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
    fn builds_smoke_config_with_defaults_and_overrides() {
        let defaults = PlanDefaults {
            guest_cid: Some(77),
            ..sample_defaults()
        };
        let config = build_smoke_config(&SmokeOptions::default(), &defaults);

        assert_eq!(config.cid, 77);
        assert_eq!(config.port, DEFAULT_VSOCK_PORT);
        assert_eq!(config.timeout, DEFAULT_SMOKE_TIMEOUT);
        assert_eq!(config.max_output_bytes, DEFAULT_MAX_OUTPUT_BYTES);
        assert_eq!(config.cwd, "/workspace");
        assert_eq!(config.command, ["/bin/echo", "fend-linux-ok"]);

        let options = SmokeOptions {
            cid: Some(99),
            port: Some(2048),
            timeout_secs: Some(3),
            cwd: "/tmp".to_string(),
            env: BTreeMap::from([("KEY".to_string(), "VALUE".to_string())]),
            command: vec!["/bin/true".to_string()],
        };
        let config = build_smoke_config(&options, &defaults);

        assert_eq!(config.cid, 99);
        assert_eq!(config.port, 2048);
        assert_eq!(config.timeout, Duration::from_secs(3));
        assert_eq!(config.cwd, "/tmp");
        assert_eq!(config.env.get("KEY").map(String::as_str), Some("VALUE"));
        assert_eq!(config.command, ["/bin/true"]);
    }

    #[test]
    fn builds_run_configs_with_command_network_override() {
        let defaults = sample_defaults();
        let options = RunOptions {
            workspace: Some(PathBuf::from("/repo/app")),
            vm_network: Some(NetworkMode::User),
            network: Some(CommandNetworkMode::Off),
            timeout_secs: Some(7),
            env: BTreeMap::from([("KEY".to_string(), "VALUE".to_string())]),
            command: vec!["/bin/echo".to_string(), "ok".to_string()],
            ..RunOptions::default()
        };

        let launch = build_run_launch_config(&options, &defaults);
        let smoke = build_run_smoke_config(&options, &launch);

        assert_eq!(launch.workspace, PathBuf::from("/repo/app"));
        assert_eq!(launch.network, NetworkMode::User);
        assert_eq!(
            launch.guest_cid,
            autogenerated_guest_cid(defaults.epoch, std::process::id())
        );
        assert_eq!(smoke.timeout, Duration::from_secs(7));
        assert_eq!(smoke.cwd, "/workspace");
        assert_eq!(smoke.env.get("KEY").map(String::as_str), Some("VALUE"));
        assert_eq!(
            smoke.env.get("FEND_NETWORK_MODE").map(String::as_str),
            Some("off")
        );
        assert_eq!(smoke.command, ["/bin/echo", "ok"]);
    }

    #[test]
    fn renders_doctor_report_with_actionable_issues() {
        let report = crate::doctor::evaluate(&HostProbe {
            os: "linux".to_string(),
            arch: "x86_64".to_string(),
            distribution: Some(crate::doctor::DistributionInfo {
                id: "arch".to_string(),
                version_id: None,
            }),
            runtime_dir: PathBuf::from("/runtime"),
            kernel_exists: false,
            initrd_exists: true,
            rootfs_exists: true,
            qemu_available: true,
            virtiofsd: Some(crate::tools::ResolvedVirtiofsd::direct(
                "/usr/bin/virtiofsd",
            )),
            unshare_available: true,
            subuid_configured: None,
            subgid_configured: None,
            passt_available: false,
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
        });

        let rendered = render_doctor_report(&report);

        assert!(rendered.contains("fend linux doctor"));
        assert!(rendered.contains("passt"));
        assert!(!rendered.contains("Install passt"));
        assert!(rendered.contains("Run `fend setup` to prepare Linux runtime artifacts."));
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
        let mut config = build_launch_config(&options, &defaults);
        config.virtiofsd = crate::tools::ResolvedVirtiofsd::direct("virtiofsd");
        let plan = build_launch_plan(&config).unwrap();

        let rendered = render_launch_plan(&plan);

        assert!(rendered.contains("fend linux launch plan"));
        assert!(rendered.contains("virtiofsd"));
        assert!(rendered.contains("'--socket-path=/tmp/fend run/workspace.sock'"));
        assert!(rendered.contains("'source=/repo/app with spaces'"));
        assert!(rendered.contains("qemu-system-x86_64"));
        assert!(rendered.contains("'socket,id=char-workspace,path=/tmp/fend run/workspace.sock'"));
    }

    #[test]
    fn renders_launch_summary_with_runtime_run_dir_and_network() {
        let defaults = sample_defaults();
        let config = build_supervised_launch_config(
            &PlanOptions {
                workspace: Some(PathBuf::from("/repo/app")),
                network: Some(NetworkMode::User),
                ..PlanOptions::default()
            },
            &defaults,
        );

        let rendered = render_launch_summary(&config);

        assert!(rendered.contains("fend linux launch"));
        assert!(rendered.contains("workspace  /repo/app"));
        assert!(rendered.contains("runtime    /home/user/.fend/runtime/linux-x86_64"));
        assert!(rendered.contains("run dir"));
        assert!(rendered.contains("logs"));
        assert!(rendered.contains("network    user"));
        assert!(rendered.contains("stop       fend-linux stop --run-dir"));
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
