//! Poll /proc/net/tcp{,6} and log new outbound TCP connections.
//!
//! This is a coarse but zero-dep signal: enough to catch a postinstall
//! reaching for an exfil endpoint. Events are published over a small vsock
//! stream so the host can persist them in the structured audit log.

use crate::protocol::*;
use crate::vsock::{VsockListener, VsockStream};
use std::collections::HashSet;
use std::fs;
use std::sync::{Arc, Mutex};
use std::time::Duration;

#[derive(Hash, Eq, PartialEq, Clone, Debug)]
struct Conn {
    remote: String,
    port: u16,
    state: String,
}

struct NetworkMonitorState {
    known_connections: HashSet<Conn>,
    subscribers: Vec<VsockStream>,
}

type SharedState = Arc<Mutex<NetworkMonitorState>>;

pub fn start() {
    let state: SharedState = Arc::new(Mutex::new(NetworkMonitorState {
        known_connections: HashSet::new(),
        subscribers: Vec::new(),
    }));

    let poll_state = state.clone();
    std::thread::spawn(move || poll_loop(poll_state));

    let listener_state = state.clone();
    std::thread::spawn(move || event_listener(listener_state));
}

fn poll_loop(state: SharedState) {
    let mut seen: HashSet<Conn> = HashSet::new();

    loop {
        std::thread::sleep(Duration::from_secs(2));
        let current = scan_connections();

        let opened: Vec<Conn> = current.difference(&seen).cloned().collect();
        if !opened.is_empty() {
            let mut s = state.lock().unwrap();
            s.known_connections = current.clone();

            let mut dead = Vec::new();
            for (i, sub) in s.subscribers.iter_mut().enumerate() {
                for conn in &opened {
                    eprintln!(
                        "fendd: net connect {}:{} ({})",
                        conn.remote, conn.port, conn.state
                    );
                    if send_network_event(sub, conn).is_err() {
                        dead.push(i);
                        break;
                    }
                }
            }

            for &i in dead.iter().rev() {
                s.subscribers.swap_remove(i);
            }
        } else {
            state.lock().unwrap().known_connections = current.clone();
        }
        seen = current;
    }
}

fn event_listener(state: SharedState) {
    let listener = match VsockListener::bind(VSOCK_PORT_NETWORK_EVENTS) {
        Ok(l) => {
            eprintln!(
                "fendd: network monitor listening on vsock port {}",
                VSOCK_PORT_NETWORK_EVENTS
            );
            l
        }
        Err(e) => {
            eprintln!("fendd: network monitor bind failed: {}", e);
            return;
        }
    };

    loop {
        match listener.accept() {
            Ok(conn) => {
                eprintln!("fendd: network event subscriber connected");
                state.lock().unwrap().subscribers.push(conn);
            }
            Err(e) => {
                eprintln!("fendd: network event accept error: {}", e);
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
}

fn scan_connections() -> HashSet<Conn> {
    let mut current = HashSet::new();

    if let Ok(data) = fs::read_to_string("/proc/net/tcp") {
        collect(&data, false, &mut current);
    }
    if let Ok(data) = fs::read_to_string("/proc/net/tcp6") {
        collect(&data, true, &mut current);
    }

    current
}

/// Parse /proc/net/tcp output, collecting ESTABLISHED and SYN_SENT outbound
/// connections. Columns (hex): sl local_address rem_address st tx_queue …
fn collect(data: &str, v6: bool, out: &mut HashSet<Conn>) {
    for line in data.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 4 {
            continue;
        }

        // "st" is the 4th column, hex state code.
        let state = match parts[3] {
            "01" => "established",
            "02" => "syn_sent",
            _ => continue,
        };
        // 01 = ESTABLISHED, 02 = SYN_SENT — both indicate a live outbound attempt.

        let rem = parts[2]; // e.g. "0100007F:1F90"
        let (ip_hex, port_hex) = match rem.split_once(':') {
            Some(p) => p,
            None => continue,
        };

        let port = match u16::from_str_radix(port_hex, 16) {
            Ok(p) => p,
            Err(_) => continue,
        };

        let ip = if v6 {
            parse_v6(ip_hex)
        } else {
            parse_v4(ip_hex)
        };
        if let Some(ip) = ip {
            // Skip loopback — noisy and not a real exfil signal.
            if ip.starts_with("127.") || ip == "::1" || ip.starts_with("0.0.0.0") {
                continue;
            }
            out.insert(Conn {
                remote: ip,
                port,
                state: state.to_string(),
            });
        }
    }
}

/// Decode a little-endian v4 address in /proc/net format (e.g. "0100007F" → "127.0.0.1").
fn parse_v4(hex: &str) -> Option<String> {
    if hex.len() != 8 {
        return None;
    }
    let bytes: Vec<u8> = (0..4)
        .map(|i| u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap_or(0))
        .collect();
    Some(format!(
        "{}.{}.{}.{}",
        bytes[3], bytes[2], bytes[1], bytes[0]
    ))
}

/// Decode a v6 address — /proc format is 8×4 nibbles grouped little-endian
/// per 32-bit word. We keep it simple: print as colon-separated hex groups.
fn parse_v6(hex: &str) -> Option<String> {
    if hex.len() != 32 {
        return None;
    }
    let mut parts = Vec::with_capacity(8);
    for word in 0..4 {
        let chunk = &hex[word * 8..word * 8 + 8];
        // Reverse byte order within each 32-bit word.
        let bytes: Vec<&str> = (0..4).map(|i| &chunk[i * 2..i * 2 + 2]).collect();
        parts.push(format!("{}{}", bytes[3], bytes[2]));
        parts.push(format!("{}{}", bytes[1], bytes[0]));
    }
    Some(parts.join(":"))
}

fn send_network_event(stream: &mut VsockStream, conn: &Conn) -> std::io::Result<()> {
    let msg = NetworkEventMsg {
        remote: conn.remote.clone(),
        port: conn.port,
        state: conn.state.clone(),
    };
    let json =
        serde_json::to_vec(&msg).map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e))?;
    write_frame(stream, MessageType::NetworkEvent, &json)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_collect_established_ipv4_connection() {
        let content =
            "  sl  local_address rem_address   st\n   0: 0F02000A:A1B2 22D8B85D:01BB 01\n";
        let mut out = HashSet::new();
        collect(content, false, &mut out);

        assert!(out.contains(&Conn {
            remote: "93.184.216.34".to_string(),
            port: 443,
            state: "established".to_string(),
        }));
    }

    #[test]
    fn test_collect_syn_sent_ipv4_connection() {
        let content =
            "  sl  local_address rem_address   st\n   0: 0F02000A:A1B2 08080808:0035 02\n";
        let mut out = HashSet::new();
        collect(content, false, &mut out);

        assert!(out.contains(&Conn {
            remote: "8.8.8.8".to_string(),
            port: 53,
            state: "syn_sent".to_string(),
        }));
    }

    #[test]
    fn test_collect_skips_loopback_and_non_outbound_states() {
        let content = "  sl  local_address rem_address   st\n   0: 0100007F:A1B2 0100007F:0BB8 01\n   1: 0F02000A:A1B2 08080808:0035 0A\n";
        let mut out = HashSet::new();
        collect(content, false, &mut out);

        assert!(out.is_empty());
    }
}
