import XCTest
@testable import FendCommon
@testable import FendCLI

final class WatchPolicyTests: XCTestCase {
    func testAutoUsesPollingForLinuxDevCommands() throws {
        let plan = try WatchPolicy.resolve(
            requestedMode: .auto,
            command: ["npm", "run", "dev"],
            pollIntervalMs: 500,
            hostOS: .linux
        )

        XCTAssertEqual(plan.effectiveMode, .polling)
        XCTAssertTrue(plan.usesPolling)
    }

    func testAutoUsesNativeForMacDevCommands() throws {
        let plan = try WatchPolicy.resolve(
            requestedMode: .auto,
            command: ["npm", "run", "dev"],
            pollIntervalMs: 500,
            hostOS: .macOS
        )

        XCTAssertEqual(plan.effectiveMode, .native)
        XCTAssertFalse(plan.usesPolling)
    }

    func testAutoUsesNativeForLinuxNonDevCommands() throws {
        let plan = try WatchPolicy.resolve(
            requestedMode: .auto,
            command: ["npm", "test"],
            pollIntervalMs: 500,
            hostOS: .linux
        )

        XCTAssertEqual(plan.effectiveMode, .native)
        XCTAssertFalse(plan.usesPolling)
    }

    func testExplicitPollingInjectsWatcherEnvironment() throws {
        let plan = try WatchPolicy.resolve(
            requestedMode: .polling,
            command: ["npm", "test"],
            pollIntervalMs: 750,
            hostOS: .macOS
        )
        var env: [String: String] = [:]

        WatchPolicy.apply(plan, to: &env)

        XCTAssertEqual(env["FEND_WATCH_MODE"], "polling")
        XCTAssertEqual(env["FEND_WATCH_POLL_INTERVAL_MS"], "750")
        XCTAssertEqual(env["CHOKIDAR_USEPOLLING"], "true")
        XCTAssertEqual(env["CHOKIDAR_INTERVAL"], "750")
        XCTAssertEqual(env["WATCHPACK_POLLING"], "true")
    }

    func testNativeDoesNotInjectPollingEnvironment() throws {
        let plan = try WatchPolicy.resolve(
            requestedMode: .native,
            command: ["npm", "run", "dev"],
            pollIntervalMs: 500,
            hostOS: .linux
        )
        var env: [String: String] = [:]

        WatchPolicy.apply(plan, to: &env)

        XCTAssertEqual(env["FEND_WATCH_MODE"], "native")
        XCTAssertNil(env["CHOKIDAR_USEPOLLING"])
        XCTAssertNil(env["CHOKIDAR_INTERVAL"])
        XCTAssertNil(env["WATCHPACK_POLLING"])
    }

    func testMirrorModeFailsBeforeExecution() {
        XCTAssertThrowsError(try WatchPolicy.resolve(
            requestedMode: .mirror,
            command: ["npm", "run", "dev"],
            pollIntervalMs: 500,
            hostOS: .linux
        ))
    }

    func testDevCommandDetectionCoversCommonTools() {
        XCTAssertTrue(WatchPolicy.isLikelyDevCommand(["vite"]))
        XCTAssertTrue(WatchPolicy.isLikelyDevCommand(["next", "dev"]))
        XCTAssertTrue(WatchPolicy.isLikelyDevCommand(["pnpm", "--filter", "app", "dev"]))
        XCTAssertTrue(WatchPolicy.isLikelyDevCommand(["bunx", "vite"]))
        XCTAssertTrue(WatchPolicy.isLikelyDevCommand(["npx", "--yes", "vite"]))
        XCTAssertTrue(WatchPolicy.isLikelyDevCommand(["webpack", "serve"]))

        XCTAssertFalse(WatchPolicy.isLikelyDevCommand(["npm", "install"]))
        XCTAssertFalse(WatchPolicy.isLikelyDevCommand(["pnpm", "add", "vite"]))
        XCTAssertFalse(WatchPolicy.isLikelyDevCommand(["npm", "test"]))
    }
}
