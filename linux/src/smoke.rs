use std::collections::BTreeMap;
use std::fmt;
use std::io::{Read, Write};
use std::time::Duration;

pub const DEFAULT_VSOCK_PORT: u32 = 1024;
pub const DEFAULT_SMOKE_TIMEOUT: Duration = Duration::from_secs(30);
const RETRY_INTERVAL: Duration = Duration::from_millis(250);
const MESSAGE_EXECUTE_COMMAND: u8 = 1;
const MESSAGE_OUTPUT_DATA: u8 = 3;
const MESSAGE_EXIT_STATUS: u8 = 4;
const MESSAGE_READY: u8 = 6;
const MAX_PAYLOAD: usize = 16 * 1024 * 1024;
const COMMAND_ID: u64 = 1;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmokeConfig {
    pub cid: u32,
    pub port: u32,
    pub timeout: Duration,
    pub cwd: String,
    pub env: BTreeMap<String, String>,
    pub command: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SmokeResult {
    pub exit_code: i32,
    pub stdout: Vec<u8>,
    pub stderr: Vec<u8>,
}

#[derive(Debug)]
pub enum SmokeError {
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
    UnsupportedHost,
}

impl fmt::Display for SmokeError {
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
            Self::UnsupportedHost => write!(f, "vsock smoke is only supported on Linux hosts"),
        }
    }
}

impl std::error::Error for SmokeError {}

impl From<std::io::Error> for SmokeError {
    fn from(error: std::io::Error) -> Self {
        Self::Io(error)
    }
}

impl From<serde_json::Error> for SmokeError {
    fn from(error: serde_json::Error) -> Self {
        Self::Json(error)
    }
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

pub fn run_smoke(config: &SmokeConfig) -> Result<SmokeResult, SmokeError> {
    validate_config(config)?;
    let mut stream = connect_vsock_with_retry(
        config,
        || connect_vsock(config.cid, config.port),
        std::thread::sleep,
    )?;
    run_smoke_session(&mut stream, config)
}

fn connect_vsock_with_retry<S>(
    config: &SmokeConfig,
    mut connect: impl FnMut() -> Result<S, SmokeError>,
    mut sleep: impl FnMut(Duration),
) -> Result<S, SmokeError> {
    let attempts = connection_attempts(config.timeout);
    let mut last_error = "unknown error".to_string();

    for attempt in 0..attempts {
        match connect() {
            Ok(stream) => return Ok(stream),
            Err(SmokeError::UnsupportedHost) => return Err(SmokeError::UnsupportedHost),
            Err(error) => {
                last_error = error.to_string();
                if attempt + 1 < attempts {
                    sleep(RETRY_INTERVAL);
                }
            }
        }
    }

    Err(SmokeError::ConnectionTimeout {
        cid: config.cid,
        port: config.port,
        timeout: config.timeout,
        last_error,
    })
}

fn connection_attempts(timeout: Duration) -> usize {
    let timeout_ms = timeout.as_millis();
    let interval_ms = RETRY_INTERVAL.as_millis();
    let attempts = timeout_ms / interval_ms + 1;
    usize::try_from(attempts).unwrap_or(usize::MAX)
}

pub fn run_smoke_session(
    stream: &mut (impl Read + Write),
    config: &SmokeConfig,
) -> Result<SmokeResult, SmokeError> {
    validate_config(config)?;
    let (cmd, args) = config.command.split_first().expect("validated command");

    let ready = read_frame(stream)?;
    if ready.kind != MESSAGE_READY {
        return Err(SmokeError::Protocol(format!(
            "expected Ready frame, got type {}",
            ready.kind
        )));
    }

    let payload = serde_json::to_vec(&serde_json::json!({
        "id": COMMAND_ID,
        "cmd": cmd,
        "args": args,
        "env": &config.env,
        "cwd": &config.cwd,
        "tty": false,
    }))?;
    write_frame(stream, MESSAGE_EXECUTE_COMMAND, &payload)?;

    let mut stdout = Vec::new();
    let mut stderr = Vec::new();
    loop {
        let frame = read_frame(stream)?;
        match frame.kind {
            MESSAGE_OUTPUT_DATA => {
                let output = parse_output_data(&frame.payload)?;
                ensure_command_id(output.id)?;
                let bytes = base64_decode(&output.data)
                    .ok_or_else(|| SmokeError::Protocol("guest sent invalid base64".to_string()))?;
                match output.stream.as_str() {
                    "stdout" => stdout.extend(bytes),
                    "stderr" => stderr.extend(bytes),
                    other => {
                        return Err(SmokeError::Protocol(format!(
                            "unknown output stream {other:?}"
                        )));
                    }
                }
            }
            MESSAGE_EXIT_STATUS => {
                let status = parse_exit_status(&frame.payload)?;
                ensure_command_id(status.id)?;
                return Ok(SmokeResult {
                    exit_code: status.code,
                    stdout,
                    stderr,
                });
            }
            other => {
                return Err(SmokeError::Protocol(format!(
                    "unexpected frame type {other}"
                )));
            }
        }
    }
}

fn parse_output_data(payload: &[u8]) -> Result<OutputData, SmokeError> {
    let value: serde_json::Value = serde_json::from_slice(payload)?;
    Ok(OutputData {
        id: json_u64(&value, "id")?,
        stream: json_string(&value, "stream")?,
        data: json_string(&value, "data")?,
    })
}

fn parse_exit_status(payload: &[u8]) -> Result<ExitStatus, SmokeError> {
    let value: serde_json::Value = serde_json::from_slice(payload)?;
    Ok(ExitStatus {
        id: json_u64(&value, "id")?,
        code: json_i32(&value, "code")?,
    })
}

fn json_u64(value: &serde_json::Value, key: &str) -> Result<u64, SmokeError> {
    value
        .get(key)
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| SmokeError::Protocol(format!("guest reply missing numeric {key:?}")))
}

