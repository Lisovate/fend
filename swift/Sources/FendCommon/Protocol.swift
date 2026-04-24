import Foundation

/// Port used by fendd command listener inside the VM.
public let vsockPort: UInt32 = 1024

/// Port used by fendd port-event stream inside the VM.
public let vsockPortEvents: UInt32 = 1025

/// Port used by fendd port-forward data connections inside the VM.
public let vsockPortForward: UInt32 = 1026

// MARK: - Host → Guest Messages

/// Command execution request sent from host CLI to guest agent.
public struct ExecuteCommand: Codable {
    public let id: UInt64
    public let cmd: String
    public let args: [String]
    public let env: [String: String]
    public let cwd: String
    public let tty: Bool

    public init(id: UInt64, cmd: String, args: [String], env: [String: String], cwd: String, tty: Bool = false) {
        self.id = id
        self.cmd = cmd
        self.args = args
        self.env = env
        self.cwd = cwd
        self.tty = tty
    }
}

/// Signal forwarded from host to a running process in the VM.
public struct ForwardSignal: Codable {
    public let id: UInt64
    public let signal: Int32

    public init(id: UInt64, signal: Int32) {
        self.id = id
        self.signal = signal
    }
}

/// Stdin data forwarded from host to a running process in the VM.
/// Empty data signals EOF (close stdin).
public struct InputData: Codable {
    public let id: UInt64
    public let data: Data

    public init(id: UInt64, data: Data) {
        self.id = id
        self.data = data
    }
}

/// Terminal window size change forwarded from host to guest.
public struct WindowSize: Codable {
    public let id: UInt64
    public let rows: UInt16
    public let cols: UInt16

    public init(id: UInt64, rows: UInt16, cols: UInt16) {
        self.id = id
        self.rows = rows
        self.cols = cols
    }
}

// MARK: - Guest → Host Messages

/// Stdout/stderr data streamed from guest to host.
public struct OutputData: Codable {
    public let id: UInt64
    public let stream: OutputStream
    public let data: Data

    public enum OutputStream: String, Codable {
        case stdout
        case stderr
    }

    public init(id: UInt64, stream: OutputStream, data: Data) {
        self.id = id
        self.stream = stream
        self.data = data
    }
}

/// Exit status of a completed command.
public struct ExitStatus: Codable {
    public let id: UInt64
    public let code: Int32

    public init(id: UInt64, code: Int32) {
        self.id = id
        self.code = code
    }
}

/// Notification that a port was opened/closed inside the VM.
public struct PortEvent: Codable {
    public let port: UInt16
    public let event: PortEventType

    public enum PortEventType: String, Codable {
        case opened
        case closed
    }

    public init(port: UInt16, event: PortEventType) {
        self.port = port
        self.event = event
    }
}

// MARK: - Wire Protocol

/// Message types for the binary framing protocol over vsock.
public enum MessageType: UInt8, Codable {
    case executeCommand = 1
    case forwardSignal = 2
    case outputData = 3
    case exitStatus = 4
    case portEvent = 5
    case ready = 6
    case inputData = 7
    case windowSize = 8
    // Daemon protocol (CLI ↔ daemon)
    case daemonRun = 10
    case daemonError = 11
    case daemonStatus = 12
    case daemonStatusResponse = 13
    case daemonStopVM = 14
}

// MARK: - Daemon Protocol Messages

/// CLI → Daemon: request to run a command in a project's VM.
public struct DaemonRunRequest: Codable {
    public let projectDir: String
    public let cmd: String
    public let args: [String]
    public let env: [String: String]
    public let tty: Bool

    public init(projectDir: String, cmd: String, args: [String], env: [String: String], tty: Bool = false) {
        self.projectDir = projectDir
        self.cmd = cmd
        self.args = args
        self.env = env
        self.tty = tty
    }
}

/// Daemon → CLI: error response.
public struct DaemonErrorMsg: Codable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}

/// Daemon → CLI: status response with VM info.
public struct DaemonStatusResponse: Codable {
    public let vms: [VMInfo]

    public init(vms: [VMInfo]) {
        self.vms = vms
    }
}

/// Info about a single running VM.
public struct VMInfo: Codable {
    public let projectDir: String
    public let state: String
    public let uptimeSeconds: Int
    public let forwardedPorts: [UInt16]

    public init(projectDir: String, state: String, uptimeSeconds: Int, forwardedPorts: [UInt16]) {
        self.projectDir = projectDir
        self.state = state
        self.uptimeSeconds = uptimeSeconds
        self.forwardedPorts = forwardedPorts
    }
}

/// CLI → Daemon: request to stop a VM.
public struct DaemonStopRequest: Codable {
    public let projectDir: String

    public init(projectDir: String) {
        self.projectDir = projectDir
    }
}

/// Framed message: [type: 1 byte][length: 4 bytes big-endian][payload: N bytes]
public struct FramedMessage {
    public let type: MessageType
    public let payload: Data

    public init(type: MessageType, payload: Data) {
        self.type = type
        self.payload = payload
    }

    /// Serialize to wire format.
    public func encode() -> Data {
        var data = Data()
        data.append(type.rawValue)
        var length = UInt32(payload.count).bigEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(payload)
        return data
    }

    /// Read a framed message from a file descriptor.
    public static func read(from fd: Int32) throws -> FramedMessage {
        let header = try readExactData(fd: fd, count: 5)

        guard let msgType = MessageType(rawValue: header[0]) else {
            throw FendError.protocolError("Unknown message type: \(header[0])")
        }

        let length = UInt32(header[1]) << 24 | UInt32(header[2]) << 16
            | UInt32(header[3]) << 8 | UInt32(header[4])
        guard length <= 16 * 1024 * 1024 else {
            throw FendError.protocolError("Payload too large: \(length)")
        }

        let payload = length > 0 ? try readExactData(fd: fd, count: Int(length)) : Data()
        return FramedMessage(type: msgType, payload: payload)
    }

    /// Write a framed message to a file descriptor.
    public func write(to fd: Int32) throws {
        let encoded = self.encode()
        try writeAllData(fd: fd, data: encoded)
    }
}

// MARK: - Errors

public enum FendError: LocalizedError {
    case missingRuntime(String)
    case vmNotRunning
    case timeout(String)
    case connectionClosed
    case connectionError(String)
    case protocolError(String)

    public var errorDescription: String? {
        switch self {
        case .missingRuntime(let msg): return msg
        case .vmNotRunning: return "VM is not running"
        case .timeout(let msg): return msg
        case .connectionClosed: return "Connection closed"
        case .connectionError(let msg): return msg
        case .protocolError(let msg): return "Protocol error: \(msg)"
        }
    }
}

// MARK: - Low-level I/O helpers

private func readExactData(fd: Int32, count: Int) throws -> Data {
    var data = Data(count: count)
    var offset = 0
    try data.withUnsafeMutableBytes { ptr in
        guard let base = ptr.baseAddress else { return }
        while offset < count {
            let n = Darwin.read(fd, base + offset, count - offset)
            if n < 0 {
                throw FendError.connectionError("read: \(String(cString: strerror(errno)))")
            }
            if n == 0 {
                throw FendError.connectionClosed
            }
            offset += n
        }
    }
    return data
}

private func writeAllData(fd: Int32, data: Data) throws {
    try data.withUnsafeBytes { rawPtr in
        guard let base = rawPtr.baseAddress else { return }
        var offset = 0
        while offset < data.count {
            let n = Darwin.write(fd, base + offset, data.count - offset)
            if n <= 0 {
                throw FendError.connectionError("write: \(String(cString: strerror(errno)))")
            }
            offset += n
        }
    }
}
