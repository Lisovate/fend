use crate::process;
use crate::protocol::*;
use crate::vsock::VsockStream;
use std::io::{BufReader, Write};
use std::sync::{Arc, Mutex};

/// Handle a single vsock connection from the host.
pub fn handle(conn: VsockStream) {
    let writer = Arc::new(Mutex::new(match conn.try_clone() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("fendd: clone error: {}", e);
            return;
        }
    }));

    if write_frame(&mut *writer.lock().unwrap(), MessageType::Ready, b"{}").is_err() {
        return;
    }

    let mut reader = BufReader::new(conn);

    let (msg_type, payload) = match read_frame(&mut reader) {
        Ok(frame) => frame,
        Err(_) => {
            eprintln!("fendd: connection closed before command");
            return;
        }
    };

    if msg_type != MessageType::ExecuteCommand {
        eprintln!("fendd: expected ExecuteCommand, got {:?}", msg_type);
        return;
    }

    let cmd = match serde_json::from_slice::<ExecuteCommand>(&payload) {
        Ok(cmd) => cmd,
        Err(e) => {
            eprintln!("fendd: bad ExecuteCommand: {}", e);
            return;
        }
    };

    eprintln!("fendd: exec {} {:?} (tty={})", cmd.cmd, cmd.args, cmd.tty);

    let result = if cmd.tty {
        process::spawn_pty(&writer, &cmd)
    } else {
        process::spawn(&writer, &cmd)
    };

    let (pid, waiter, mut child_stdin, master_fd) = match result {
        Ok(process::SpawnResult::Piped { pid, stdin, waiter }) => (pid, waiter, stdin, None),
        Ok(process::SpawnResult::Pty {
            pid,
            master_fd,
            waiter,
        }) => (pid, waiter, None, Some(master_fd)),
        Err(()) => return,
    };
    let command_id = cmd.id;

    while let Ok((msg_type, payload)) = read_frame(&mut reader) {
        match msg_type {
            MessageType::InputData => {
                if let Ok(input) = serde_json::from_slice::<InputData>(&payload) {
                    if input.id != command_id {
                        eprintln!("fendd: ignoring input for stale command id {}", input.id);
                        continue;
                    }
                    if input.data.is_empty() {
                        child_stdin.take();
                    } else if let Some(bytes) = base64_decode(&input.data) {
                        if let Some(fd) = master_fd {
                            unsafe {
                                libc::write(fd, bytes.as_ptr() as *const _, bytes.len());
                            }
                        } else if let Some(ref mut stdin) = child_stdin {
                            let _ = stdin.write_all(&bytes);
                            let _ = stdin.flush();
                        }
                    }
                }
            }
            MessageType::ForwardSignal => {
                if let Ok(sig) = serde_json::from_slice::<ForwardSignal>(&payload) {
                    if sig.id != command_id {
                        eprintln!("fendd: ignoring signal for stale command id {}", sig.id);
                        continue;
                    }
                    eprintln!("fendd: forwarding signal {} to pid {}", sig.signal, pid);
                    unsafe {
                        libc::kill(pid as i32, sig.signal);
                    }
                }
            }
            MessageType::WindowSize => {
                if let Some(fd) = master_fd {
                    if let Ok(ws) = serde_json::from_slice::<WindowSizeMsg>(&payload) {
                        if ws.id != command_id {
                            eprintln!("fendd: ignoring window size for stale command id {}", ws.id);
                            continue;
                        }
                        let winsize = libc::winsize {
                            ws_row: ws.rows,
                            ws_col: ws.cols,
                            ws_xpixel: 0,
                            ws_ypixel: 0,
                        };
                        unsafe {
                            libc::ioctl(fd, libc::TIOCSWINSZ, &winsize);
                        }
                    }
                }
            }
            _ => {
                eprintln!(
                    "fendd: unexpected message type {:?} during execution",
                    msg_type
                );
            }
        }
    }

    drop(child_stdin);
    if let Some(fd) = master_fd {
        unsafe {
            libc::close(fd);
        }
    }

    waiter.join().ok();
}
