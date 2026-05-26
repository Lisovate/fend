import Foundation
import XCTest
@testable import FendCLI
@testable import FendCommon

final class DoctorChecksTests: XCTestCase {

    // MARK: - Section status / exit-code mapping

    func testExitCodeZeroWhenAllRequiredPass() {
        let sections = [
            DoctorSection(
                title: "System",
                required: true,
                status: .pass,
                fields: [],
                notes: []
            ),
            DoctorSection(
                title: "Optional",
                required: false,
                status: .warn,
                fields: [],
                notes: []
            ),
        ]
        XCTAssertEqual(DoctorChecks.exitCode(for: sections), 0)
    }

    func testExitCodeOneWhenRequiredFails() {
        let sections = [
            DoctorSection(
                title: "Guest runtime",
                required: true,
                status: .fail,
                fields: [],
                notes: []
            ),
        ]
        XCTAssertEqual(DoctorChecks.exitCode(for: sections), 1)
    }

    func testOptionalFailureDoesNotChangeExitCode() {
        let sections = [
            DoctorSection(
                title: "Contributor",
                required: false,
                status: .fail,
                fields: [],
                notes: []
            ),
        ]
        XCTAssertEqual(DoctorChecks.exitCode(for: sections), 0)
    }

    // MARK: - Dev-mode detection priorities

    func testEnvOverrideWinsOverEverything() {
        let originalEnv = ProcessInfo.processInfo.environment["FEND_DEV"]
        setenv("FEND_DEV", "1", 1)
        defer {
            if let orig = originalEnv { setenv("FEND_DEV", orig, 1) }
            else { unsetenv("FEND_DEV") }
        }

        let mode = DoctorChecks.detectDevMode()
        XCTAssertEqual(mode, .envOverride)
    }

    func testEnvOverrideAcceptsTrueLiteral() {
        let originalEnv = ProcessInfo.processInfo.environment["FEND_DEV"]
        setenv("FEND_DEV", "true", 1)
        defer {
            if let orig = originalEnv { setenv("FEND_DEV", orig, 1) }
            else { unsetenv("FEND_DEV") }
        }

        XCTAssertEqual(DoctorChecks.detectDevMode(), .envOverride)
    }

    // MARK: - Runtime section reflects on-disk state

    func testRuntimeSectionPassesWhenAllFilesAndSentinelMatch() throws {
        let paths = try makeTempPaths()
        for name in RuntimeBootstrap.requiredFiles {
            try Data("x".utf8).write(to: paths.runtimeDir.appendingPathComponent(name))
        }
        try RuntimeManifest.runtimeVersion.write(
            to: paths.runtimeDir.appendingPathComponent(".version"),
            atomically: true,
            encoding: .utf8
        )

        let sections = DoctorChecks.sections(paths: paths, config: FendConfig.load(from: paths.home))
        let runtime = sections.first(where: { $0.title == "Guest runtime" })
        XCTAssertNotNil(runtime)
        XCTAssertEqual(runtime?.status, .pass)
    }

    func testRuntimeSectionFailsWhenArtifactsMissing() throws {
        let paths = try makeTempPaths()
        let sections = DoctorChecks.sections(paths: paths, config: FendConfig.load(from: paths.home))
        let runtime = sections.first(where: { $0.title == "Guest runtime" })
        XCTAssertEqual(runtime?.status, .fail)
        let kernelField = runtime?.fields.first { $0.label == "kernel" }
        XCTAssertEqual(kernelField?.status, .fail)
    }

    func testRuntimeSectionWarnsOnVersionDrift() throws {
        let paths = try makeTempPaths()
        for name in RuntimeBootstrap.requiredFiles {
            try Data("x".utf8).write(to: paths.runtimeDir.appendingPathComponent(name))
        }
        try "0.0.0-some-old-version".write(
            to: paths.runtimeDir.appendingPathComponent(".version"),
            atomically: true,
            encoding: .utf8
        )

        let sections = DoctorChecks.sections(paths: paths, config: FendConfig.load(from: paths.home))
        let runtime = sections.first(where: { $0.title == "Guest runtime" })
        XCTAssertEqual(runtime?.status, .warn)
    }

    // MARK: - Helpers

    private func makeTempPaths() throws -> FendPaths {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fend-doctor-test-\(UUID().uuidString)")
        let paths = FendPaths(home: home)
        try paths.ensureDirectories()
        return paths
    }
}
