import XCTest
@testable import FendCommon

/// Tests for the framing protocol through pipes, which validates the same
/// protocol behavior used by the CLI's relayOutput and startStdinForwarding.
final class TerminalTests: XCTestCase {

    /// Test writing OutputData + ExitStatus frames to a pipe, then reading them back.
    func testRelayOutputBehaviorViaPipe() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer {
            close(readFd)
            close(writeFd)
        }

        // Simulate what fendd sends: OutputData + ExitStatus
        DispatchQueue.global().async {
            let output = OutputData(id: 1, stream: .stdout, data: Data("hello world".utf8))
            if let payload = try? JSONEncoder().encode(output) {
                try? FramedMessage(type: .outputData, payload: payload).write(to: writeFd)
            }

            let exit = ExitStatus(id: 1, code: 42)
            if let payload = try? JSONEncoder().encode(exit) {
                try? FramedMessage(type: .exitStatus, payload: payload).write(to: writeFd)
            }
        }

        // Read first frame (OutputData)
        let frame1 = try FramedMessage.read(from: readFd)
        XCTAssertEqual(frame1.type, .outputData)
        let output = try JSONDecoder().decode(OutputData.self, from: frame1.payload)
        XCTAssertEqual(output.stream, .stdout)
        XCTAssertEqual(String(data: output.data, encoding: .utf8), "hello world")

        // Read second frame (ExitStatus)
        let frame2 = try FramedMessage.read(from: readFd)
        XCTAssertEqual(frame2.type, .exitStatus)
        let status = try JSONDecoder().decode(ExitStatus.self, from: frame2.payload)
        XCTAssertEqual(status.code, 42)
    }

    /// Test concurrent frame writes from multiple threads.
    func testConcurrentFrameWrites() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer {
            close(readFd)
            close(writeFd)
        }

        let count = 50
        let group = DispatchGroup()

        // Write frames from multiple threads
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                let msg = ExitStatus(id: UInt64(i), code: Int32(i))
                if let payload = try? JSONEncoder().encode(msg) {
                    // Note: concurrent writes to the same fd may interleave,
                    // but each individual frame should be valid
                    try? FramedMessage(type: .exitStatus, payload: payload).write(to: writeFd)
                }
                group.leave()
            }
        }

        group.wait()
        close(writeFd) // Signal EOF

        // Read all frames
        var readCount = 0
        while true {
            do {
                let frame = try FramedMessage.read(from: readFd)
                XCTAssertEqual(frame.type, .exitStatus)
                readCount += 1
            } catch {
                break
            }
        }

        XCTAssertEqual(readCount, count)
    }

    /// Test InputData with empty data (EOF signal).
    func testInputDataEOFSignal() throws {
        let eof = InputData(id: 1, data: Data())
        let encoded = try JSONEncoder().encode(eof)
        let decoded = try JSONDecoder().decode(InputData.self, from: encoded)
        XCTAssertTrue(decoded.data.isEmpty)
    }

    /// Test DaemonError frame handling.
    func testDaemonErrorFrame() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let readFd = fds[0]
        let writeFd = fds[1]
        defer {
            close(readFd)
            close(writeFd)
        }

        let err = DaemonErrorMsg(message: "VM boot failed")
        let payload = try JSONEncoder().encode(err)

        DispatchQueue.global().async {
            try? FramedMessage(type: .daemonError, payload: payload).write(to: writeFd)
        }

        let frame = try FramedMessage.read(from: readFd)
        XCTAssertEqual(frame.type, .daemonError)
        let decoded = try JSONDecoder().decode(DaemonErrorMsg.self, from: frame.payload)
        XCTAssertEqual(decoded.message, "VM boot failed")
    }
}
