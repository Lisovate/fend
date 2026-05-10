use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::io::{self, Read, Write};

/// Vsock port that fendd listens on. Must match Swift's `vsockPort`.
pub const VSOCK_PORT: u32 = 1024;

/// Max payload size (16 MB). Prevents OOM from malformed frames.
const MAX_PAYLOAD: usize = 16 * 1024 * 1024;

// ── Message Types (must match Swift MessageType enum) ───────────────

#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum MessageType {
    ExecuteCommand = 1,
    ForwardSignal = 2,
    OutputData = 3,
    ExitStatus = 4,
    PortEvent = 5,
    Ready = 6,
    InputData = 7,
    WindowSize = 8,
    NetworkEvent = 9,
}

impl MessageType {
    pub fn from_u8(v: u8) -> Option<Self> {
        match v {
            1 => Some(Self::ExecuteCommand),
            2 => Some(Self::ForwardSignal),
            3 => Some(Self::OutputData),
            4 => Some(Self::ExitStatus),
            5 => Some(Self::PortEvent),
            6 => Some(Self::Ready),
            7 => Some(Self::InputData),
            8 => Some(Self::WindowSize),
            9 => Some(Self::NetworkEvent),
            _ => None,
        }
    }
}

// ── Host → Guest ────────────────────────────────────────────────────

#[derive(Debug, Deserialize)]
pub struct ExecuteCommand {
    pub id: u64,
    pub cmd: String,
    pub args: Vec<String>,
    pub env: HashMap<String, String>,
    pub cwd: String,
    #[serde(default)]
    pub tty: bool,
}

#[derive(Debug, Deserialize)]
pub struct ForwardSignal {
    pub id: u64,
    pub signal: i32,
}

#[derive(Debug, Deserialize)]
pub struct InputData {
    pub id: u64,
    pub data: String, // base64-encoded bytes (empty = EOF)
}

#[derive(Debug, Deserialize)]
pub struct WindowSizeMsg {
    pub id: u64,
    pub rows: u16,
    pub cols: u16,
}

// ── Guest → Host ────────────────────────────────────────────────────

#[derive(Debug, Serialize)]
pub struct OutputData {
    pub id: u64,
    pub stream: String,
    pub data: String, // base64-encoded bytes
}

#[derive(Debug, Serialize)]
pub struct ExitStatusMsg {
    pub id: u64,
    pub code: i32,
}

#[derive(Debug, Serialize)]
pub struct PortEventMsg {
    pub port: u16,
    pub event: String, // "opened" or "closed"
}

#[derive(Debug, Serialize)]
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub struct NetworkEventMsg {
    pub remote: String,
    pub port: u16,
    pub state: String, // "syn_sent" or "established"
}

/// Vsock port for port-event stream (daemon subscribes here).
pub const VSOCK_PORT_EVENTS: u32 = 1025;

/// Vsock port for port-forward data connections.
pub const VSOCK_PORT_FORWARD: u32 = 1026;

/// Vsock port for outbound-network event stream.
#[cfg_attr(not(target_os = "linux"), allow(dead_code))]
pub const VSOCK_PORT_NETWORK_EVENTS: u32 = 1027;

// ── Wire Protocol ───────────────────────────────────────────────────
// Frame: [type: 1 byte][length: 4 bytes big-endian][payload: N bytes]

pub fn read_frame(r: &mut impl Read) -> io::Result<(MessageType, Vec<u8>)> {
    let mut header = [0u8; 5];
    r.read_exact(&mut header)?;

    let msg_type = MessageType::from_u8(header[0])
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "unknown message type"))?;

    let len = u32::from_be_bytes([header[1], header[2], header[3], header[4]]) as usize;
    if len > MAX_PAYLOAD {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "payload too large",
        ));
    }

    let mut payload = vec![0u8; len];
    if len > 0 {
        r.read_exact(&mut payload)?;
    }

    Ok((msg_type, payload))
}

pub fn write_frame(w: &mut impl Write, msg_type: MessageType, payload: &[u8]) -> io::Result<()> {
    let mut header = [0u8; 5];
    header[0] = msg_type as u8;
    header[1..5].copy_from_slice(&(payload.len() as u32).to_be_bytes());
    w.write_all(&header)?;
    if !payload.is_empty() {
        w.write_all(payload)?;
    }
    w.flush()?;
    Ok(())
}

// ── Base64 encoder (inline, avoids extra dependency) ────────────────

const B64: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

pub fn base64_encode(input: &[u8]) -> String {
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for chunk in input.chunks(3) {
        let b0 = chunk[0] as u32;
        let b1 = chunk.get(1).copied().unwrap_or(0) as u32;
        let b2 = chunk.get(2).copied().unwrap_or(0) as u32;
        let n = (b0 << 16) | (b1 << 8) | b2;
        out.push(B64[((n >> 18) & 0x3F) as usize] as char);
        out.push(B64[((n >> 12) & 0x3F) as usize] as char);
        out.push(if chunk.len() > 1 {
            B64[((n >> 6) & 0x3F) as usize] as char
        } else {
            '='
        });
        out.push(if chunk.len() > 2 {
            B64[(n & 0x3F) as usize] as char
        } else {
            '='
        });
    }
    out
}

