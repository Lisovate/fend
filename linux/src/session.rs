use std::collections::BTreeMap;
use std::fmt;
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crate::smoke::SmokeConfig;

const MESSAGE_EXECUTE_COMMAND: u8 = 1;
const MESSAGE_FORWARD_SIGNAL: u8 = 2;
const MESSAGE_OUTPUT_DATA: u8 = 3;
const MESSAGE_EXIT_STATUS: u8 = 4;
const MESSAGE_PORT_EVENT: u8 = 5;
const MESSAGE_READY: u8 = 6;
const MESSAGE_WINDOW_SIZE: u8 = 8;
const MAX_PAYLOAD: usize = 16 * 1024 * 1024;
const COMMAND_ID: u64 = 1;
const PORT_EVENTS: u32 = 1025;
const PORT_FORWARD: u32 = 1026;
const PORT_FORWARD_POLL_INTERVAL: Duration = Duration::from_millis(100);
const SIGNAL_POLL_INTERVAL: Duration = Duration::from_millis(50);
const EVENT_POLL_INTERVAL: Duration = Duration::from_millis(250);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SessionResult {
    pub exit_code: i32,
}

#[derive(Debug)]
pub enum SessionError {
    InvalidConfig(String),
    Io(std::io::Error),
    Json(serde_json::Error),
    Protocol(String),
    ConnectionTimeout {
        cid: u32,
        port: u32,
        timeout: Duration,
        last_error: String,
    },
    StartupTimeout {
        timeout: Duration,
    },
    UnsupportedHost,
}

impl fmt::Display for SessionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::InvalidConfig(message) => write!(f, "{message}"),
            Self::Io(error) => write!(f, "{error}"),
            Self::Json(error) => write!(f, "{error}"),
            Self::Protocol(message) => write!(f, "{message}"),
            Self::ConnectionTimeout {
                cid,
                port,
                timeout,
                last_error,
            } => write!(
                f,
                "timed out connecting to fendd on vsock cid {cid} port {port} after {}s: {last_error}",
                timeout.as_secs()
            ),
            Self::StartupTimeout { timeout } => write!(
                f,
                "timed out waiting for fendd session startup after {}s",
                timeout.as_secs()
            ),
            Self::UnsupportedHost => write!(f, "attached sessions are only supported on Linux"),
        }
    }
}

impl std::error::Error for SessionError {}

impl From<std::io::Error> for SessionError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for SessionError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
}

pub fn run_attached(config: &SmokeConfig) -> Result<SessionResult, SessionError> {
    validate_config(config)?;

    let tty = host_uses_tty();
    let mut stream = connect_vsock_with_retry(config.cid, config.port, config.timeout)?;
    set_socket_timeout(&stream.file, Some(config.timeout))?;

    let ready =
        read_frame(&mut stream).map_err(|error| io_or_startup_timeout(error, config.timeout))?;
    if ready.kind != MESSAGE_READY {
        return Err(SessionError::Protocol(format!(
            "expected Ready frame, got type {}",
            ready.kind
        )));
    }

    let (cmd, args) = config.command.split_first().expect("validated command");
    let payload = serde_json::to_vec(&serde_json::json!({
        "id": COMMAND_ID,
        "cmd": cmd,
        "args": args,
        "env": &config.env,
        "cwd": &config.cwd,
        "tty": tty,
    }))?;
    write_frame(&mut stream, MESSAGE_EXECUTE_COMMAND, &payload)
        .map_err(|error| io_or_startup_timeout(error, config.timeout))?;

    if tty {
        if let Some((rows, cols)) = current_window_size() {
            send_window_size(&mut stream, rows, cols)?;
        }
    }

    set_socket_timeout(&stream.file, None)?;

    let port_forwarding = PortForwarding::start(config.cid, config.timeout);
    let _port_forwarding = port_forwarding;
    let _signal_forwarder = SignalForwarder::start(&stream, tty)?;

    loop {
        let frame = read_frame(&mut stream)?;
        match frame.kind {
            MESSAGE_OUTPUT_DATA => {
                let output = parse_output_data(&frame.payload)?;
                ensure_command_id(output.id)?;
                let bytes = base64_decode(&output.data).ok_or_else(|| {
                    SessionError::Protocol("guest sent invalid base64".to_string())
                })?;
                match output.stream.as_str() {
                    "stdout" => std::io::stdout().write_all(&bytes)?,
                    "stderr" => std::io::stderr().write_all(&bytes)?,
                    other => {
                        return Err(SessionError::Protocol(format!(
                            "unknown output stream {other:?}"
                        )));
                    }
                }
                std::io::stdout().flush().ok();
                std::io::stderr().flush().ok();
            }
            MESSAGE_EXIT_STATUS => {
                let status = parse_exit_status(&frame.payload)?;
                ensure_command_id(status.id)?;
                return Ok(SessionResult {
                    exit_code: status.code,
                });
            }
            other => {
                return Err(SessionError::Protocol(format!(
                    "unexpected frame type {other}"
                )));
            }
        }
    }
}

