use std::io::Write as _;
use std::process::ExitCode;

use fend_linux::cli::{
    build_launch_config, build_supervised_launch_config, doctor_usage, launch_usage, parse_args,
    plan_defaults_from_env, plan_usage, render_doctor_report, render_launch_plan,
    render_launch_summary, resolve_doctor_runtime_dir, resolve_plan_runtime_dir,
    resolve_stop_run_dir, smoke_usage, stop_usage, usage, CliCommand, HelpTopic,
};
use fend_linux::doctor;
use fend_linux::qemu;
use fend_linux::smoke;
use fend_linux::supervisor::{stop_run_dir, Supervisor, SupervisorOptions};

fn main() -> ExitCode {
    match run() {
        Ok(code) => code,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::from(2)
        }
    }
}

fn run() -> Result<ExitCode, String> {
    let command =
        parse_args(std::env::args().skip(1)).map_err(|error| format!("{error}\n\n{}", usage()))?;

    match command {
        CliCommand::Help(topic) => {
            print!(
                "{}",
                match topic {
                    HelpTopic::General => usage(),
                    HelpTopic::Doctor => doctor_usage(),
                    HelpTopic::Plan => plan_usage(),
                    HelpTopic::Launch => launch_usage(),
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
            let config = fend_linux::cli::build_smoke_config(&options, &defaults);
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
