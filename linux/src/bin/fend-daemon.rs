use std::process::ExitCode;

fn main() -> ExitCode {
    match parse_args(std::env::args().skip(1)) {
        Ok(Command::Run(config)) => match fend_linux::daemon::run(config) {
            Ok(()) => ExitCode::SUCCESS,
            Err(error) => {
                eprintln!("fend-daemon: {error}");
                ExitCode::FAILURE
            }
        },
        Ok(Command::Help) => {
            print!("{}", usage());
            ExitCode::SUCCESS
        }
        Ok(Command::Version) => {
            println!("fend-daemon {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        Err(error) => {
            eprintln!("error: {error}\n\n{}", usage());
            ExitCode::from(2)
        }
    }
}

enum Command {
    Run(fend_linux::daemon::DaemonConfig),
    Help,
    Version,
}

fn usage() -> String {
    String::from(
        "usage: fend-daemon [options]\n\n\
         options:\n  \
           --socket path        Unix socket path. Default: $FEND_DAEMON_SOCKET, then\n  \
                                $XDG_RUNTIME_DIR/fend/daemon.sock, then $FEND_HOME/run/daemon.sock.\n  \
           --state-dir path     State directory for VM run dirs and pidfile.\n  \
           --reap-interval sec  Idle-VM reaper tick in seconds. Default: 60.\n  \
           -h, --help           Show this help.\n  \
           -V, --version        Show version.\n\n\
         The daemon keeps one QEMU instance per project workspace and serves\n\
         CLI requests over the Unix socket. Idle VMs are stopped after\n\
         30 minutes with zero active sessions.\n",
    )
}

fn parse_args<I: IntoIterator<Item = String>>(args: I) -> Result<Command, String> {
    let mut config = fend_linux::daemon::DaemonConfig::from_env();
    let mut iter = args.into_iter();
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "-h" | "--help" | "help" => return Ok(Command::Help),
            "-V" | "--version" | "version" => return Ok(Command::Version),
            "--socket" => {
                let value = iter
                    .next()
                    .ok_or_else(|| "missing value for --socket".to_string())?;
                config.socket_path = value.into();
            }
            "--state-dir" => {
                let value = iter
                    .next()
                    .ok_or_else(|| "missing value for --state-dir".to_string())?;
                config.state_dir = value.into();
            }
            "--reap-interval" => {
                let value = iter
                    .next()
                    .ok_or_else(|| "missing value for --reap-interval".to_string())?;
                let seconds: u64 = value
                    .parse()
                    .map_err(|_| format!("invalid --reap-interval: {value:?}"))?;
                config.reap_interval = std::time::Duration::from_secs(seconds);
            }
            other => return Err(format!("unknown argument: {other}")),
        }
    }
    Ok(Command::Run(config))
}
