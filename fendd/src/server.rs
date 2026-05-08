use crate::connection;
use crate::protocol::VSOCK_PORT;
use crate::vsock::VsockListener;

pub fn bind() -> std::io::Result<VsockListener> {
    VsockListener::bind(VSOCK_PORT)
}

/// Run the vsock server accept loop.
pub fn run(listener: VsockListener) {
    loop {
        match listener.accept() {
            Ok(conn) => {
                eprintln!("fendd: connection accepted");
                std::thread::spawn(move || connection::handle(conn));
            }
            Err(e) => {
                eprintln!("fendd: accept error: {}", e);
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
}
