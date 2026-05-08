use std::io::Write as _;
use std::path::Path;
use std::process::ExitCode;

use crate::cli::{
    build_launch_config, build_run_launch_config, build_run_smoke_config,
    build_supervised_launch_config, doctor_usage, launch_usage, parse_args, plan_defaults_from_env,
    plan_usage, render_doctor_report, render_launch_plan, render_launch_summary,
    resolve_doctor_runtime_dir, resolve_plan_runtime_dir, resolve_stop_run_dir, run_usage,
    smoke_usage, stop_usage, usage, CliCommand, HelpTopic,
};
use crate::doctor;
use crate::qemu;
use crate::smoke;
use crate::supervisor::{stop_run_dir, Supervisor, SupervisorOptions};

pub fn main_entry() -> ExitCode {
    match run(std::env::args().skip(1)) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::from(2)
        }
    }
}

pub fn run<I, S>(args: I) -> Result<ExitCode, String>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let command = parse_args(args).map_err(|error| format!("{error}\n\n{}", usage()))?;

    match command {
        CliCommand::Help(topic) => {
            print!(
                "{}",
                match topic {
                    HelpTopic::General => usage(),
                    HelpTopic::Doctor => doctor_usage(),
                    HelpTopic::Plan => plan_usage(),
                    HelpTopic::Launch => launch_usage(),
                    HelpTopic::Run => run_usage(),
                    HelpTopic::Stop => stop_usage(),
                    HelpTopic::Smoke => smoke_usage(),
                }
            );
            Ok(ExitCode::SUCCESS)
        }
        CliCommand::Doctor(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let runtime_dir = resolve_doctor_runtime_dir(&options, &defaults);
            let report = doctor::evaluate(&doctor::current_probe(runtime_dir));
            print!("{}", render_doctor_report(&report));
            if report.issues.is_empty() {
                Ok(ExitCode::SUCCESS)
            } else {
                Ok(ExitCode::FAILURE)
            }
        }
        CliCommand::Plan(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let config = build_launch_config(&options, &defaults);
            let plan = qemu::build_launch_plan(&config).map_err(|error| error.to_string())?;
            print!("{}", render_launch_plan(&plan));
            Ok(ExitCode::SUCCESS)
        }
        CliCommand::Launch(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let config = build_supervised_launch_config(&options, &defaults);
            let runtime_dir = resolve_plan_runtime_dir(&options, &defaults);
            let report =
                doctor::evaluate_launch(&doctor::current_launch_probe(runtime_dir), config.network);
            if !report.issues.is_empty() {
                eprint!("{}", render_doctor_report(&report));
                return Ok(ExitCode::FAILURE);
            }
            let plan = qemu::build_launch_plan(&config).map_err(|error| error.to_string())?;
            print!("{}", render_launch_summary(&config));
            println!();
            let mut supervisor = Supervisor::new(SupervisorOptions::default());
            let mut vm = supervisor
                .launch_plan(&plan)
                .map_err(|error| error.to_string())?;
            let status = vm.wait_for_qemu().map_err(|error| error.to_string())?;
            if status.code == Some(0) {
                Ok(ExitCode::SUCCESS)
            } else {
                Ok(ExitCode::FAILURE)
            }
        }
        CliCommand::Run(options) => run_disposable_command(&options),
        CliCommand::Stop(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let run_dir = resolve_stop_run_dir(&options, &defaults);
            let timeout = std::time::Duration::from_secs(options.timeout_secs.unwrap_or(3));
            let report = stop_run_dir(&run_dir, timeout).map_err(|error| error.to_string())?;
            println!("fend linux stop");
            println!("  run dir    {}", run_dir.display());
            println!("  stopped    {}", report.terminated.len());
            println!("  stale      {}", report.stale.len());
            if !report.terminated.is_empty() {
                println!("  labels     {}", report.terminated.join(", "));
            }
            if !report.stale.is_empty() {
                println!("  stale ids  {}", report.stale.join(", "));
            }
            Ok(ExitCode::SUCCESS)
        }
        CliCommand::Smoke(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let config = crate::cli::build_smoke_config(&options, &defaults);
            let result = smoke::run_smoke(&config).map_err(|error| error.to_string())?;
            std::io::stdout()
                .write_all(&result.stdout)
                .map_err(|error| error.to_string())?;
            std::io::stderr()
                .write_all(&result.stderr)
                .map_err(|error| error.to_string())?;
            if result.exit_code == 0 {
                eprintln!("ok    vsock smoke passed");
                Ok(ExitCode::SUCCESS)
            } else {
                eprintln!("fail  vsock smoke exited {}", result.exit_code);
                Ok(ExitCode::FAILURE)
            }
        }
    }
}

