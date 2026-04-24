//! Poll /proc/net/tcp{,6} and log new outbound TCP connections.
//!
//! This is a coarse but zero-dep signal: enough to catch a postinstall
//! reaching for an exfil endpoint. For the MVP we log to stderr (which
//! flows out via the VM's serial console); structured capture into the
//! host-side audit log is a follow-up.

use std::collections::HashSet;
use std::fs;
use std::time::Duration;

#[derive(Hash, Eq, PartialEq, Clone, Debug)]
struct Conn {
    remote: String,
    port: u16,
}

pub fn start() {
    std::thread::spawn(move || loop {
        run_once();
        std::thread::sleep(Duration::from_secs(2));
    });
}

fn run_once() {
    let mut seen: HashSet<Conn> = HashSet::new();

    loop {
        let mut current = HashSet::new();

        if let Ok(data) = fs::read_to_string("/proc/net/tcp") {
            collect(&data, false, &mut current);
        }
        if let Ok(data) = fs::read_to_string("/proc/net/tcp6") {
            collect(&data, true, &mut current);
        }

        for conn in current.difference(&seen) {
            eprintln!("fendd: net connect {}:{}", conn.remote, conn.port);
        }

        seen = current;
        std::thread::sleep(Duration::from_millis(2000));
    }
}

/// Parse /proc/net/tcp output, collecting ESTABLISHED and SYN_SENT outbound
/// connections. Columns (hex): sl local_address rem_address st tx_queue …
fn collect(data: &str, v6: bool, out: &mut HashSet<Conn>) {
    for line in data.lines().skip(1) {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 4 { continue; }

        // "st" is the 4th column, hex state code.
        let state = parts[3];
        // 01 = ESTABLISHED, 02 = SYN_SENT — both indicate a live outbound attempt.
        if state != "01" && state != "02" { continue; }

        let rem = parts[2]; // e.g. "0100007F:1F90"
        let (ip_hex, port_hex) = match rem.split_once(':') {
            Some(p) => p,
            None => continue,
        };

        let port = match u16::from_str_radix(port_hex, 16) {
            Ok(p) => p,
            Err(_) => continue,
        };

        let ip = if v6 { parse_v6(ip_hex) } else { parse_v4(ip_hex) };
        if let Some(ip) = ip {
            // Skip loopback — noisy and not a real exfil signal.
            if ip.starts_with("127.") || ip == "::1" || ip.starts_with("0.0.0.0") {
                continue;
            }
            out.insert(Conn { remote: ip, port });
        }
    }
}

/// Decode a little-endian v4 address in /proc/net format (e.g. "0100007F" → "127.0.0.1").
fn parse_v4(hex: &str) -> Option<String> {
    if hex.len() != 8 { return None; }
    let bytes: Vec<u8> = (0..4).map(|i| {
        u8::from_str_radix(&hex[i*2..i*2+2], 16).unwrap_or(0)
    }).collect();
    Some(format!("{}.{}.{}.{}", bytes[3], bytes[2], bytes[1], bytes[0]))
}

/// Decode a v6 address — /proc format is 8×4 nibbles grouped little-endian
/// per 32-bit word. We keep it simple: print as colon-separated hex groups.
fn parse_v6(hex: &str) -> Option<String> {
    if hex.len() != 32 { return None; }
    let mut parts = Vec::with_capacity(8);
    for word in 0..4 {
        let chunk = &hex[word*8..word*8+8];
        // Reverse byte order within each 32-bit word.
        let bytes: Vec<&str> = (0..4).map(|i| &chunk[i*2..i*2+2]).collect();
        parts.push(format!("{}{}", bytes[3], bytes[2]));
        parts.push(format!("{}{}", bytes[1], bytes[0]));
    }
    Some(parts.join(":"))
}
