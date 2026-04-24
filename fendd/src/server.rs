use crate::connection;
use crate::init;
use crate::protocol::VSOCK_PORT;
use crate::vsock::VsockListener;

/// Run the vsock server accept loop.
pub fn run() {
    let listener = match VsockListener::bind(VSOCK_PORT) {
        Ok(l) => {
            eprintln!("fendd: listening on vsock port {}", VSOCK_PORT);
            l
        }
        Err(e) => {
            eprintln!("fendd: failed to bind vsock: {}", e);
            init::exec_shell();
            return;
        }
    };

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
