import Foundation
@preconcurrency import Virtualization
import FendCommon

/// Host-side connection to the fendd guest agent over vsock.
/// Each GuestConnection wraps one VZVirtioSocketConnection.
public final class GuestConnection {
    private let connection: VZVirtioSocketConnection
    public let fd: Int32

    public init(connection: VZVirtioSocketConnection) {
        self.connection = connection
        self.fd = connection.fileDescriptor
    }

    /// Read the initial Ready message from fendd.
    public func waitForReady() throws {
        let frame = try FramedMessage.read(from: fd)
        guard frame.type == .ready else {
            throw FendError.protocolError("Expected Ready message, got type \(frame.type.rawValue)")
        }
    }

    /// Send ExecuteCommand to fendd without reading a response.
    /// Used by direct mode where the CLI handles the relay loop.
    public func sendCommand(
        cmd: String,
        args: [String],
        env: [String: String],
        cwd: String,
        tty: Bool = false
    ) throws {
        let command = ExecuteCommand(id: 1, cmd: cmd, args: args, env: env, cwd: cwd, tty: tty)
        let payload = try JSONEncoder().encode(command)
        try FramedMessage(type: .executeCommand, payload: payload).write(to: fd)
    }

    /// Send a command to fendd and stream output to the terminal.
    /// Returns the command's exit code.
    public func executeCommand(
        cmd: String,
        args: [String],
        env: [String: String],
        cwd: String
    ) throws -> Int32 {
        try sendCommand(cmd: cmd, args: args, env: env, cwd: cwd)

        // Read response frames until we get ExitStatus
        while true {
            let response = try FramedMessage.read(from: fd)

            switch response.type {
            case .outputData:
                let output = try JSONDecoder().decode(OutputData.self, from: response.payload)
                switch output.stream {
                case .stdout:
                    FileHandle.standardOutput.write(output.data)
                case .stderr:
                    FileHandle.standardError.write(output.data)
                }

            case .exitStatus:
                let status = try JSONDecoder().decode(ExitStatus.self, from: response.payload)
                return status.code

            default:
                break
            }
        }
    }
}
