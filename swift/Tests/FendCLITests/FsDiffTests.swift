import XCTest
@testable import FendCLI

final class FsDiffTests: XCTestCase {

    func testChangesIncludesHiddenProjectFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()

        try writeFile(".env", in: dir)
        try writeFile("src/index.js", in: dir)
        try writeFile("package-lock.json", in: dir)
        try writeFile("node_modules/pkg/index.js", in: dir)

        let diff = FsDiff.changes(in: dir, after: start)

        XCTAssertTrue(diff.touchedFiles.contains(".env"))
        XCTAssertTrue(diff.touchedFiles.contains("src/index.js"))
        XCTAssertFalse(diff.touchedFiles.contains("package-lock.json"))
        XCTAssertFalse(diff.touchedFiles.contains("node_modules/pkg/index.js"))
        XCTAssertEqual(diff.risk, "high")
        XCTAssertEqual(diff.sensitiveFiles ?? [], [".env"])
    }

    func testChangesClassifiesSourceWritesAsMediumRisk() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let start = Date()

        try writeFile("src/index.js", in: dir)

        let diff = FsDiff.changes(in: dir, after: start)

        XCTAssertEqual(diff.touchedFiles, ["src/index.js"])
        XCTAssertEqual(diff.risk, "medium")
        XCTAssertEqual(diff.sensitiveFiles ?? [], [])
    }

    func testSensitivePathClassifier() {
        XCTAssertTrue(FsDiff.isSensitivePath(".env.local"))
        XCTAssertTrue(FsDiff.isSensitivePath(".npmrc"))
        XCTAssertTrue(FsDiff.isSensitivePath("certs/dev.pem"))
        XCTAssertFalse(FsDiff.isSensitivePath("src/index.js"))
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fend-fsdiff-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeFile(_ relativePath: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "changed".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(5)],
            ofItemAtPath: url.path
        )
    }
}
