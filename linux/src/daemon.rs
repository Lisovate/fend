//! Long-lived host daemon: owns the [`VmPool`], accepts CLI connections on a
//! Unix socket, and runs a background reaper for idle VMs.

use std::fs;
use std::io::{self, Read};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use crate::ipc::{self, Request, Response};
use crate::pool::VmPool;
use crate::supervisor::stop_run_dir;

pub const DEFAULT_REAP_INTERVAL: Duration = Duration::from_secs(60);
const ACCEPT_POLL_INTERVAL: Duration = Duration::from_millis(50);
const STOP_GRACE: Duration = Duration::from_secs(3);

static SHUTDOWN_REQUESTED: AtomicBool = AtomicBool::new(false);

#[derive(Debug, Clone)]
pub struct DaemonConfig {
    pub socket_path: PathBuf,
    pub state_dir: PathBuf,
    pub reap_interval: Duration,
}

impl DaemonConfig {
    pub fn from_env() -> Self {
        Self {
            socket_path: ipc::default_socket_path(),
            state_dir: ipc::default_state_dir(),
            reap_interval: DEFAULT_REAP_INTERVAL,
        }
    }
}

/// Run the daemon to completion. Returns when the listener exits — either
/// because a Shutdown request arrived or a signal was caught.
pub fn run(config: DaemonConfig) -> io::Result<()> {
    fs::create_dir_all(&config.state_dir)?;
    if let Some(parent) = config.socket_path.parent() {
        fs::create_dir_all(parent)?;
    }

    let pidfile = config.state_dir.join("daemon.pid");
    if let Some(existing_pid) = read_pid(&pidfile) {
        if process_alive(existing_pid) {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                format!("fend-daemon already running (pid {existing_pid})"),
            ));
        }
        // Stale pidfile: previous daemon crashed. Sweep orphan VM run dirs.
        sweep_orphan_run_dirs(&config.state_dir);
    }
    write_pidfile(&pidfile)?;

    install_signal_handlers();

    let pool = Arc::new(VmPool::new(config.state_dir.clone()));
    let shutdown_flag = Arc::new(AtomicBool::new(false));

    let reaper_pool = pool.clone();
    let reaper_shutdown = shutdown_flag.clone();
    let reaper_interval = config.reap_interval;
    let reaper_handle = std::thread::spawn(move || {
        run_reaper(reaper_pool, reaper_shutdown, reaper_interval);
    });

    let listener_result = run_listener(&config.socket_path, pool.clone(), shutdown_flag.clone());

    shutdown_flag.store(true, Ordering::SeqCst);
    let _ = reaper_handle.join();
    let stopped = pool.stop(None);
    if stopped > 0 {
        eprintln!("fend-daemon: stopped {stopped} vm(s) on shutdown");
    }
    let _ = fs::remove_file(&config.socket_path);
    let _ = fs::remove_file(&pidfile);
    listener_result
}

fn run_listener(
    socket_path: &Path,
    pool: Arc<VmPool>,
    shutdown_flag: Arc<AtomicBool>,
) -> io::Result<()> {
    let _ = fs::remove_file(socket_path);
    let listener = UnixListener::bind(socket_path)?;
    listener.set_nonblocking(true)?;

    loop {
        if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) || shutdown_flag.load(Ordering::SeqCst) {
            return Ok(());
        }
        match listener.accept() {
            Ok((stream, _addr)) => {
                let pool = pool.clone();
                let shutdown_flag = shutdown_flag.clone();
                std::thread::spawn(move || {
                    if let Err(error) = handle_connection(stream, &pool, &shutdown_flag) {
                        if !is_normal_close(&error) {
                            eprintln!("fend-daemon: connection error: {error}");
                        }
                    }
                });
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                std::thread::sleep(ACCEPT_POLL_INTERVAL);
            }
            Err(error) => return Err(error),
        }
    }
}

fn handle_connection(
    mut stream: UnixStream,
    pool: &VmPool,
    shutdown_flag: &Arc<AtomicBool>,
) -> io::Result<()> {
    let request: Request = ipc::read_message(&mut stream)?;
    match request {
        Request::EnsureVm { version, config } => {
            if version != ipc::PROTOCOL_VERSION {
                return ipc::write_message(
                    &mut stream,
                    &Response::Error {
                        message: format!(
                            "protocol version mismatch: daemon={}, client={version}",
                            ipc::PROTOCOL_VERSION
                        ),
                    },
                );
            }
            let project = config.project.clone();
            match pool.ensure(config) {
                Ok(outcome) => {
                    ipc::write_message(
                        &mut stream,
                        &Response::VmReady {
                            cid: outcome.cid,
                            run_dir: outcome.run_dir,
                            booted: outcome.booted,
                        },
                    )?;
                    wait_for_session_close(&mut stream);
                    pool.release(&project);
                }
                Err(error) => {
                    ipc::write_message(
                        &mut stream,
                        &Response::Error {
                            message: error.to_string(),
                        },
                    )?;
                }
            }
        }
        Request::Stop { project } => {
            let count = pool.stop(project.as_deref());
            ipc::write_message(&mut stream, &Response::Stopped { count })?;
        }
        Request::Status => {
            let vms = pool.status();
            ipc::write_message(&mut stream, &Response::Status { vms })?;
        }
        Request::Shutdown => {
            ipc::write_message(&mut stream, &Response::ShuttingDown)?;
            shutdown_flag.store(true, Ordering::SeqCst);
        }
    }
    Ok(())
}

