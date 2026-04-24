use crate::protocol::*;
use crate::vsock::VsockStream;
use std::io::{BufReader, Read};
use std::os::unix::io::{FromRawFd, RawFd};
use std::os::unix::process::CommandExt;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

/// Result of spawning a process — either piped or PTY mode.
pub enum SpawnResult {
    Piped {
        pid: u32,
        stdin: Option<ChildStdin>,
        waiter: JoinHandle<()>,
    },
    Pty {
        pid: u32,
        master_fd: RawFd,
        waiter: JoinHandle<()>,
    },
}

/// Spawn a command in pipe mode (separate stdout/stderr streams).
pub fn spawn(
    writer: &Arc<Mutex<VsockStream>>,
    cmd: &ExecuteCommand,
) -> Result<SpawnResult, ()> {
    let env = build_env(cmd);

    let child = unsafe {
        Command::new(&cmd.cmd)
            .args(&cmd.args)
            .envs(&env)
            .current_dir(&cmd.cwd)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::piped())
            .pre_exec(drop_root)
            .spawn()
    };

    let mut child = match child {
        Ok(c) => c,
        Err(e) => {
            // Host might be in TTY raw mode; use \r\n so the error doesn't
            // staircase across the user's terminal.
            let newline = if cmd.tty { "\r\n" } else { "\n" };
            let msg = if e.kind() == std::io::ErrorKind::NotFound {
                format!("fendd: command not found: {}{}", cmd.cmd, newline)
            } else {
                format!("fendd: exec {}: {}{}", cmd.cmd, e, newline)
            };
            let _ = send_output(writer, cmd.id, "stderr", msg.as_bytes());
            send_exit(writer, cmd.id, 127);
            return Err(());
        }
    };

    let pid = child.id();
    let stdin = child.stdin.take();
    let stdout = child.stdout.take().unwrap();
    let stderr = child.stderr.take().unwrap();
    let id = cmd.id;

    let w1 = writer.clone();
    let t1 = std::thread::spawn(move || {
        stream_pipe(w1, id, "stdout", stdout);
    });

    let w2 = writer.clone();
    let t2 = std::thread::spawn(move || {
        stream_pipe(w2, id, "stderr", stderr);
    });

    let w3 = writer.clone();
    let waiter = std::thread::spawn(move || {
        t1.join().ok();
        t2.join().ok();
        let code = match child.wait() {
            Ok(status) => status.code().unwrap_or(-1),
            Err(_) => -1,
        };
        send_exit(&w3, id, code);
    });

    Ok(SpawnResult::Piped { pid, stdin, waiter })
}

