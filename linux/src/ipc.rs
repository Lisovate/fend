//! Host-side IPC protocol between the `fend` CLI and the `fend-daemon`.
//!
//! Wire format: framed JSON. Each message is a 4-byte big-endian length
//! prefix followed by UTF-8 JSON bytes. The protocol is request/response;
//! one request per connection except for `EnsureVm`, where the client keeps
//! the connection open for the lifetime of the command session so the
//! daemon can detect when the session ends (socket close = session over).

use std::env;
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::qemu::NetworkMode;

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_MESSAGE_SIZE: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VmConfig {
    pub project: PathBuf,
    pub runtime_dir: PathBuf,
    pub cache_dir: PathBuf,
    pub tools_dir: PathBuf,
    pub guest_workspace: String,
    pub cpus: u16,
    pub memory_mib: u32,
    pub network: NetworkMode,
    pub epoch: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Request {
    EnsureVm { version: u32, config: VmConfig },
    Stop { project: Option<PathBuf> },
    Status,
    Shutdown,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Response {
    VmReady {
        cid: u32,
        run_dir: PathBuf,
        booted: bool,
    },
    Stopped {
        count: usize,
    },
    Status {
        vms: Vec<VmStatus>,
    },
    ShuttingDown,
    Error {
        message: String,
    },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct VmStatus {
    pub project: PathBuf,
    pub cid: u32,
    pub state: String,
    pub active_sessions: usize,
    pub idle_secs: u64,
    pub run_dir: PathBuf,
}

pub fn write_message<W: Write, T: Serialize>(writer: &mut W, message: &T) -> io::Result<()> {
    let bytes = serde_json::to_vec(message)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    if bytes.len() > MAX_MESSAGE_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("ipc message too large ({} bytes)", bytes.len()),
        ));
    }
    let len = (bytes.len() as u32).to_be_bytes();
    writer.write_all(&len)?;
    writer.write_all(&bytes)?;
    writer.flush()
}

pub fn read_message<R: Read, T: for<'de> Deserialize<'de>>(reader: &mut R) -> io::Result<T> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_MESSAGE_SIZE {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("ipc message too large ({len} bytes)"),
        ));
    }
    let mut buf = vec![0u8; len];
    reader.read_exact(&mut buf)?;
    serde_json::from_slice(&buf)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

/// Default socket path for the host daemon.
///
/// Resolution order:
/// 1. `$FEND_DAEMON_SOCKET` (explicit override).
/// 2. `$XDG_RUNTIME_DIR/fend/daemon.sock` (modern Linux).
/// 3. `$FEND_HOME/run/daemon.sock`.
/// 4. `$HOME/.fend/run/daemon.sock`.
/// 5. `/tmp/fend-{uid}/daemon.sock` as a last resort.
pub fn default_socket_path() -> PathBuf {
    if let Some(path) = env::var_os("FEND_DAEMON_SOCKET") {
        return PathBuf::from(path);
    }
    if let Some(xdg) = env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(xdg).join("fend").join("daemon.sock");
    }
    if let Some(fend_home) = env::var_os("FEND_HOME") {
        return PathBuf::from(fend_home).join("run").join("daemon.sock");
    }
    if let Some(home) = env::var_os("HOME") {
        return PathBuf::from(home)
            .join(".fend")
            .join("run")
            .join("daemon.sock");
    }
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/fend-{uid}/daemon.sock"))
}

/// Default base directory where the daemon stores per-VM run dirs, logs, and
/// the pidfile. Mirrors the resolution order of [`default_socket_path`].
pub fn default_state_dir() -> PathBuf {
    if let Some(path) = env::var_os("FEND_DAEMON_STATE_DIR") {
        return PathBuf::from(path);
    }
    if let Some(xdg) = env::var_os("XDG_RUNTIME_DIR") {
        return PathBuf::from(xdg).join("fend");
    }
    if let Some(fend_home) = env::var_os("FEND_HOME") {
        return PathBuf::from(fend_home).join("run");
    }
    if let Some(home) = env::var_os("HOME") {
        return PathBuf::from(home).join(".fend").join("run");
    }
    let uid = unsafe { libc::getuid() };
    PathBuf::from(format!("/tmp/fend-{uid}"))
}

/// Stable, filesystem-safe identifier for a project path. Uses SipHash via
/// `DefaultHasher`; we only need locality on this host, never a cross-host
/// guarantee, so a non-cryptographic hash is fine.
pub fn project_key(project: &Path) -> String {
    use std::collections::hash_map::DefaultHasher;
    use std::hash::{Hash, Hasher};

    let mut hasher = DefaultHasher::new();
    project.hash(&mut hasher);
    format!("{:016x}", hasher.finish())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn ensure_vm_request_round_trips() {
        let request = Request::EnsureVm {
            version: PROTOCOL_VERSION,
            config: VmConfig {
                project: PathBuf::from("/home/u/proj"),
                runtime_dir: PathBuf::from("/home/u/.fend/runtime/linux-x86_64"),
                cache_dir: PathBuf::from("/home/u/.fend/cache/npm"),
                tools_dir: PathBuf::from("/home/u/.fend/tools"),
                guest_workspace: "/workspace".into(),
                cpus: 2,
                memory_mib: 2048,
                network: NetworkMode::Passt,
                epoch: 12345,
            },
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &request).unwrap();
        let mut cursor = Cursor::new(buf);
        let decoded: Request = read_message(&mut cursor).unwrap();
        assert_eq!(request, decoded);
    }

    #[test]
    fn vm_ready_response_round_trips() {
        let response = Response::VmReady {
            cid: 137,
            run_dir: PathBuf::from("/run/user/1000/fend/vms/abc"),
            booted: true,
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &response).unwrap();
        let decoded: Response = read_message(&mut Cursor::new(buf)).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn status_response_round_trips() {
        let response = Response::Status {
            vms: vec![VmStatus {
                project: PathBuf::from("/p"),
                cid: 100,
                state: "running".into(),
                active_sessions: 1,
                idle_secs: 0,
                run_dir: PathBuf::from("/run/user/1000/fend/vms/abc"),
            }],
        };
        let mut buf = Vec::new();
        write_message(&mut buf, &response).unwrap();
        let decoded: Response = read_message(&mut Cursor::new(buf)).unwrap();
        assert_eq!(response, decoded);
    }

    #[test]
    fn rejects_message_over_max_size() {
        let mut buf = Vec::new();
        let len = (MAX_MESSAGE_SIZE as u32 + 1).to_be_bytes();
        buf.extend_from_slice(&len);
        let result: io::Result<Request> = read_message(&mut Cursor::new(buf));
        assert!(result.is_err());
        assert_eq!(result.unwrap_err().kind(), io::ErrorKind::InvalidData);
    }

    #[test]
    fn project_key_is_stable() {
        let a = project_key(Path::new("/home/u/p"));
        let b = project_key(Path::new("/home/u/p"));
        assert_eq!(a, b);
        let c = project_key(Path::new("/home/u/q"));
        assert_ne!(a, c);
    }

    #[test]
    fn default_socket_path_honors_override() {
        let original = env::var_os("FEND_DAEMON_SOCKET");
        env::set_var("FEND_DAEMON_SOCKET", "/tmp/custom.sock");
        assert_eq!(default_socket_path(), PathBuf::from("/tmp/custom.sock"));
        match original {
            Some(value) => env::set_var("FEND_DAEMON_SOCKET", value),
            None => env::remove_var("FEND_DAEMON_SOCKET"),
        }
    }
}