struct SignalForwarder {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
    old_mask: libc::sigset_t,
}

impl SignalForwarder {
    fn start(stream: &VsockStream, tty: bool) -> Result<Self, SessionError> {
        #[cfg(not(target_os = "linux"))]
        {
            let _ = stream;
            let _ = tty;
            return Err(SessionError::UnsupportedHost);
        }

        #[cfg(target_os = "linux")]
        {
            let mut mask = zeroed_sigset();
            sigaddset(&mut mask, libc::SIGINT)?;
            sigaddset(&mut mask, libc::SIGTERM)?;
            if tty {
                sigaddset(&mut mask, libc::SIGWINCH)?;
            }

            let mut old_mask = zeroed_sigset();
            let rc = unsafe { libc::pthread_sigmask(libc::SIG_BLOCK, &mask, &mut old_mask) };
            if rc != 0 {
                return Err(SessionError::Io(std::io::Error::from_raw_os_error(rc)));
            }

            let fd = unsafe { libc::signalfd(-1, &mask, libc::SFD_CLOEXEC | libc::SFD_NONBLOCK) };
            if fd < 0 {
                unsafe {
                    libc::pthread_sigmask(libc::SIG_SETMASK, &old_mask, std::ptr::null_mut());
                }
                return Err(SessionError::Io(std::io::Error::last_os_error()));
            }

            let stop = Arc::new(AtomicBool::new(false));
            let thread_stop = stop.clone();
            let mut writer = stream.try_clone()?;
            let fd = unsafe { OwnedFd::from_raw_fd(fd) };
            let handle = thread::spawn(move || signal_loop(fd, &mut writer, tty, thread_stop));

            Ok(Self {
                stop,
                handle: Some(handle),
                old_mask,
            })
        }
    }
}

impl Drop for SignalForwarder {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }

        #[cfg(target_os = "linux")]
        unsafe {
            libc::pthread_sigmask(libc::SIG_SETMASK, &self.old_mask, std::ptr::null_mut());
        }
    }
}

struct PortForwarding {
    stop: Arc<AtomicBool>,
    handle: Option<JoinHandle<()>>,
}

impl PortForwarding {
    fn start(cid: u32, timeout: Duration) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let handle = thread::spawn(move || port_forward_loop(cid, timeout, thread_stop));
        Self {
            stop,
            handle: Some(handle),
        }
    }
}

impl Drop for PortForwarding {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        if let Some(handle) = self.handle.take() {
            let _ = handle.join();
        }
    }
}

struct PortListener {
    stop: Arc<AtomicBool>,
    handle: JoinHandle<()>,
}

impl PortListener {
    fn start(cid: u32, port: u16) -> std::io::Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", port))?;
        listener.set_nonblocking(true)?;

        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = stop.clone();
        let handle = thread::spawn(move || loop {
            if thread_stop.load(Ordering::SeqCst) {
                break;
            }

            match listener.accept() {
                Ok((tcp, _)) => {
                    thread::spawn(move || {
                        if let Err(error) = relay_host_connection(cid, port, tcp) {
                            eprintln!("fend: port forward for 127.0.0.1:{port} failed: {error}");
                        }
                    });
                }
                Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                    thread::sleep(PORT_FORWARD_POLL_INTERVAL);
                }
                Err(error) => {
                    eprintln!("fend: host port listener on 127.0.0.1:{port} failed: {error}");
                    break;
                }
            }
        });

        Ok(Self { stop, handle })
    }

    fn stop(self) {
        self.stop.store(true, Ordering::SeqCst);
        let _ = self.handle.join();
    }
}

