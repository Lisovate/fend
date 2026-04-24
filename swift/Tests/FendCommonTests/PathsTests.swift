import XCTest
@testable import FendCommon

final class PathsTests: XCTestCase {

    // MARK: - Directory hierarchy

    func testDirectoryHierarchy() {
        let paths = FendPaths()
        let home = FileManager.default.homeDirectoryForCurrentUser

        XCTAssertEqual(paths.home, home.appendingPathComponent(".fend"))
        XCTAssertEqual(paths.runtimeDir, paths.home.appendingPathComponent("runtime"))
        XCTAssertEqual(paths.cacheDir, paths.home.appendingPathComponent("cache"))
        XCTAssertEqual(paths.toolsDir, paths.home.appendingPathComponent("tools"))
        XCTAssertEqual(paths.stateDir, paths.home.appendingPathComponent("state"))
        XCTAssertEqual(paths.socketPath, paths.home.appendingPathComponent("fend.sock"))
        XCTAssertEqual(paths.pidPath, paths.home.appendingPathComponent("fend.pid"))
    }

    // MARK: - projectHash deterministic + unique

    func testProjectHashDeterministic() {
        let dir = URL(fileURLWithPath: "/tmp/test-project")
        let hash1 = FendPaths.projectHash(for: dir)
        let hash2 = FendPaths.projectHash(for: dir)
        XCTAssertEqual(hash1, hash2)
    }

    func testProjectHashUnique() {
        let dir1 = URL(fileURLWithPath: "/tmp/project-a")
        let dir2 = URL(fileURLWithPath: "/tmp/project-b")
        let hash1 = FendPaths.projectHash(for: dir1)
        let hash2 = FendPaths.projectHash(for: dir2)
        XCTAssertNotEqual(hash1, hash2)
    }

    func testProjectHashFormat() {
        let hash = FendPaths.projectHash(for: URL(fileURLWithPath: "/tmp/test"))
        // Should be a 32-character hex string (16 bytes * 2 hex chars)
        XCTAssertEqual(hash.count, 32)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    // MARK: - projectRootfsPath

    func testProjectRootfsPath() {
        let paths = FendPaths()
        let hash = "abc123"
        let rootfsPath = paths.projectRootfsPath(hash: hash)
        XCTAssertEqual(rootfsPath, paths.stateDir.appendingPathComponent("abc123/rootfs.img"))
    }

    // MARK: - Tool directories

    func testNodeDir() {
        let paths = FendPaths()
        let nodeDir = paths.nodeDir(version: "22.11.0")
        XCTAssertEqual(nodeDir, paths.toolsDir.appendingPathComponent("node-22.11.0"))
    }

    func testBunDir() {
        let paths = FendPaths()
        let bunDir = paths.bunDir(version: "1.1.0")
        XCTAssertEqual(bunDir, paths.toolsDir.appendingPathComponent("bun-1.1.0"))
    }

    func testRootfsImagePath() {
        let paths = FendPaths()
        XCTAssertEqual(paths.rootfsImagePath, paths.runtimeDir.appendingPathComponent("rootfs.img"))
    }
}