fn run_disposable_command(options: &crate::cli::RunOptions) -> Result<ExitCode, String> {
    let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
    let config = build_run_launch_config(options, &defaults);
    ensure_guest_tool_available(
        options.command.first().map(String::as_str),
        &config.tools_dir,
    )?;
    let runtime_dir = config
        .artifacts
        .kernel
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf();
    let report =
        doctor::evaluate_launch(&doctor::current_launch_probe(runtime_dir), config.network);
    if !report.issues.is_empty() {
        eprint!("{}", render_doctor_report(&report));
        return Ok(ExitCode::FAILURE);
    }

    let plan = qemu::build_launch_plan(&config).map_err(|error| error.to_string())?;
    let mut supervisor = Supervisor::new(SupervisorOptions::default());
    let _vm = supervisor
        .launch_plan(&plan)
        .map_err(|error| error.to_string())?;

    let smoke_config = build_run_smoke_config(options, &config);
    let result = smoke::run_smoke(&smoke_config).map_err(|error| error.to_string())?;
    std::io::stdout()
        .write_all(&result.stdout)
        .map_err(|error| error.to_string())?;
    std::io::stderr()
        .write_all(&result.stderr)
        .map_err(|error| error.to_string())?;
    Ok(exit_code_from_i32(result.exit_code))
}

fn exit_code_from_i32(code: i32) -> ExitCode {
    if code == 0 {
        ExitCode::SUCCESS
    } else {
        let clamped = code.clamp(1, u8::MAX as i32) as u8;
        ExitCode::from(clamped)
    }
}

fn ensure_guest_tool_available(command: Option<&str>, tools_dir: &Path) -> Result<(), String> {
    let Some(command) = command else {
        return Ok(());
    };
    if !requires_guest_tool(command) {
        return Ok(());
    }
    if guest_tool_exists(tools_dir, command) {
        return Ok(());
    }

    Err(format!(
        "guest tool {command:?} is not available in {}. Populate ~/.fend/tools with the Linux runtime toolchain before running {command}.",
        tools_dir.display()
    ))
}

fn requires_guest_tool(command: &str) -> bool {
    if command.contains('/') {
        return false;
    }
    matches!(
        command,
        "node" | "npm" | "npx" | "pnpm" | "pnpx" | "yarn" | "bun" | "bunx" | "claude"
    )
}

fn guest_tool_exists(tools_dir: &Path, name: &str) -> bool {
    let Ok(entries) = std::fs::read_dir(tools_dir) else {
        return false;
    };

    entries
        .flatten()
        .any(|entry| tool_entry_contains(&entry.path(), name))
}

fn tool_entry_contains(path: &Path, name: &str) -> bool {
    path.join("bin").join(name).exists() || path.join(name).exists()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn guest_tool_preflight_ignores_absolute_commands() {
        assert!(!requires_guest_tool("/bin/sh"));
    }

    #[test]
    fn guest_tool_preflight_recognizes_node_style_commands() {
        assert!(requires_guest_tool("npm"));
        assert!(requires_guest_tool("bun"));
        assert!(!requires_guest_tool("git"));
    }

    #[test]
    fn guest_tool_preflight_checks_tools_dir_layout() {
        let temp = TempDir::new("guest-tools");
        let node_dir = temp.path.join("node-22.0.0-linux-x64");
        std::fs::create_dir_all(node_dir.join("bin")).unwrap();
        std::fs::write(node_dir.join("bin/npm"), b"").unwrap();

        assert!(guest_tool_exists(&temp.path, "npm"));
        assert!(!guest_tool_exists(&temp.path, "pnpm"));
    }

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(name: &str) -> Self {
            let path =
                PathBuf::from("/tmp").join(format!("fend-linux-app-{name}-{}", std::process::id()));
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