fn wait_for_session_close(stream: &mut UnixStream) {
    let mut discard = [0u8; 64];
    loop {
        match stream.read(&mut discard) {
            Ok(0) => return,
            Ok(_) => continue,
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::UnexpectedEof
                        | io::ErrorKind::ConnectionReset
                        | io::ErrorKind::BrokenPipe
                ) =>
            {
                return;
            }
            Err(error) => {
                eprintln!("fend-daemon: session read error: {error}");
                return;
            }
        }
    }
}

fn run_reaper(pool: Arc<VmPool>, shutdown_flag: Arc<AtomicBool>, interval: Duration) {
    let mut elapsed = Duration::ZERO;
    let tick = Duration::from_millis(200);
    loop {
        if SHUTDOWN_REQUESTED.load(Ordering::SeqCst) || shutdown_flag.load(Ordering::SeqCst) {
            return;
        }
        std::thread::sleep(tick);
        elapsed += tick;
        if elapsed >= interval {
            elapsed = Duration::ZERO;
            let reaped = pool.reap();
            if reaped > 0 {
                eprintln!("fend-daemon: reaped {reaped} idle vm(s)");
            }
        }
    }
}

fn sweep_orphan_run_dirs(state_dir: &Path) {
    let vms_dir = state_dir.join("vms");
    let entries = match fs::read_dir(&vms_dir) {
        Ok(entries) => entries,
        Err(_) => return,
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if !path.is_dir() {
            continue;
        }
        match stop_run_dir(&path, STOP_GRACE) {
            Ok(report) => {
                if !report.terminated.is_empty() {
                    eprintln!(
                        "fend-daemon: cleaned up orphan vm at {} ({})",
                        path.display(),
                        report.terminated.join(", ")
                    );
                }
            }
            Err(error) => {
                eprintln!(
                    "fend-daemon: orphan cleanup failed for {}: {error}",
                    path.display()
                );
            }
        }
        let _ = fs::remove_dir_all(&path);
    }
}

fn read_pid(path: &Path) -> Option<u32> {
    let contents = fs::read_to_string(path).ok()?;
    contents.trim().parse::<u32>().ok()
}

fn write_pidfile(path: &Path) -> io::Result<()> {
    fs::write(path, format!("{}\n", std::process::id()))
}

fn process_alive(pid: u32) -> bool {
    if pid == 0 {
        return false;
    }
    let ret = unsafe { libc::kill(pid as i32, 0) };
    if ret == 0 {
        return true;
    }
    let error = io::Error::last_os_error();
    matches!(error.raw_os_error(), Some(libc::EPERM))
}

fn install_signal_handlers() {
    let handler = signal_handler as *const () as libc::sighandler_t;
    unsafe {
        libc::signal(libc::SIGTERM, handler);
        libc::signal(libc::SIGINT, handler);
        libc::signal(libc::SIGHUP, handler);
    }
}

extern "C" fn signal_handler(_: libc::c_int) {
    SHUTDOWN_REQUESTED.store(true, Ordering::SeqCst);
}

