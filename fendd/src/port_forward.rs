use crate::protocol::VSOCK_PORT_FORWARD;
use crate::vsock::VsockListener;
use std::io::{Read, Write};
use std::net::TcpStream;

/// Start the port-forward data listener on vsock port 1026.
/// Each connection: read 2-byte port header (BE u16), connect to
/// localhost:<port> inside VM, relay bidirectionally.
pub fn start() {
    std::thread::spawn(|| {
        let listener = match VsockListener::bind(VSOCK_PORT_FORWARD) {
            Ok(l) => {
                eprintln!(
                    "fendd: port forward listening on vsock port {}",
                    VSOCK_PORT_FORWARD
                );
                l
            }
            Err(e) => {
                eprintln!("fendd: port forward bind failed: {}", e);
                return;
            }
        };

        loop {
            match listener.accept() {
                Ok(conn) => {
                    std::thread::spawn(move || handle_forward(conn));
                }
                Err(e) => {
                    eprintln!("fendd: port forward accept error: {}", e);
                    std::thread::sleep(std::time::Duration::from_millis(100));
                }
            }
        }
    });
}

fn handle_forward(mut vsock: crate::vsock::VsockStream) {
    // Read 2-byte port header (big-endian u16)
    let mut port_buf = [0u8; 2];
    if vsock.read_exact(&mut port_buf).is_err() {
        return;
    }
    let target_port = u16::from_be_bytes(port_buf);

    eprintln!("fendd: forwarding to localhost:{}", target_port);

    // Connect to localhost:<port> inside the VM
    let tcp = match TcpStream::connect(("127.0.0.1", target_port)) {
        Ok(s) => s,
        Err(e) => {
            eprintln!(
                "fendd: forward connect to port {} failed: {}",
                target_port, e
            );
            return;
        }
    };

    // Bidirectional relay
    relay(vsock, tcp);
}

/// Relay data bidirectionally between two streams until either side closes.
fn relay(mut a: crate::vsock::VsockStream, tcp: TcpStream) {
    let mut a2 = match a.try_clone() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut tcp_read = match tcp.try_clone() {
        Ok(c) => c,
        Err(_) => return,
    };
    let mut tcp_write = tcp;

    // vsock → TCP
    let t1 = std::thread::spawn(move || {
        let mut buf = [0u8; 16384];
        loop {
            match a.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if tcp_write.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
        tcp_write.shutdown(std::net::Shutdown::Write).ok();
    });

    // TCP → vsock
    let t2 = std::thread::spawn(move || {
        let mut buf = [0u8; 16384];
        loop {
            match tcp_read.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    if a2.write_all(&buf[..n]).is_err() {
                        break;
                    }
                }
            }
        }
    });

    t1.join().ok();
    t2.join().ok();
}