fn port_forward_loop(cid: u32, timeout: Duration, stop: Arc<AtomicBool>) {
    let mut listeners = BTreeMap::<u16, PortListener>::new();
    let mut stream = match connect_vsock_with_retry(cid, PORT_EVENTS, timeout) {
        Ok(stream) => stream,
        Err(error) => {
            eprintln!("fend: port event subscription unavailable: {error}");
            return;
        }
    };

    if set_socket_timeout(&stream.file, Some(EVENT_POLL_INTERVAL)).is_err() {
        eprintln!("fend: failed to configure port event stream timeout");
        return;
    }

    loop {
        if stop.load(Ordering::SeqCst) {
            break;
        }

        match read_frame(&mut stream) {
            Ok(frame) => {
                if frame.kind != MESSAGE_PORT_EVENT {
                    continue;
                }
                let event = match parse_port_event(&frame.payload) {
                    Ok(event) => event,
                    Err(error) => {
                        eprintln!("fend: invalid port event from guest: {error}");
                        continue;
                    }
                };
                match event.event.as_str() {
                    "opened" => {
                        if listeners.contains_key(&event.port) {
                            continue;
                        }
                        match PortListener::start(cid, event.port) {
                            Ok(listener) => {
                                eprintln!(
                                    "fend: forwarding guest port {} on http://127.0.0.1:{}",
                                    event.port, event.port
                                );
                                listeners.insert(event.port, listener);
                            }
                            Err(error) => {
                                eprintln!(
                                    "fend: could not bind host port {} for guest forwarding: {}",
                                    event.port, error
                                );
                            }
                        }
                    }
                    "closed" => {
                        if let Some(listener) = listeners.remove(&event.port) {
                            listener.stop();
                            eprintln!("fend: stopped forwarding guest port {}", event.port);
                        }
                    }
                    _ => {}
                }
            }
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(error) => {
                if !stop.load(Ordering::SeqCst) {
                    eprintln!("fend: port event stream ended: {error}");
                }
                break;
            }
        }
    }

    for listener in listeners.into_values() {
        listener.stop();
    }
}

fn relay_host_connection(cid: u32, port: u16, tcp: TcpStream) -> std::io::Result<()> {
    let mut vsock = connect_vsock(cid, PORT_FORWARD).map_err(session_error_to_io)?;
    vsock.write_all(&port.to_be_bytes())?;
    relay(vsock, tcp);
    Ok(())
}

