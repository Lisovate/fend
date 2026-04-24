import XCTest
@testable import FendCommon

final class ProtocolTests: XCTestCase {

    // MARK: - MessageType raw values

    func testMessageTypeRawValues() {
        XCTAssertEqual(MessageType.executeCommand.rawValue, 1)
        XCTAssertEqual(MessageType.forwardSignal.rawValue, 2)
        XCTAssertEqual(MessageType.outputData.rawValue, 3)
        XCTAssertEqual(MessageType.exitStatus.rawValue, 4)
        XCTAssertEqual(MessageType.portEvent.rawValue, 5)
        XCTAssertEqual(MessageType.ready.rawValue, 6)
        XCTAssertEqual(MessageType.inputData.rawValue, 7)
        XCTAssertEqual(MessageType.windowSize.rawValue, 8)
        XCTAssertEqual(MessageType.daemonRun.rawValue, 10)
        XCTAssertEqual(MessageType.daemonError.rawValue, 11)
        XCTAssertEqual(MessageType.daemonStatus.rawValue, 12)
        XCTAssertEqual(MessageType.daemonStatusResponse.rawValue, 13)
        XCTAssertEqual(MessageType.daemonStopVM.rawValue, 14)
    }

    // MARK: - Frame encode/decode round-trip via pipe fds

    func testFrameRoundTripViaPipe() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer {
            close(readFd)
            close(writeFd)
        }

        let payload = try JSONEncoder().encode(["key": "value"])
        let original = FramedMessage(type: .ready, payload: payload)

        // Write on background thread, read on this thread
        DispatchQueue.global().async {
            try? original.write(to: writeFd)
        }

        let decoded = try FramedMessage.read(from: readFd)
        XCTAssertEqual(decoded.type, .ready)
        XCTAssertEqual(decoded.payload, payload)
    }

    // MARK: - Zero-length payload

    func testFrameEmptyPayload() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer {
            close(readFd)
            close(writeFd)
        }

        let original = FramedMessage(type: .exitStatus, payload: Data())

        DispatchQueue.global().async {
            try? original.write(to: writeFd)
        }

        let decoded = try FramedMessage.read(from: readFd)
        XCTAssertEqual(decoded.type, .exitStatus)
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    // MARK: - Max payload rejection

    func testMaxPayloadRejection() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer {
            close(readFd)
            close(writeFd)
        }

        // Write a header claiming 17MB payload
        DispatchQueue.global().async {
            var header = Data()
            header.append(MessageType.ready.rawValue)
            var length = UInt32(17 * 1024 * 1024).bigEndian
            header.append(Data(bytes: &length, count: 4))
            header.withUnsafeBytes { ptr in
                _ = Darwin.write(writeFd, ptr.baseAddress!, ptr.count)
            }
        }

        XCTAssertThrowsError(try FramedMessage.read(from: readFd))
    }

    // MARK: - Codable message types

    func testExecuteCommandCodable() throws {
        let cmd = ExecuteCommand(id: 42, cmd: "npm", args: ["install"], env: ["HOME": "/root"], cwd: "/workspace", tty: true)
        let data = try JSONEncoder().encode(cmd)
        let decoded = try JSONDecoder().decode(ExecuteCommand.self, from: data)
        XCTAssertEqual(decoded.id, 42)
        XCTAssertEqual(decoded.cmd, "npm")
        XCTAssertEqual(decoded.args, ["install"])
        XCTAssertEqual(decoded.tty, true)
    }

    func testForwardSignalCodable() throws {
        let msg = ForwardSignal(id: 1, signal: 2)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ForwardSignal.self, from: data)
        XCTAssertEqual(decoded.signal, 2)
    }

    func testInputDataCodable() throws {
        let msg = InputData(id: 1, data: Data("hello".utf8))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(InputData.self, from: data)
        XCTAssertEqual(String(data: decoded.data, encoding: .utf8), "hello")
    }

    func testOutputDataCodable() throws {
        let msg = OutputData(id: 1, stream: .stdout, data: Data("output".utf8))
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(OutputData.self, from: data)
        XCTAssertEqual(decoded.stream, .stdout)
    }

    func testExitStatusCodable() throws {
        let msg = ExitStatus(id: 1, code: 0)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(ExitStatus.self, from: data)
        XCTAssertEqual(decoded.code, 0)
    }

    func testWindowSizeCodable() throws {
        let msg = WindowSize(id: 1, rows: 24, cols: 80)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(WindowSize.self, from: data)
        XCTAssertEqual(decoded.rows, 24)
        XCTAssertEqual(decoded.cols, 80)
    }

    func testDaemonRunRequestCodable() throws {
        let msg = DaemonRunRequest(projectDir: "/foo", cmd: "ls", args: ["-la"], env: [:], tty: false)
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DaemonRunRequest.self, from: data)
        XCTAssertEqual(decoded.projectDir, "/foo")
    }

    func testDaemonErrorMsgCodable() throws {
        let msg = DaemonErrorMsg(message: "boom")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DaemonErrorMsg.self, from: data)
        XCTAssertEqual(decoded.message, "boom")
    }

    func testDaemonStatusResponseCodable() throws {
        let info = VMInfo(projectDir: "/project", state: "running", uptimeSeconds: 120, forwardedPorts: [3000, 8080])
        let msg = DaemonStatusResponse(vms: [info])
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DaemonStatusResponse.self, from: data)
        XCTAssertEqual(decoded.vms.count, 1)
        XCTAssertEqual(decoded.vms[0].forwardedPorts, [3000, 8080])
    }

    func testDaemonStopRequestCodable() throws {
        let msg = DaemonStopRequest(projectDir: "/project")
        let data = try JSONEncoder().encode(msg)
        let decoded = try JSONDecoder().decode(DaemonStopRequest.self, from: data)
        XCTAssertEqual(decoded.projectDir, "/project")
    }

    // MARK: - Frame encode produces correct wire format

    func testFrameEncodeFormat() {
        let frame = FramedMessage(type: .ready, payload: Data([0x41, 0x42]))
        let encoded = frame.encode()

        // Type byte
        XCTAssertEqual(encoded[0], MessageType.ready.rawValue)

        // Length (big-endian u32 = 2)
        XCTAssertEqual(encoded[1], 0)
        XCTAssertEqual(encoded[2], 0)
        XCTAssertEqual(encoded[3], 0)
        XCTAssertEqual(encoded[4], 2)

        // Payload
        XCTAssertEqual(encoded[5], 0x41)
        XCTAssertEqual(encoded[6], 0x42)
    }
}
