use std::io::Write as _;
use std::path::Path;
use std::process::ExitCode;

use crate::bootstrap;
use crate::cli::{
    build_bootstrap_options, build_launch_config, build_run_launch_config, build_run_smoke_config,
    build_supervised_launch_config, doctor_usage_for, launch_usage_for, parse_args,
    plan_defaults_from_env, plan_usage_for, render_doctor_report, render_launch_plan,
    render_launch_summary, resolve_doctor_runtime_dir, resolve_plan_runtime_dir,
    resolve_stop_run_dir, run_usage_for, setup_usage_for, smoke_usage_for, stop_usage_for,
    usage_for, CliCommand, HelpTopic, SetupOptions,
};
use crate::doctor;
use crate::qemu::{self, LaunchConfig, NetworkMode};
use crate::runtime;
use crate::session;
use crate::smoke;
use crate::supervisor::{stop_run_dir, ProcessIo, Supervisor, SupervisorOptions};

pub fn main_entry() -> ExitCode {
    main_entry_named("fend-linux")
}

pub fn main_entry_named(program: &str) -> ExitCode {
    match run(program, std::env::args().skip(1)) {
        Ok(code) => code,
        Err(error) => {
            eprintln!("error: {error}");
            ExitCode::from(2)
        }
    }
}

pub fn run<I, S>(program: &str, args: I) -> Result<ExitCode, String>
where
    I: IntoIterator<Item = S>,
    S: Into<String>,
{
    let command = parse_args(args).map_err(|error| format!("{error}\n\n{}", usage_for(program)))?;

    match command {
        CliCommand::Help(topic) => {
            print!(
                "{}",
                match topic {
                    HelpTopic::General => usage_for(program),
                    HelpTopic::Doctor => doctor_usage_for(program),
                    HelpTopic::Setup => setup_usage_for(program),
                    HelpTopic::Plan => plan_usage_for(program),
                    HelpTopic::Launch => launch_usage_for(program),
                    HelpTopic::Run => run_usage_for(program),
                    HelpTopic::Stop => stop_usage_for(program),
                    HelpTopic::Smoke => smoke_usage_for(program),
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
        CliCommand::Setup(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let bootstrap = build_bootstrap_options(&options, &defaults);
            let report = bootstrap::ensure_linux_runtime(&bootstrap)?;
            println!("fend setup");
            println!("  runtime    {}", bootstrap.runtime_dir.display());
            println!("  work dir   {}", bootstrap.work_dir.display());
            println!("  metadata   {}", report.metadata_path.display());
            println!(
                "  status     {}",
                if report.bootstrapped {
                    "prepared"
                } else {
                    "already ready"
                }
            );
            Ok(ExitCode::SUCCESS)
        }
        CliCommand::Plan(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            let mut config = build_launch_config(&options, &defaults);
            let probe = doctor::current_launch_probe(resolve_plan_runtime_dir(&options, &defaults));
            if apply_network_fallback(
                &mut config,
                options.network.is_some() || defaults.network.is_some(),
                &probe,
            ) {
                eprintln!("fend: passt not found, falling back to qemu user networking");
            }
            let plan = qemu::build_launch_plan(&config).map_err(|error| error.to_string())?;
            print!("{}", render_launch_plan(&plan));
            Ok(ExitCode::SUCCESS)
        }
        CliCommand::Launch(options) => {
            let defaults = plan_defaults_from_env().map_err(|error| error.to_string())?;
            ensure_bootstrap_for_launch(&options, &defaults)?;
            let runtime_dir = resolve_plan_runtime_dir(&options, &defaults);
            let probe = doctor::current_launch_probe(&runtime_dir);
            let mut config = build_supervised_launch_config(&options, &defaults);
            if apply_network_fallback(
                &mut config,
                options.network.is_some() || defaults.network.is_some(),
                &probe,
            ) {
                eprintln!("fend: passt not found, falling back to qemu user networking");
            }
            let report = doctor::evaluate_launch(&probe, config.network);
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
    let mut config = build_run_launch_config(options, &defaults);
    let bootstrap = build_bootstrap_options(
        &SetupOptions {
            runtime_dir: Some(
                config
                    .artifacts
                    .kernel
                    .parent()
                    .unwrap_or_else(|| Path::new("."))
                    .to_path_buf(),
            ),
            work_dir: None,
            rebuild_rootfs: false,
            force_downloads: false,
            skip_claude: false,
        },
        &defaults,
    );
    let _ = bootstrap::ensure_linux_runtime(&bootstrap)?;
    let prepared =
        runtime::prepare_guest_command(&options.command, &config.workspace, &config.tools_dir)?;
    let runtime_dir = config
        .artifacts
        .kernel
        .parent()
        .unwrap_or_else(|| Path::new("."))
        .to_path_buf();
    let probe = doctor::current_launch_probe(&runtime_dir);
    if apply_network_fallback(
        &mut config,
        options.vm_network.is_some() || defaults.network.is_some(),
        &probe,
    ) {
        eprintln!("fend: passt not found, falling back to qemu user networking");
    }
    let report = doctor::evaluate_launch(&probe, config.network);
    if !report.issues.is_empty() {
        eprint!("{}", render_doctor_report(&report));
        return Ok(ExitCode::FAILURE);
    }

    let plan = qemu::build_launch_plan(&config).map_err(|error| error.to_string())?;
    let mut supervisor = Supervisor::new(SupervisorOptions {
        qemu_io: ProcessIo::Log(config.run_dir.join("logs/qemu.log")),
        ..SupervisorOptions::default()
    });
    let _vm = supervisor
        .launch_plan(&plan)
        .map_err(|error| error.to_string())?;

    let smoke_config = build_run_smoke_config(options, &config);
    let mut prepared_smoke = smoke_config;
    prepared_smoke.command = prepared.command;
    prepared_smoke.env.extend(prepared.env);
    let result = session::run_attached(&prepared_smoke).map_err(|error| error.to_string())?;
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

fn ensure_bootstrap_for_launch(
    options: &crate::cli::PlanOptions,
    defaults: &crate::cli::PlanDefaults,
) -> Result<(), String> {
    let runtime_dir = resolve_plan_runtime_dir(options, defaults);
    if !bootstrap::runtime_missing(&runtime_dir) {
        return Ok(());
    }
    let setup = SetupOptions {
        runtime_dir: Some(runtime_dir),
        work_dir: None,
        rebuild_rootfs: false,
        force_downloads: false,
        skip_claude: false,
    };
    let bootstrap = build_bootstrap_options(&setup, defaults);
    let _ = bootstrap::ensure_linux_runtime(&bootstrap)?;
    Ok(())
}

fn apply_network_fallback(
    config: &mut LaunchConfig,
    network_explicit: bool,
    probe: &doctor::HostProbe,
) -> bool {
    if !network_explicit && config.network == NetworkMode::Passt && !probe.passt_available {
        config.network = NetworkMode::User;
        true
    } else {
        false
    }
}