fn is_normal_close(error: &io::Error) -> bool {
    matches!(
        error.kind(),
        io::ErrorKind::UnexpectedEof | io::ErrorKind::ConnectionReset | io::ErrorKind::BrokenPipe
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ipc::{Request, Response};
    use std::io::Write;
    use std::os::unix::net::UnixStream;

    fn temp_dir(name: &str) -> PathBuf {
        // Unix socket paths are bounded by SUN_LEN (104 on macOS, 108 on
        // Linux), so we avoid the default $TMPDIR (which is ~60 chars on
        // macOS) and use a short /tmp path.
        use std::sync::atomic::AtomicU64;
        static COUNTER: AtomicU64 = AtomicU64::new(0);
        let id = COUNTER.fetch_add(1, Ordering::SeqCst);
        let path = PathBuf::from(format!("/tmp/fendd-{}-{name}-{id}", std::process::id()));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).unwrap();
        path
    }

    fn round_trip(stream: &mut UnixStream, request: &Request) -> Response {
        ipc::write_message(stream, request).unwrap();
        ipc::read_message(stream).unwrap()
    }

    fn spawn_daemon(name: &str) -> (PathBuf, std::thread::JoinHandle<io::Result<()>>) {
        let dir = temp_dir(name);
        let socket = dir.join("daemon.sock");
        let state_dir = dir.join("state");
        let config = DaemonConfig {
            socket_path: socket.clone(),
            state_dir,
            reap_interval: Duration::from_millis(50),
        };
        let handle = std::thread::spawn(move || run(config));
        // Wait for the socket to appear.
        for _ in 0..200 {
            if socket.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        (socket, handle)
    }

    #[test]
    fn status_request_returns_empty_list_initially() {
        let (socket, handle) = spawn_daemon("status-empty");
        let mut stream = UnixStream::connect(&socket).unwrap();
        let response = round_trip(&mut stream, &Request::Status);
        match response {
            Response::Status { vms } => assert!(vms.is_empty()),
            other => panic!("unexpected response: {other:?}"),
        }
        drop(stream);
        // Shut the daemon down.
        let mut stream = UnixStream::connect(&socket).unwrap();
        ipc::write_message(&mut stream, &Request::Shutdown).unwrap();
        let _: Response = ipc::read_message(&mut stream).unwrap();
        drop(stream);
        handle.join().unwrap().unwrap();
    }

    #[test]
    fn shutdown_request_stops_the_listener() {
        let (socket, handle) = spawn_daemon("shutdown");
        let mut stream = UnixStream::connect(&socket).unwrap();
        let response = round_trip(&mut stream, &Request::Shutdown);
        assert!(matches!(response, Response::ShuttingDown));
        drop(stream);
        // After Shutdown the listener exits; join should return shortly.
        let start = std::time::Instant::now();
        loop {
            if start.elapsed() > Duration::from_secs(2) {
                panic!("daemon failed to exit after Shutdown");
            }
            if handle.is_finished() {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        handle.join().unwrap().unwrap();
    }

    #[test]
    fn ensure_vm_rejects_wrong_protocol_version() {
        let (socket, handle) = spawn_daemon("badversion");
        let mut stream = UnixStream::connect(&socket).unwrap();
        let workspace = std::env::temp_dir();
        let request = Request::EnsureVm {
            version: 99,
            config: ipc::VmConfig {
                project: workspace,
                runtime_dir: PathBuf::from("/nonexistent"),
                cache_dir: PathBuf::from("/nonexistent"),
                tools_dir: PathBuf::from("/nonexistent"),
                guest_workspace: "/workspace".into(),
                cpus: 2,
                memory_mib: 2048,
                network: crate::qemu::NetworkMode::Off,
                epoch: 0,
            },
        };
        let response = round_trip(&mut stream, &request);
        match response {
            Response::Error { message } => assert!(message.contains("protocol version mismatch")),
            other => panic!("unexpected response: {other:?}"),
        }
        drop(stream);
        let mut stream = UnixStream::connect(&socket).unwrap();
        ipc::write_message(&mut stream, &Request::Shutdown).unwrap();
        let _: Response = ipc::read_message(&mut stream).unwrap();
        handle.join().unwrap().unwrap();
    }

    #[test]
    fn refuses_to_start_when_another_daemon_holds_pidfile() {
        let dir = temp_dir("conflict");
        let state_dir = dir.join("state");
        fs::create_dir_all(&state_dir).unwrap();
        fs::write(
            state_dir.join("daemon.pid"),
            format!("{}\n", std::process::id()),
        )
        .unwrap();
        let config = DaemonConfig {
            socket_path: dir.join("daemon.sock"),
            state_dir,
            reap_interval: Duration::from_secs(60),
        };
        let error = run(config).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::AlreadyExists);
    }

    #[test]
    fn invalid_request_payload_returns_quietly() {
        let (socket, handle) = spawn_daemon("badjson");
        let mut stream = UnixStream::connect(&socket).unwrap();
        let bogus = b"not-json";
        let len = (bogus.len() as u32).to_be_bytes();
        stream.write_all(&len).unwrap();
        stream.write_all(bogus).unwrap();
        drop(stream);
        // Daemon should remain healthy and continue serving.
        let mut stream = UnixStream::connect(&socket).unwrap();
        let response = round_trip(&mut stream, &Request::Status);
        assert!(matches!(response, Response::Status { .. }));
        drop(stream);
        let mut stream = UnixStream::connect(&socket).unwrap();
        ipc::write_message(&mut stream, &Request::Shutdown).unwrap();
        let _: Response = ipc::read_message(&mut stream).unwrap();
        handle.join().unwrap().unwrap();
    }
}