fn json_i32(value: &serde_json::Value, key: &str) -> Result<i32, SmokeError> {
    let number = value
        .get(key)
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| SmokeError::Protocol(format!("guest reply missing numeric {key:?}")))?;
    i32::try_from(number).map_err(|_| SmokeError::Protocol(format!("{key:?} is out of range")))
}

fn json_string(value: &serde_json::Value, key: &str) -> Result<String, SmokeError> {
    value
        .get(key)
        .and_then(serde_json::Value::as_str)
        .map(ToString::to_string)
        .ok_or_else(|| SmokeError::Protocol(format!("guest reply missing string {key:?}")))
}

fn ensure_command_id(id: u64) -> Result<(), SmokeError> {
    if id == COMMAND_ID {
        Ok(())
    } else {
        Err(SmokeError::Protocol(format!(
            "guest replied for unexpected command id {id}"
        )))
    }
}

fn validate_config(config: &SmokeConfig) -> Result<(), SmokeError> {
    if config.command.is_empty() {
        return Err(SmokeError::InvalidConfig(
            "smoke command cannot be empty".to_string(),
        ));
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn connect_vsock(cid: u32, port: u32) -> Result<std::fs::File, SmokeError> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};

    const AF_VSOCK: libc::c_int = 40;

    #[repr(C)]
    struct SockaddrVm {
        svm_family: libc::sa_family_t,
        svm_reserved1: u16,
        svm_port: u32,
        svm_cid: u32,
        svm_flags: u8,
        svm_zero: [u8; 3],
    }

    let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
    if fd < 0 {
        return Err(SmokeError::Io(std::io::Error::last_os_error()));
    }
    let fd = unsafe { OwnedFd::from_raw_fd(fd) };

    let addr = SockaddrVm {
        svm_family: AF_VSOCK as libc::sa_family_t,
        svm_reserved1: 0,
        svm_port: port,
        svm_cid: cid,
        svm_flags: 0,
        svm_zero: [0; 3],
    };

    let rc = unsafe {
        libc::connect(
            fd.as_raw_fd(),
            &addr as *const SockaddrVm as *const libc::sockaddr,
            std::mem::size_of::<SockaddrVm>() as libc::socklen_t,
        )
    };
    if rc != 0 {
        return Err(SmokeError::Io(std::io::Error::last_os_error()));
    }

    Ok(std::fs::File::from(fd))
}

#[cfg(not(target_os = "linux"))]
fn connect_vsock(_cid: u32, _port: u32) -> Result<std::fs::File, SmokeError> {
    Err(SmokeError::UnsupportedHost)
}

struct Frame {
    kind: u8,
    payload: Vec<u8>,
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
    reader.read_exact(&mut payload)?;
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
    writer.write_all(payload)?;
    writer.flush()
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
        if pad < 1 {
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Cursor, Read, Write};