fn relay(mut vsock: VsockStream, tcp: TcpStream) {
    let mut vsock_writer = match vsock.try_clone() {
        Ok(stream) => stream,
        Err(_) => return,
    };
    let mut tcp_reader = match tcp.try_clone() {
        Ok(stream) => stream,
        Err(_) => return,
    };
    let mut tcp_writer = tcp;

    let t1 = thread::spawn(move || {
        let mut buf = [0u8; 16384];
        loop {
            match vsock.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tcp_writer.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        let _ = tcp_writer.shutdown(Shutdown::Write);
    });

    let t2 = thread::spawn(move || {
        let mut buf = [0u8; 16384];
        loop {
            match tcp_reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if vsock_writer.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
    });

    let _ = t1.join();
    let _ = t2.join();
}

fn signal_loop(fd: OwnedFd, writer: &mut VsockStream, tty: bool, stop: Arc<AtomicBool>) {
    let mut info = std::mem::MaybeUninit::<libc::signalfd_siginfo>::uninit();

    while !stop.load(Ordering::SeqCst) {
        let rc = unsafe {
            libc::read(
                fd.as_raw_fd(),
                info.as_mut_ptr() as *mut libc::c_void,
                std::mem::size_of::<libc::signalfd_siginfo>(),
            )
        };

        if rc < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::WouldBlock {
                thread::sleep(SIGNAL_POLL_INTERVAL);
                continue;
            }
            break;
        }

        if rc as usize != std::mem::size_of::<libc::signalfd_siginfo>() {
            continue;
        }

        let info = unsafe { info.assume_init() };
        let signal = info.ssi_signo as i32;
        match signal {
            libc::SIGINT | libc::SIGTERM if send_signal(writer, signal).is_err() => {
                break;
            }
            libc::SIGWINCH if tty => {
                if let Some((rows, cols)) = current_window_size() {
                    if send_window_size(writer, rows, cols).is_err() {
                        break;
                    }
                }
            }
            _ => {}
        }
    }
}

fn send_signal(writer: &mut VsockStream, signal: i32) -> Result<(), SessionError> {
    let payload = serde_json::to_vec(&serde_json::json!({
        "id": COMMAND_ID,
        "signal": signal,
    }))?;
    write_frame(writer, MESSAGE_FORWARD_SIGNAL, &payload)?;
    Ok(())
}

fn send_window_size(writer: &mut VsockStream, rows: u16, cols: u16) -> Result<(), SessionError> {
    let payload = serde_json::to_vec(&serde_json::json!({
        "id": COMMAND_ID,
        "rows": rows,
        "cols": cols,
    }))?;
    write_frame(writer, MESSAGE_WINDOW_SIZE, &payload)?;
    Ok(())
}

fn current_window_size() -> Option<(u16, u16)> {
    let mut winsize = libc::winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe {
        libc::ioctl(
            std::io::stdout().as_raw_fd(),
            libc::TIOCGWINSZ,
            &mut winsize,
        )
    };
    if rc == 0 && winsize.ws_row > 0 && winsize.ws_col > 0 {
        Some((winsize.ws_row, winsize.ws_col))
    } else {
        None
    }
}

fn host_uses_tty() -> bool {
    unsafe {
        libc::isatty(std::io::stdin().as_raw_fd()) == 1
            && libc::isatty(std::io::stdout().as_raw_fd()) == 1
    }
}

fn validate_config(config: &SmokeConfig) -> Result<(), SessionError> {
    if config.command.is_empty() {
        return Err(SessionError::InvalidConfig(
            "session command cannot be empty".to_string(),
        ));
    }
    if config.timeout.is_zero() {
        return Err(SessionError::InvalidConfig(
            "session timeout must be greater than 0".to_string(),
        ));
    }
    Ok(())
}

fn connect_vsock_with_retry(
    cid: u32,
    port: u32,
    timeout: Duration,
) -> Result<VsockStream, SessionError> {
    let attempts = connection_attempts(timeout);
    let mut last_error = "unknown error".to_string();

    for attempt in 0..attempts {
        match connect_vsock(cid, port) {
            Ok(stream) => return Ok(stream),
            Err(SessionError::UnsupportedHost) => return Err(SessionError::UnsupportedHost),
            Err(error) => {
                last_error = error.to_string();
                if attempt + 1 < attempts {
                    thread::sleep(Duration::from_millis(250));
                }
            }
        }
    }

    Err(SessionError::ConnectionTimeout {
        cid,
        port,
        timeout,
        last_error,
    })
}

fn connection_attempts(timeout: Duration) -> usize {
    let timeout_ms = timeout.as_millis();
    let interval_ms = 250u128;
    let attempts = timeout_ms / interval_ms + 1;
    usize::try_from(attempts).unwrap_or(usize::MAX)
}

#[cfg(target_os = "linux")]
fn connect_vsock(cid: u32, port: u32) -> Result<VsockStream, SessionError> {
    let fd = unsafe { libc::socket(libc::AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(SessionError::Io(std::io::Error::last_os_error()));
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };

    let addr = libc::sockaddr_vm {
        svm_family: libc::AF_VSOCK as libc::sa_family_t,
        svm_reserved1: 0,
        svm_port: port,
        svm_cid: cid,
        svm_zero: [0; 4],
    };

    let rc = unsafe {
        libc::connect(
            fd.as_raw_fd(),
            &addr as *const libc::sockaddr_vm as *const libc::sockaddr,
            std::mem::size_of::<libc::sockaddr_vm>() as libc::socklen_t,
        )
    };
    if rc != 0 {
        return Err(SessionError::Io(std::io::Error::last_os_error()));
    }

    Ok(VsockStream {
        file: std::fs::File::from(fd),
    })
}

#[cfg(not(target_os = "linux"))]
fn connect_vsock(_cid: u32, _port: u32) -> Result<VsockStream, SessionError> {
    Err(SessionError::UnsupportedHost)
}

fn set_socket_timeout(file: &std::fs::File, timeout: Option<Duration>) -> std::io::Result<()> {
    let timeval = duration_to_timeval(timeout);
    for option in [libc::SO_RCVTIMEO, libc::SO_SNDTIMEO] {
        let rc = unsafe {
            libc::setsockopt(
                file.as_raw_fd(),
                libc::SOL_SOCKET,
                option,
                &timeval as *const libc::timeval as *const libc::c_void,
                std::mem::size_of::<libc::timeval>() as libc::socklen_t,
            )
        };
        if rc != 0 {
            return Err(std::io::Error::last_os_error());
        }
    }
    Ok(())
}

fn duration_to_timeval(timeout: Option<Duration>) -> libc::timeval {
    let Some(timeout) = timeout else {
        return libc::timeval {
            tv_sec: 0,
            tv_usec: 0,
        };
    };

    let micros = timeout.as_micros().max(1);
    let seconds = i64::try_from(micros / 1_000_000).unwrap_or(i64::MAX);
    let useconds = if seconds == i64::MAX {
        999_999
    } else {
        micros % 1_000_000
    };

    libc::timeval {
        tv_sec: seconds as _,
        tv_usec: useconds as _,
    }
}

fn read_frame(reader: &mut impl Read) -> std::io::Result<Frame> {
    let mut header = [0u8; 5];
    reader.read_exact(&mut header)?;
    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_PAYLOAD {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "payload too large",
        ));
    }
    let mut payload = vec![0u8; len];
    if len > 0 {
        reader.read_exact(&mut payload)?;
    }
    Ok(Frame {
        kind: header[0],
        payload,
    })
}

