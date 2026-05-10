use crate::protocol::*;
use crate::vsock::{VsockListener, VsockStream};
use std::collections::HashSet;
use std::sync::{Arc, Mutex};

/// Combined port monitor state (Phase 2D fix: single lock for both fields).
struct PortMonitorState {
    known_ports: HashSet<u16>,
    subscribers: Vec<VsockStream>,
}

type SharedState = Arc<Mutex<PortMonitorState>>;

/// Start the port monitor system:
/// 1. A polling thread that scans /proc/net/tcp every 2 seconds
/// 2. A vsock listener on port 1025 for event subscribers
pub fn start() {
    let state: SharedState = Arc::new(Mutex::new(PortMonitorState {
        known_ports: HashSet::new(),
        subscribers: Vec::new(),
    }));

    let s1 = state.clone();
    std::thread::spawn(move || poll_loop(s1));

    let s2 = state.clone();
    std::thread::spawn(move || event_listener(s2));
}

/// Poll /proc/net/tcp every 2 seconds and notify subscribers of changes.
fn poll_loop(state: SharedState) {
    let mut prev = HashSet::new();

    loop {
        std::thread::sleep(std::time::Duration::from_secs(2));

        let current = scan_listening_ports();

        let opened: Vec<u16> = current.difference(&prev).copied().collect();
        let closed: Vec<u16> = prev.difference(&current).copied().collect();

        if !opened.is_empty() || !closed.is_empty() {
            let mut s = state.lock().unwrap();
            s.known_ports = current.clone();

            let mut dead = Vec::new();
            for (i, sub) in s.subscribers.iter_mut().enumerate() {
                for &port in &opened {
                    if send_port_event(sub, port, "opened").is_err() {
                        dead.push(i);
                        break;
                    }
                }
                for &port in &closed {
                    if send_port_event(sub, port, "closed").is_err() {
                        if !dead.contains(&i) {
                            dead.push(i);
                        }
                        break;
                    }
                }
            }

            for &i in dead.iter().rev() {
                s.subscribers.swap_remove(i);
            }
        }

        prev = current;
    }
}

/// Accept event subscriber connections on vsock port 1025.
fn event_listener(state: SharedState) {
    let listener = match VsockListener::bind(VSOCK_PORT_EVENTS) {
        Ok(l) => {
            eprintln!(
                "fendd: port monitor listening on vsock port {}",
                VSOCK_PORT_EVENTS
            );
            l
        }
        Err(e) => {
            eprintln!("fendd: port monitor bind failed: {}", e);
            return;
        }
    };

    loop {
        match listener.accept() {
            Ok(mut conn) => {
                eprintln!("fendd: port event subscriber connected");

                let mut s = state.lock().unwrap();
                let ports: Vec<u16> = s.known_ports.iter().copied().collect();
                let mut ok = true;
                for port in ports {
                    if send_port_event(&mut conn, port, "opened").is_err() {
                        ok = false;
                        break;
                    }
                }

                if ok {
                    s.subscribers.push(conn);
                }
            }
            Err(e) => {
                eprintln!("fendd: port event accept error: {}", e);
                std::thread::sleep(std::time::Duration::from_millis(100));
            }
        }
    }
}

/// Parse /proc/net/tcp format content for listening ports (state 0A = LISTEN).
/// Extracted as a pure function for testability (Phase 3E).
pub fn parse_listening_ports(content: &str) -> HashSet<u16> {
    let mut ports = HashSet::new();
    for line in content.lines().skip(1) {
        let fields: Vec<&str> = line.split_whitespace().collect();
        if fields.len() < 4 {
            continue;
        }
        if fields[3] != "0A" {
            continue;
        }
        if let Some(port_hex) = fields[1].split(':').nth(1) {
            if let Ok(port) = u16::from_str_radix(port_hex, 16) {
                if port > 0 {
                    ports.insert(port);
                }
            }
        }
    }
    ports
}

/// Scan /proc/net/tcp and /proc/net/tcp6 for listening ports.
fn scan_listening_ports() -> HashSet<u16> {
    let mut ports = HashSet::new();
    for path in &["/proc/net/tcp", "/proc/net/tcp6"] {
        if let Ok(content) = std::fs::read_to_string(path) {
            ports.extend(parse_listening_ports(&content));
        }
    }
    ports
}

fn send_port_event(stream: &mut VsockStream, port: u16, event: &str) -> std::io::Result<()> {
    let msg = PortEventMsg {
        port,
        event: event.to_string(),
    };
    let json = serde_json::to_vec(&msg).map_err(std::io::Error::other)?;
    write_frame(stream, MessageType::PortEvent, &json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_listening_ports_basic() {
        let content = "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n   0: 00000000:0BB8 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1 0000000000000000 100 0 0 10 0\n";
        let ports = parse_listening_ports(content);
        assert_eq!(ports, HashSet::from([3000]));
    }

    #[test]
    fn test_parse_listening_ports_non_listen() {
        let content =
            "  sl  local_address rem_address   st\n   0: 00000000:0050 00000000:0000 01\n";
        let ports = parse_listening_ports(content);
        assert!(ports.is_empty());
    }

    #[test]
    fn test_parse_listening_ports_multiple() {
        let content = "  sl  local_address rem_address   st\n   0: 00000000:0050 00000000:0000 0A\n   1: 00000000:01BB 00000000:0000 0A\n   2: 00000000:0050 00000001:1234 01\n";
        let ports = parse_listening_ports(content);
        assert!(ports.contains(&80));
        assert!(ports.contains(&443));
        assert_eq!(ports.len(), 2);
    }

    #[test]
    fn test_parse_listening_ports_empty() {
        let content = "  sl  local_address rem_address   st\n";
        let ports = parse_listening_ports(content);
        assert!(ports.is_empty());
    }

    #[test]
    fn test_parse_listening_ports_ipv6() {
        let content = "  sl  local_address                         remote_address                        st\n   0: 00000000000000000000000000000000:1F90 00000000000000000000000000000000:0000 0A\n";
        let ports = parse_listening_ports(content);
        assert_eq!(ports, HashSet::from([8080]));
    }
}