    #[test]
    fn smoke_session_runs_command_and_collects_output() {
        let mut input = Vec::new();
        test_frame(&mut input, MESSAGE_READY, b"");
        test_frame(
            &mut input,
            MESSAGE_OUTPUT_DATA,
            br#"{"id":1,"stream":"stdout","data":"ZmVuZAo="}"#,
        );
        test_frame(
            &mut input,
            MESSAGE_OUTPUT_DATA,
            br#"{"id":1,"stream":"stderr","data":"d2Fybgo="}"#,
        );
        test_frame(&mut input, MESSAGE_EXIT_STATUS, br#"{"id":1,"code":0}"#);
        let mut stream = TestStream::new(input);
        let config = SmokeConfig {
            cid: 42,
            port: DEFAULT_VSOCK_PORT,
            timeout: DEFAULT_SMOKE_TIMEOUT,
            cwd: "/workspace".to_string(),
            env: BTreeMap::from([("FEND_NETWORK_MODE".to_string(), "off".to_string())]),
            command: vec!["/bin/echo".to_string(), "fend".to_string()],
        };

        let result = run_smoke_session(&mut stream, &config).unwrap();

        assert_eq!(result.exit_code, 0);
        assert_eq!(result.stdout, b"fend\n");
        assert_eq!(result.stderr, b"warn\n");
        let mut written = Cursor::new(stream.output);
        let frame = read_frame(&mut written).unwrap();
        assert_eq!(frame.kind, MESSAGE_EXECUTE_COMMAND);
        let payload: serde_json::Value = serde_json::from_slice(&frame.payload).unwrap();
        assert_eq!(payload["cmd"], "/bin/echo");
        assert_eq!(payload["args"], serde_json::json!(["fend"]));
        assert_eq!(payload["env"]["FEND_NETWORK_MODE"], "off");
        assert_eq!(payload["cwd"], "/workspace");
        assert_eq!(payload["tty"], false);
    }

    #[test]
    fn smoke_session_rejects_unexpected_ready_frame() {
        let mut input = Vec::new();
        test_frame(&mut input, MESSAGE_OUTPUT_DATA, b"{}");
        let mut stream = TestStream::new(input);
        let config = sample_config();

        let err = run_smoke_session(&mut stream, &config).unwrap_err();

        assert!(err.to_string().contains("expected Ready frame"));
    }

    #[test]
    fn smoke_session_rejects_wrong_command_id() {
        let mut input = Vec::new();
        test_frame(&mut input, MESSAGE_READY, b"");
        test_frame(&mut input, MESSAGE_EXIT_STATUS, br#"{"id":2,"code":0}"#);
        let mut stream = TestStream::new(input);
        let config = sample_config();

        let err = run_smoke_session(&mut stream, &config).unwrap_err();

        assert!(err.to_string().contains("unexpected command id 2"));
    }

    #[test]
    fn smoke_retries_connection_until_ready() {
        let config = sample_config();
        let mut input = Vec::new();
        test_frame(&mut input, MESSAGE_READY, b"");
        test_frame(&mut input, MESSAGE_EXIT_STATUS, br#"{"id":1,"code":0}"#);
        let mut failures = 2;
        let mut sleeps = Vec::new();

        let mut stream = connect_vsock_with_retry(
            &config,
            || {
                if failures > 0 {
                    failures -= 1;
                    return Err(SmokeError::Io(std::io::Error::new(
                        std::io::ErrorKind::ConnectionRefused,
                        "not ready",
                    )));
                }
                Ok(TestStream::new(input.clone()))
            },
            |duration| sleeps.push(duration),
        )
        .unwrap();

        assert_eq!(sleeps, [RETRY_INTERVAL, RETRY_INTERVAL]);
        let result = run_smoke_session(&mut stream, &config).unwrap();
        assert_eq!(result.exit_code, 0);
    }

    #[test]
    fn smoke_timeout_reports_last_connection_error() {
        let mut config = sample_config();
        config.timeout = RETRY_INTERVAL * 2;
        let mut attempts = 0;
        let mut sleeps = Vec::new();

        let err = connect_vsock_with_retry(
            &config,
            || -> Result<TestStream, SmokeError> {
                attempts += 1;
                Err(SmokeError::Io(std::io::Error::new(
                    std::io::ErrorKind::ConnectionRefused,
                    "still booting",
                )))
            },
            |duration| sleeps.push(duration),
        )
        .unwrap_err();

        assert_eq!(attempts, 3);
        assert_eq!(sleeps, [RETRY_INTERVAL, RETRY_INTERVAL]);
        assert!(err.to_string().contains("timed out connecting"));
        assert!(err.to_string().contains("still booting"));
    }

    #[test]
    fn base64_decode_accepts_expected_payloads() {
        assert_eq!(base64_decode(""), Some(Vec::new()));
        assert_eq!(base64_decode("Zg=="), Some(b"f".to_vec()));
        assert_eq!(base64_decode("Zm8="), Some(b"fo".to_vec()));
        assert_eq!(base64_decode("Zm9v"), Some(b"foo".to_vec()));
        assert_eq!(base64_decode("bad"), None);
        assert_eq!(base64_decode("!!!!"), None);
    }

    fn sample_config() -> SmokeConfig {
        SmokeConfig {
            cid: 42,
            port: DEFAULT_VSOCK_PORT,
            timeout: DEFAULT_SMOKE_TIMEOUT,
            cwd: "/workspace".to_string(),
            env: BTreeMap::new(),
            command: vec!["/bin/true".to_string()],
        }
    }

    fn test_frame(output: &mut Vec<u8>, kind: u8, payload: &[u8]) {
        write_frame(output, kind, payload).unwrap();
    }

    #[derive(Debug)]
    struct TestStream {
        input: Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl TestStream {
        fn new(input: Vec<u8>) -> Self {
            Self {
                input: Cursor::new(input),
                output: Vec::new(),
            }
        }
    }

    impl Read for TestStream {
        fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
            self.input.read(buf)
        }
    }

    impl Write for TestStream {
        fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
            self.output.extend_from_slice(buf);
            Ok(buf.len())
        }

        fn flush(&mut self) -> std::io::Result<()> {
            Ok(())
        }
    }
}