fn write_frame(writer: &mut impl Write, kind: u8, payload: &[u8]) -> std::io::Result<()> {
    let mut header = [0u8; 5];
    header[0] = kind;
    header[1..].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    writer.write_all(&header)?;
    if !payload.is_empty() {
        writer.write_all(payload)?;
    }
    writer.flush()
}

fn parse_output_data(payload: &[u8]) -> Result<OutputData, SessionError> {
    let value: serde_json::Value = serde_json::from_slice(payload)?;
    Ok(OutputData {
        id: json_u64(&value, "id")?,
        stream: json_string(&value, "stream")?,
        data: json_string(&value, "data")?,
    })
}

fn parse_exit_status(payload: &[u8]) -> Result<ExitStatus, SessionError> {
    let value: serde_json::Value = serde_json::from_slice(payload)?;
    Ok(ExitStatus {
        id: json_u64(&value, "id")?,
        code: json_i32(&value, "code")?,
    })
}

fn parse_port_event(payload: &[u8]) -> Result<PortEvent, SessionError> {
    let value: serde_json::Value = serde_json::from_slice(payload)?;
    let port = json_u64(&value, "port")?;
    Ok(PortEvent {
        port: u16::try_from(port)
            .map_err(|_| SessionError::Protocol(format!("port {port} is out of range")))?,
        event: json_string(&value, "event")?,
    })
}

fn json_u64(value: &serde_json::Value, key: &str) -> Result<u64, SessionError> {
    value
        .get(key)
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| SessionError::Protocol(format!("guest reply missing numeric {key:?}")))
}

fn json_i32(value: &serde_json::Value, key: &str) -> Result<i32, SessionError> {
    let number = value
        .get(key)
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| SessionError::Protocol(format!("guest reply missing numeric {key:?}")))?;
    i32::try_from(number).map_err(|_| SessionError::Protocol(format!("{key:?} is out of range")))
}

fn json_string(value: &serde_json::Value, key: &str) -> Result<String, SessionError> {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .map(ToString::to_string)
        .ok_or_else(|| SessionError::Protocol(format!("guest reply missing string {key:?}")))
}

fn ensure_command_id(id: u64) -> Result<(), SessionError> {
    if id == COMMAND_ID {
        Ok(())
    } else {
        Err(SessionError::Protocol(format!(
            "guest replied for unexpected command id {id}"
        )))
    }
}

