mod connection;
mod port_forward;
mod port_monitor;
mod process;
mod protocol;
mod server;
mod vsock;

#[cfg(target_os = "linux")]
mod init;
#[cfg(target_os = "linux")]
mod network_monitor;

#[cfg(not(target_os = "linux"))]
mod init {
    pub fn initialize() {}
    pub fn exec_shell() {}
}
#[cfg(not(target_os = "linux"))]
mod network_monitor {
    pub fn start() {}
}

fn main() {
    eprintln!("fendd: starting (pid {})", std::process::id());

    init::initialize();
    port_monitor::start();
    port_forward::start();
    network_monitor::start();

    eprintln!("fendd: ready");

    server::run();
}
