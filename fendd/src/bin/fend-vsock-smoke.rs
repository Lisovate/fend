#[cfg(target_os = "linux")]
fn main() {
    if let Err(err) = linux::run() {
        eprintln!("fend-vsock-smoke: {err}");
        std::process::exit(1);
    }
}

#[cfg(not(target_os = "linux"))]
fn main() {
    eprintln!("fend-vsock-smoke: Linux host only");
    std::process::exit(1);
}

#[cfg(target_os = "linux")]
mod linux {
    use serde::{Deserialize, Serialize};
    use std::collections::BTreeMap;
    use std::io::{Read, Write};
    use std::os::fd::{FromRawFd, OwnedFd};

    const AF_VSOCK: libc::c_int = 40;
    const VMADDR_PORT_FENDD: u32 = 1024;
    const MESSAGE_EXECUTE_COMMAND: u8 = 1;
    const MESSAGE_OUTPUT_DATA: u8 = 3;
    const MESSAGE_EXIT_STATUS: u8 = 4;
    const MESSAGE_READY: u8 = 6;
    const MAX_PAYLOAD: usize = 16 * 1024 * 1024;

    #[repr(C)]
    struct SockaddrVm {
        svm_family: libc::sa_family_t,
        svm_reserved1: u16,
        svm_port: u32,
        svm_cid: u32,
        svm_flags: u8,
        svm_zero: [u8; 3],
    }

    #[derive(Debug)]
    struct Options {
        cid: u32,
        port: u32,
        cwd: String,
        env: BTreeMap<String, String>,
        command: Vec<String>,
    }

    #[derive(Serialize)]
    struct ExecuteCommand {
        id: u64,
        cmd: String,
        args: Vec<String>,
        env: BTreeMap<String, String>,
        cwd: String,
        tty: bool,
    }

    #[derive(Deserialize)]
    struct OutputData {
        stream: String,
        data: String,
    }

    #[derive(Deserialize)]
    struct ExitStatus {
        code: i32,
    }

    pub fn run() -> Result<(), Box<dyn std::error::Error>> {
        let options = parse_args()?;
        let mut stream = connect(options.cid, options.port)?;

        let ready = read_frame(&mut stream)?;
        if ready.kind != MESSAGE_READY {
            return Err(format!("expected Ready frame, got type {}", ready.kind).into());
        }

        let command = ExecuteCommand {
            id: 1,
            cmd: options.command[0].clone(),
            args: options.command[1..].to_vec(),
            env: options.env,
            cwd: options.cwd,
            tty: false,
        };
        let payload = serde_json::to_vec(&command)?;
        write_frame(&mut stream, MESSAGE_EXECUTE_COMMAND, &payload)?;

        loop {
            let frame = read_frame(&mut stream)?;
            match frame.kind {
                MESSAGE_OUTPUT_DATA => {
                    let output: OutputData = serde_json::from_slice(&frame.payload)?;
                    let bytes = base64_decode(&output.data)
                        .ok_or("guest sent invalid base64 output payload")?;
                    match output.stream.as_str() {
                        "stdout" => std::io::stdout().write_all(&bytes)?,
                        "stderr" => std::io::stderr().write_all(&bytes)?,
                        other => return Err(format!("unknown output stream {other:?}").into()),
                    }
                }
                MESSAGE_EXIT_STATUS => {
                    let status: ExitStatus = serde_json::from_slice(&frame.payload)?;
                    std::process::exit(status.code);
                }
                other => {
                    return Err(format!("unexpected frame type {other}").into());
                }
            }
        }
    }

    fn parse_args() -> Result<Options, Box<dyn std::error::Error>> {
        let mut cid = std::env::var("FEND_QEMU_CID")
            .ok()
            .and_then(|value| value.parse().ok())
            .unwrap_or(42);
        let mut port = VMADDR_PORT_FENDD;
        let mut cwd = "/workspace".to_string();
        let mut env = BTreeMap::new();
        let mut command = Vec::new();

        let mut args = std::env::args().skip(1).peekable();
        while let Some(arg) = args.next() {
            match arg.as_str() {
                "--cid" => {
                    let value = args.next().ok_or("--cid requires a value")?;
                    cid = value.parse()?;
                }
                "--port" => {
                    let value = args.next().ok_or("--port requires a value")?;
                    port = value.parse()?;
                }
                "--cwd" => {
                    cwd = args.next().ok_or("--cwd requires a value")?;
                }
                "--env" => {
                    let value = args.next().ok_or("--env requires KEY=VALUE")?;
                    let (key, val) = value.split_once('=').ok_or("--env requires KEY=VALUE")?;
                    env.insert(key.to_string(), val.to_string());
                }
                "--help" | "-h" => {
                    print_usage();
                    std::process::exit(0);
                }
                "--" => {
                    command.extend(args);
                    break;
                }
                value if value.starts_with('-') => {
                    return Err(format!("unknown option {value:?}").into());
                }
                value => {
                    command.push(value.to_string());
                    command.extend(args);
                    break;
                }
            }
        }

        if command.is_empty() {
            print_usage();
            return Err("missing command".into());
        }

        Ok(Options {
            cid,
            port,
            cwd,
            env,
            command,
        })
    }

    fn print_usage() {
        eprintln!(
            "usage: fend-vsock-smoke [--cid N] [--port N] [--cwd PATH] [--env KEY=VALUE] -- command [args...]"
        );
    }

    fn connect(cid: u32, port: u32) -> std::io::Result<std::fs::File> {
        let fd = unsafe { libc::socket(AF_VSOCK, libc::SOCK_STREAM | libc::SOCK_CLOEXEC, 0) };
        if fd < 0 {
            return Err(std::io::Error::last_os_error());
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
                std::os::fd::AsRawFd::as_raw_fd(&fd),
                &addr as *const SockaddrVm as *const libc::sockaddr,
                std::mem::size_of::<SockaddrVm>() as libc::socklen_t,
            )
        };
        if rc != 0 {
            return Err(std::io::Error::last_os_error());
        }

        Ok(std::fs::File::from(fd))
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

        for b in input.bytes().filter(|b| !b.is_ascii_whitespace()) {
            chunk[count] = b;
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
            let n = (n0 << 18) | (n1 << 12) | (n2 << 6) | n3;

            out.push(((n >> 16) & 0xFF) as u8);
            if pad < 2 {
                out.push(((n >> 8) & 0xFF) as u8);
            }
            if pad < 1 {
                out.push((n & 0xFF) as u8);
            }

            count = 0;
        }

        if count == 0 {
            Some(out)
        } else {
            None
        }
    }
}