/// Spawn a command in PTY mode (single combined terminal stream).
pub fn spawn_pty(
    writer: &Arc<Mutex<VsockStream>>,
    cmd: &ExecuteCommand,
) -> Result<SpawnResult, ()> {
    let env = build_env(cmd);

    // Allocate PTY
    let mut master: libc::c_int = 0;
    let mut slave: libc::c_int = 0;
    let ret = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            std::ptr::null_mut(),
            std::ptr::null_mut(),
            std::ptr::null_mut(),
        )
    };
    if ret < 0 {
        let e = std::io::Error::last_os_error();
        let _ = send_output(writer, cmd.id, "stderr", format!("fendd: openpty: {}\n", e).as_bytes());
        send_exit(writer, cmd.id, 127);
        return Err(());
    }

    // Spawn child with slave as stdin/stdout/stderr
    let slave_fd = slave;
    let child = unsafe {
        Command::new(&cmd.cmd)
            .args(&cmd.args)
            .envs(&env)
            .current_dir(&cmd.cwd)
            .stdin(Stdio::from_raw_fd(libc::dup(slave_fd)))
            .stdout(Stdio::from_raw_fd(libc::dup(slave_fd)))
            .stderr(Stdio::from_raw_fd(slave_fd))
            .pre_exec(move || {
                drop_root()?;
                // Create new session and set controlling terminal
                if libc::setsid() < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(std::io::Error::last_os_error());
                }
                Ok(())
            })
            .spawn()
    };

    // Close slave in parent — child owns it now
    unsafe { libc::close(slave) };

    let child: Child = match child {
        Ok(c) => c,
        Err(e) => {
            unsafe { libc::close(master) };
            let newline = if cmd.tty { "\r\n" } else { "\n" };
            let msg = if e.kind() == std::io::ErrorKind::NotFound {
                format!("fendd: command not found: {}{}", cmd.cmd, newline)
            } else {
                format!("fendd: exec {}: {}{}", cmd.cmd, e, newline)
            };
            let _ = send_output(writer, cmd.id, "stderr", msg.as_bytes());
            send_exit(writer, cmd.id, 127);
            return Err(());
        }
    };

    let pid = child.id();
    let id = cmd.id;

    // Read from master fd → send as stdout OutputData
    let master_read = unsafe { std::fs::File::from_raw_fd(libc::dup(master)) };
    let w1 = writer.clone();
    let reader_thread = std::thread::spawn(move || {
        stream_pipe(w1, id, "stdout", master_read);
    });

    // Waiter thread: joins reader, waits for child, sends ExitStatus
    let w2 = writer.clone();
    let waiter = std::thread::spawn(move || {
        reader_thread.join().ok();
        let code = match child.wait_with_output() {
            Ok(output) => output.status.code().unwrap_or(-1),
            Err(_) => -1,
        };
        send_exit(&w2, id, code);
    });

    Ok(SpawnResult::Pty { pid, master_fd: master, waiter })
}

/// Drop privileges before exec. Linux path:
///   1. Apply PR_SET_NO_NEW_PRIVS so setuid/file-caps can't escalate later.
///   2. Clear supplementary groups so root's groups don't leak.
///   3. setgid/setuid to uid 1000.
///   4. Clear the process capability sets (belt-and-suspenders — exec'ing a
///      non-root binary already drops ambient caps, but this closes any gap
///      if KEEP_CAPS was ever set upstream).
///
/// macOS host-check path: compile-only stub, since the guest workload only
/// runs inside the Linux VM where this function is actually called.
#[cfg(target_os = "linux")]
fn drop_root() -> Result<(), std::io::Error> {
    unsafe {
        // Block setuid/file-cap escalation for this process + any children.
        if libc::prctl(libc::PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0 {
            return Err(std::io::Error::last_os_error());
        }

        if libc::setgroups(0, std::ptr::null()) != 0 {
            return Err(std::io::Error::last_os_error());
        }
        if libc::setgid(1000) != 0 {
            return Err(std::io::Error::last_os_error());
        }
        if libc::setuid(1000) != 0 {
            return Err(std::io::Error::last_os_error());
        }

        // Clear capability sets via raw capset syscall. cap_user_header_t
        // and cap_user_data_t aren't exposed by libc, so we lay them out here.
        #[repr(C)]
        struct CapHeader {
            version: u32,
            pid: i32,
        }
        #[repr(C)]
        struct CapData {
            effective: u32,
            permitted: u32,
            inheritable: u32,
        }
        let mut header = CapHeader {
            version: 0x20080522, // _LINUX_CAPABILITY_VERSION_3
            pid: 0,
        };
        let data = [
            CapData { effective: 0, permitted: 0, inheritable: 0 },
            CapData { effective: 0, permitted: 0, inheritable: 0 },
        ];
        // capset is syscall 125 on arm64; 126 on x86_64. Use the libc constant.
        let rc = libc::syscall(
            libc::SYS_capset,
            &mut header as *mut _,
            data.as_ptr(),
        );
        if rc != 0 {
            // Don't fail — exec already drops ambient caps automatically and
            // some kernels reject capset-after-setuid without CAP_SETPCAP.
            let _ = std::io::Error::last_os_error();
        }
    }
    Ok(())
}

#[cfg(not(target_os = "linux"))]
fn drop_root() -> Result<(), std::io::Error> {
    // Host-check stub — the real workload only runs in the Linux VM.
    Ok(())
}

fn build_env(cmd: &ExecuteCommand) -> std::collections::HashMap<String, String> {
    let mut env = cmd.env.clone();
    let path = format!("/home/user/.local/bin:{}", std::env::var("PATH").unwrap_or_default());
    env.insert("PATH".to_string(), path);
    env.insert("HOME".to_string(), "/home/user".to_string());
    env.insert("USER".to_string(), "user".to_string());
    if cmd.tty {
        env.insert("TERM".to_string(), env.get("TERM").cloned().unwrap_or_else(|| "xterm-256color".to_string()));
    }
    env
}

fn stream_pipe(writer: Arc<Mutex<VsockStream>>, id: u64, stream: &str, pipe: impl Read) {
    let mut reader = BufReader::new(pipe);
    let mut buf = [0u8; 8192];
    loop {
        match reader.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                if send_output(&writer, id, stream, &buf[..n]).is_err() {
                    break;
                }
            }
            Err(e) => {
                // EIO is expected when PTY slave closes
                if e.raw_os_error() == Some(libc::EIO) {
                    break;
                }
                break;
            }
        }
    }
}

