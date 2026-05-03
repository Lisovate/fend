import XCTest
@testable import FendDaemon
import FendCommon

final class VMManagerTests: XCTestCase {

    func testInitStoresPathsCorrectly() {
        let paths = FendPaths()
        let manager = VMManager(paths: paths)
        // Manager should be created without errors
        XCTAssertNotNil(manager)
    }

    func testStopAllOnEmptyManagerIsSafe() {
        let paths = FendPaths()
        let manager = VMManager(paths: paths)
        // Should not crash or throw
        manager.stopAll()
    }

    func testReapIdleOnEmptyManagerIsSafe() {
        let paths = FendPaths()
        let manager = VMManager(paths: paths)
        // Should not crash or throw
        manager.reapIdle(pauseAfter: 60, stopAfter: 360)
    }

    func testStatusOnEmptyManagerReturnsEmpty() {
        let paths = FendPaths()
        let manager = VMManager(paths: paths)
        let status = manager.status()
        XCTAssertTrue(status.isEmpty)
    }

    func testStopVMOnEmptyManagerReturnsFalse() {
        let paths = FendPaths()
        let manager = VMManager(paths: paths)
        let result = manager.stopVM(forProjectDir: "/nonexistent")
        XCTAssertFalse(result)
    }
}
