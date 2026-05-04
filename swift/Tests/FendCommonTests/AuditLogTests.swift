import XCTest
@testable import FendCommon

final class AuditLogTests: XCTestCase {

    func testAuditEntryCodablePreservesNetworkMode() throws {
        let entry = AuditEntry(
            timestamp: "2026-05-03T04:00:00Z",
            project: "/tmp/project",
            cmd: "npm",
            args: ["install"],
            envKeys: ["FEND_NETWORK_MODE"],
            durationMs: 42,
            exitCode: 0,
            networkMode: "off",
            networkEvents: [
                NetworkEvent(remote: "93.184.216.34", port: 443, state: "established")
            ],
            watchMode: "polling",
            fsDiff: FsDiffSummary(
                outsideNodeModules: 1,
                touchedFiles: [".env"],
                risk: "high",
                sensitiveFiles: [".env"]
            )
        )

        let data = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(AuditEntry.self, from: data)

        XCTAssertEqual(decoded.networkMode, "off")
        XCTAssertEqual(decoded.networkEvents?.first?.remote, "93.184.216.34")
        XCTAssertEqual(decoded.watchMode, "polling")
        XCTAssertEqual(decoded.fsDiff?.risk, "high")
    }

    func testAuditEntryDecodesOlderEntriesWithoutNetworkMode() throws {
        let json = """
        {
          "timestamp": "2026-05-03T04:00:00Z",
          "project": "/tmp/project",
          "cmd": "npm",
          "args": ["install"],
          "envKeys": [],
          "durationMs": 42,
          "exitCode": 0
        }
        """

        let entry = try JSONDecoder().decode(AuditEntry.self, from: Data(json.utf8))

        XCTAssertNil(entry.networkMode)
        XCTAssertNil(entry.networkEvents)
        XCTAssertNil(entry.watchMode)
        XCTAssertNil(entry.fsDiff)
    }
}