fn io_or_startup_timeout(error: std::io::Error, timeout: Duration) -> SessionError {
    match error.kind() {
        std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock => {
            SessionError::StartupTimeout { timeout }
        }
        _ => SessionError::Io(error),
    }
}

fn session_error_to_io(error: SessionError) -> std::io::Error {
    match error {
        SessionError::Io(error) => error,
        other => std::io::Error::other(other.to_string()),
    }
}

fn base64_decode(input: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u8> {
        match c {
            b'A'..=b'Z' => Some(c - b'A'),
            b'a'..=b'z' => Some(c - b'a' + 26),
            b'0'..=b'9' => Some(c - b'0' + 52),
            b'+' => Some(62),
            b'/' => Some(63),
            _ => None,
        }
    }

    let mut out = Vec::with_capacity(input.len() * 3 / 4);
    let mut chunk = [0u8; 4];
    let mut count = 0;

    for byte in input.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
        chunk[count] = byte;
        count += 1;
        if count != 4 {
            continue;
        }

        let pad = (chunk[2] == b'=') as usize + (chunk[3] == b'=') as usize;
        let n0 = val(chunk[0])? as u32;
        let n1 = val(chunk[1])? as u32;
        let n2 = if chunk[2] == b'=' {
            0
        } else {
            val(chunk[2])? as u32
        };
        let n3 = if chunk[3] == b'=' {
            0
        } else {
            val(chunk[3])? as u32
        };
        let decoded = (n0 << 18) | (n1 << 12) | (n2 << 6) | n3;

        out.push(((decoded >> 16) & 0xFF) as u8);
        if pad < 2 {
            out.push(((decoded >> 8) & 0xFF) as u8);
        }
        if pad == 0 {
            out.push((decoded & 0xFF) as u8);
        }

        count = 0;
    }

    if count == 0 {
        Some(out)
    } else {
        None
    }
}

#[cfg(target_os = "linux")]
fn zeroed_sigset() -> libc::sigset_t {
    unsafe { std::mem::zeroed() }
}

#[cfg(target_os = "linux")]
fn sigaddset(mask: &mut libc::sigset_t, signal: i32) -> Result<(), SessionError> {
    let rc = unsafe { libc::sigaddset(mask, signal) };
    if rc == 0 {
        Ok(())
    } else {
        Err(SessionError::Io(std::io::Error::last_os_error()))
    }
}

#[cfg(not(target_os = "linux"))]
fn zeroed_sigset() -> libc::sigset_t {
    unsafe { std::mem::zeroed() }
}

#[cfg(not(target_os = "linux"))]
fn sigaddset(_mask: &mut libc::sigset_t, _signal: i32) -> Result<(), SessionError> {
    Ok(())
}

struct VsockStream {
    file: std::fs::File,
}

impl VsockStream {
    fn try_clone(&self) -> std::io::Result<Self> {
        Ok(Self {
            file: self.file.try_clone()?,
        })
    }
}

impl Read for VsockStream {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        self.file.read(buf)
    }
}

impl Write for VsockStream {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.file.write(buf)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

struct Frame {
    kind: u8,
    payload: Vec<u8>,
}

struct OutputData {
    id: u64,
    stream: String,
    data: String,
}

struct ExitStatus {
    id: u64,
    code: i32,
}

struct PortEvent {
    port: u16,
    event: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_port_event() {
        let event = parse_port_event(br#"{"port":3000,"event":"opened"}"#).unwrap();
        assert_eq!(event.port, 3000);
        assert_eq!(event.event, "opened");
    }

    #[test]
    fn base64_decode_handles_padding() {
        assert_eq!(base64_decode("ZmVuZA=="), Some(b"fend".to_vec()));
    }

    #[test]
    fn session_rejects_empty_command() {
        let config = SmokeConfig {
            cid: 42,
            port: 1024,
            timeout: Duration::from_secs(1),
            max_output_bytes: 1024,
            cwd: "/workspace".to_string(),
            env: BTreeMap::new(),
            command: Vec::new(),
        };
        let error = run_attached(&config).unwrap_err();
        assert!(error.to_string().contains("cannot be empty"));
    }
}