pub fn base64_decode(input: &str) -> Option<Vec<u8>> {
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
    let bytes = input.as_bytes();
    if bytes.is_empty() {
        return Some(Vec::new());
    }
    if !bytes.len().is_multiple_of(4) {
        return None;
    }
    let mut out = Vec::with_capacity(bytes.len() / 4 * 3);
    for chunk in bytes.chunks(4) {
        let a = val(chunk[0])?;
        let b = val(chunk[1])?;
        out.push((a << 2) | (b >> 4));
        if chunk[2] != b'=' {
            let c = val(chunk[2])?;
            out.push((b << 4) | (c >> 2));
            if chunk[3] != b'=' {
                let d = val(chunk[3])?;
                out.push((c << 6) | d);
            }
        }
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Cursor;

    #[test]
    fn test_base64_roundtrip_empty() {
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_decode(""), Some(vec![]));
    }

    #[test]
    fn test_base64_roundtrip_1_byte() {
        let encoded = base64_encode(b"A");
        assert_eq!(base64_decode(&encoded), Some(b"A".to_vec()));
    }

    #[test]
    fn test_base64_roundtrip_2_bytes() {
        let encoded = base64_encode(b"AB");
        assert_eq!(base64_decode(&encoded), Some(b"AB".to_vec()));
    }

    #[test]
    fn test_base64_roundtrip_3_bytes() {
        let encoded = base64_encode(b"ABC");
        assert_eq!(base64_decode(&encoded), Some(b"ABC".to_vec()));
    }

    #[test]
    fn test_base64_roundtrip_large() {
        let data: Vec<u8> = (0..=255).collect();
        let encoded = base64_encode(&data);
        assert_eq!(base64_decode(&encoded), Some(data));
    }

    #[test]
    fn test_base64_invalid_length() {
        assert_eq!(base64_decode("!!!"), None);
    }

    #[test]
    fn test_base64_invalid_chars() {
        assert_eq!(base64_decode("!!!!"), None);
    }

    #[test]
    fn test_write_read_frame_roundtrip() {
        let mut buf = Vec::new();
        write_frame(&mut buf, MessageType::Ready, b"{}").unwrap();

        let mut cursor = Cursor::new(buf);
        let (msg_type, payload) = read_frame(&mut cursor).unwrap();
        assert_eq!(msg_type, MessageType::Ready);
        assert_eq!(payload, b"{}");
    }

    #[test]
    fn test_write_read_frame_empty_payload() {
        let mut buf = Vec::new();
        write_frame(&mut buf, MessageType::ExitStatus, b"").unwrap();

        let mut cursor = Cursor::new(buf);
        let (msg_type, payload) = read_frame(&mut cursor).unwrap();
        assert_eq!(msg_type, MessageType::ExitStatus);
        assert!(payload.is_empty());
    }

    #[test]
    fn test_message_type_from_u8_valid() {
        assert_eq!(MessageType::from_u8(1), Some(MessageType::ExecuteCommand));
        assert_eq!(MessageType::from_u8(2), Some(MessageType::ForwardSignal));
        assert_eq!(MessageType::from_u8(3), Some(MessageType::OutputData));
        assert_eq!(MessageType::from_u8(4), Some(MessageType::ExitStatus));
        assert_eq!(MessageType::from_u8(5), Some(MessageType::PortEvent));
        assert_eq!(MessageType::from_u8(6), Some(MessageType::Ready));
        assert_eq!(MessageType::from_u8(7), Some(MessageType::InputData));
        assert_eq!(MessageType::from_u8(8), Some(MessageType::WindowSize));
        assert_eq!(MessageType::from_u8(9), Some(MessageType::NetworkEvent));
    }

    #[test]
    fn test_message_type_from_u8_invalid() {
        assert_eq!(MessageType::from_u8(0), None);
        assert_eq!(MessageType::from_u8(10), None);
        assert_eq!(MessageType::from_u8(255), None);
    }

    #[test]
    fn test_max_payload_rejection() {
        let mut buf = vec![MessageType::Ready as u8];
        let big_len = (17 * 1024 * 1024u32).to_be_bytes();
        buf.extend_from_slice(&big_len);
        // Need some data so read_exact doesn't fail on header
        buf.extend_from_slice(&[0u8; 100]);

        let mut cursor = Cursor::new(buf);
        assert!(read_frame(&mut cursor).is_err());
    }

    #[test]
    fn test_frame_roundtrip_all_types() {
        for type_val in [1u8, 2, 3, 4, 5, 6, 7, 8, 9] {
            let msg_type = MessageType::from_u8(type_val).unwrap();
            let payload = b"test payload";

            let mut buf = Vec::new();
            write_frame(&mut buf, msg_type, payload).unwrap();

            let mut cursor = Cursor::new(buf);
            let (rt, rp) = read_frame(&mut cursor).unwrap();
            assert_eq!(rt, msg_type);
            assert_eq!(rp, payload);
        }
    }
}