fn send_output(
    writer: &Arc<Mutex<VsockStream>>,
    id: u64,
    stream: &str,
    data: &[u8],
) -> std::io::Result<()> {
    let msg = OutputData {
        id,
        stream: stream.to_string(),
        data: base64_encode(data),
    };
    let json = serde_json::to_vec(&msg).map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    let mut w = writer.lock().unwrap();
    write_frame(&mut *w, MessageType::OutputData, &json)
}

fn send_exit(writer: &Arc<Mutex<VsockStream>>, id: u64, code: i32) {
    let msg = ExitStatusMsg { id, code };
    if let Ok(json) = serde_json::to_vec(&msg) {
        let _ = write_frame(&mut *writer.lock().unwrap(), MessageType::ExitStatus, &json);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    #[test]
    fn test_build_env_sets_defaults() {
        let cmd = ExecuteCommand {
            id: 1,
            cmd: "test".to_string(),
            args: vec![],
            env: HashMap::new(),
            cwd: "/tmp".to_string(),
            tty: false,
        };
        let env = build_env(&cmd);
        assert!(env.get("PATH").unwrap().contains("/home/user/.local/bin"));
        assert_eq!(env.get("HOME").unwrap(), "/home/user");
        assert_eq!(env.get("USER").unwrap(), "user");
    }

    #[test]
    fn test_build_env_preserves_cmd_env() {
        let mut cmd_env = HashMap::new();
        cmd_env.insert("MY_VAR".to_string(), "my_value".to_string());
        let cmd = ExecuteCommand {
            id: 1,
            cmd: "test".to_string(),
            args: vec![],
            env: cmd_env,
            cwd: "/tmp".to_string(),
            tty: false,
        };
        let env = build_env(&cmd);
        assert_eq!(env.get("MY_VAR").unwrap(), "my_value");
    }

    #[test]
    fn test_build_env_tty_adds_term() {
        let cmd = ExecuteCommand {
            id: 1,
            cmd: "test".to_string(),
            args: vec![],
            env: HashMap::new(),
            cwd: "/tmp".to_string(),
            tty: true,
        };
        let env = build_env(&cmd);
        assert_eq!(env.get("TERM").unwrap(), "xterm-256color");
    }

    #[test]
    fn test_build_env_tty_preserves_term() {
        let mut cmd_env = HashMap::new();
        cmd_env.insert("TERM".to_string(), "screen-256color".to_string());
        let cmd = ExecuteCommand {
            id: 1,
            cmd: "test".to_string(),
            args: vec![],
            env: cmd_env,
            cwd: "/tmp".to_string(),
            tty: true,
        };
        let env = build_env(&cmd);
        assert_eq!(env.get("TERM").unwrap(), "screen-256color");
    }
}
