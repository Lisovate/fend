//! Host CLI → daemon client. Connects to the Unix socket, auto-spawning
//! the daemon if it isn't already running.

use std::env;
use std::fmt;
use std::fs::{self, OpenOptions};
use std::io;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use crate::ipc::{self, Request, Response, VmConfig, VmStatus};

const AUTO_SPAWN_TIMEOUT: Duration = Duration::from_secs(5);
const POLL_INTERVAL: Duration = Duration::from_millis(50);

#[derive(Debug)]
pub enum ClientError {
    Io(io::Error),
    Daemon(String),
    UnexpectedResponse(String),
    DaemonStartTimeout,
    DaemonBinaryMissing(PathBuf),
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Io(error) => write!(f, "{error}"),
            Self::Daemon(message) => write!(f, "daemon error: {message}"),
            Self::UnexpectedResponse(message) => {
                write!(f, "unexpected daemon response: {message}")
            }
            Self::DaemonStartTimeout => write!(
                f,
                "fend-daemon did not become reachable within {}s",
                AUTO_SPAWN_TIMEOUT.as_secs()
            ),
            Self::DaemonBinaryMissing(path) => {
                write!(f, "fend-daemon binary not found at {}", path.display())
            }
        }
    }
}

impl std::error::Error for ClientError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Io(error) => Some(error),
            _ => None,
        }
    }
}

impl From<io::Error> for ClientError {
    fn from(error: io::Error) -> Self {
        Self::Io(error)
    }
}

/// A session connection held open for the lifetime of a CLI command. When
/// dropped, the daemon detects the close and decrements its active-session
/// counter for the project.
pub struct Session {
    pub cid: u32,
    pub run_dir: PathBuf,
    pub booted: bool,
    _keepalive: UnixStream,
}

/// Open an EnsureVm session. The returned [`Session`] holds the daemon
/// connection until dropped; the daemon treats the open socket as an active
/// session and will not reap the VM while it is held.
pub fn ensure_vm(socket_path: &Path, config: VmConfig) -> Result<Session, ClientError> {
    let mut stream = connect_or_spawn(socket_path)?;
    ipc::write_message(
        &mut stream,
        &Request::EnsureVm {
            version: ipc::PROTOCOL_VERSION,
            config,
        },
    )?;
    let response: Response = ipc::read_message(&mut stream)?;
    match response {
        Response::VmReady {
            cid,
            run_dir,
            booted,
        } => Ok(Session {
            cid,
            run_dir,
            booted,
            _keepalive: stream,
        }),
        Response::Error { message } => Err(ClientError::Daemon(message)),
        other => Err(ClientError::UnexpectedResponse(format!("{other:?}"))),
    }
}

pub fn stop(socket_path: &Path, project: Option<PathBuf>) -> Result<usize, ClientError> {
    let mut stream = UnixStream::connect(socket_path)?;
    ipc::write_message(&mut stream, &Request::Stop { project })?;
    match ipc::read_message::<_, Response>(&mut stream)? {
        Response::Stopped { count } => Ok(count),
        Response::Error { message } => Err(ClientError::Daemon(message)),
        other => Err(ClientError::UnexpectedResponse(format!("{other:?}"))),
    }
}

pub fn status(socket_path: &Path) -> Result<Vec<VmStatus>, ClientError> {
    let mut stream = UnixStream::connect(socket_path)?;
    ipc::write_message(&mut stream, &Request::Status)?;
    match ipc::read_message::<_, Response>(&mut stream)? {
        Response::Status { vms } => Ok(vms),
        Response::Error { message } => Err(ClientError::Daemon(message)),
        other => Err(ClientError::UnexpectedResponse(format!("{other:?}"))),
    }
}

pub fn shutdown(socket_path: &Path) -> Result<(), ClientError> {
    let mut stream = match UnixStream::connect(socket_path) {
        Ok(stream) => stream,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) if error.kind() == io::ErrorKind::ConnectionRefused => return Ok(()),
        Err(error) => return Err(ClientError::Io(error)),
    };
    ipc::write_message(&mut stream, &Request::Shutdown)?;
    let _: Response = ipc::read_message(&mut stream)?;
    Ok(())
}

/// Connect to the daemon, spawning it in the background if no listener is
/// running on the socket.
fn connect_or_spawn(socket_path: &Path) -> Result<UnixStream, ClientError> {
    match UnixStream::connect(socket_path) {
        Ok(stream) => return Ok(stream),
        Err(error)
            if matches!(
                error.kind(),
                io::ErrorKind::NotFound | io::ErrorKind::ConnectionRefused
            ) =>
        {
            // Fall through to spawn.
        }
        Err(error) => return Err(ClientError::Io(error)),
    }

    auto_spawn(socket_path)?;
    UnixStream::connect(socket_path).map_err(ClientError::Io)
}

fn auto_spawn(socket_path: &Path) -> Result<(), ClientError> {
    let state_dir = ipc::default_state_dir();
    fs::create_dir_all(&state_dir).ok();
    let log_path = state_dir.join("daemon.log");
    let stdout = OpenOptions::new()
        .create(true)
        .append(true)
        .open(&log_path)?;
    let stderr = stdout.try_clone()?;

    let binary = locate_daemon_binary()?;
    let mut command = Command::new(&binary);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::from(stdout))
        .stderr(Stdio::from(stderr));
    // Detach the daemon from the CLI's process group so SIGINT (Ctrl-C) on
    // the CLI does not also kill the daemon.
    unsafe {
        command.pre_exec(|| {
            if libc::setsid() == -1 {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        });
    }
    let mut child = command.spawn().map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            ClientError::DaemonBinaryMissing(binary.clone())
        } else {
            ClientError::Io(error)
        }
    })?;
    // We don't wait on the daemon — it long-lives past our exit. The Child
    // struct is dropped without join; the OS reparents the daemon to PID 1
    // when the CLI exits.
    drop_without_wait(&mut child);

    poll_for_socket(socket_path, AUTO_SPAWN_TIMEOUT)
}

fn poll_for_socket(socket_path: &Path, timeout: Duration) -> Result<(), ClientError> {
    let start = Instant::now();
    while start.elapsed() < timeout {
        if UnixStream::connect(socket_path).is_ok() {
            return Ok(());
        }
        std::thread::sleep(POLL_INTERVAL);
    }
    Err(ClientError::DaemonStartTimeout)
}

fn locate_daemon_binary() -> Result<PathBuf, ClientError> {
    if let Some(path) = env::var_os("FEND_DAEMON_BINARY") {
        return Ok(PathBuf::from(path));
    }
    if let Ok(current) = env::current_exe() {
        if let Some(parent) = current.parent() {
            let candidate = parent.join("fend-daemon");
            if candidate.exists() {
                return Ok(candidate);
            }
        }
    }
    // Fall back to PATH lookup; Command::new will resolve it via execvp.
    Ok(PathBuf::from("fend-daemon"))
}

fn drop_without_wait(_child: &mut std::process::Child) {
    // We intentionally do not call .wait() so the daemon survives our exit.
    // The OS reparents the daemon to PID 1 when the CLI exits.
}
