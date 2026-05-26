import XCTest
import CryptoKit
@testable import FendCommon

final class RuntimeBootstrapTests: XCTestCase {

    // MARK: - Helpers

    /// Build a self-contained fixture bundle on disk:
    ///   <fixtureDir>/fixture.tar.zst
    /// The tar contains vmlinuz / initrd / rootfs.img with the given byte
    /// payloads plus a matching manifest.json. Returns the bundle path and
    /// SHA256 so tests can plug them into a BootstrapSpec.
    private func makeFixtureBundle(
        version: String,
        kernel: Data = Data("kernel-bytes".utf8),
        initrd: Data = Data("initrd-bytes".utf8),
        rootfs: Data = Data("rootfs-bytes".utf8),
        manifestVersionOverride: String? = nil,
        schemaVersion: Int = 1,
        tamperPerFileSHA: Bool = false
    ) throws -> (bundleURL: URL, sha256: String) {
        let fm = FileManager.default
        let dir = try makeTempDir(prefix: "fixture")
        let stage = dir.appendingPathComponent("stage")
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)

        try kernel.write(to: stage.appendingPathComponent("vmlinuz"))
        try initrd.write(to: stage.appendingPathComponent("initrd"))
        try rootfs.write(to: stage.appendingPathComponent("rootfs.img"))

        var kernelSHA = sha256Hex(kernel)
        let initrdSHA = sha256Hex(initrd)
        let rootfsSHA = sha256Hex(rootfs)
        if tamperPerFileSHA {
            kernelSHA = String(repeating: "0", count: 64)
        }

        let manifest: [String: Any] = [
            "schema_version": schemaVersion,
            "runtime_version": manifestVersionOverride ?? version,
            "target": "darwin-arm64",
            "kernel_version": "6.8.0-test",
            "kernel_source": "https://example.invalid/vmlinuz",
            "fendd_sha256": String(repeating: "f", count: 64),
            "files": [
                "vmlinuz": ["sha256": kernelSHA],
                "initrd": ["sha256": initrdSHA],
                "rootfs.img": ["sha256": rootfsSHA],
            ],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: stage.appendingPathComponent("manifest.json"))

        let bundle = dir.appendingPathComponent("fixture.tar.zst")
        // BSD tar (macOS) treats --use-compress-program as the program path
        // verbatim, so we can't pass flags. Run the pipeline as a shell
        // invocation instead, which mirrors what real production CI uses.
        let shellProc = Process()
        shellProc.executableURL = URL(fileURLWithPath: "/bin/bash")
        let script = """
        set -e
        cd \(shellQuoted(stage.path))
        /usr/bin/tar -cf - vmlinuz initrd rootfs.img manifest.json \
          | /usr/bin/env zstd -q -19 -T0 -o \(shellQuoted(bundle.path))
        """
        shellProc.arguments = ["-c", script]
        let errPipe = Pipe()
        shellProc.standardError = errPipe
        try shellProc.run()
        shellProc.waitUntilExit()
        if shellProc.terminationStatus != 0 {
            let stderr = String(
                data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""
            XCTFail("fixture tar/zstd failed (\(shellProc.terminationStatus)): \(stderr)")
        }

        let bundleData = try Data(contentsOf: bundle)
        return (bundle, sha256Hex(bundleData))
    }

    private func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func makeTempDir(prefix: String) throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("\(prefix)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func shellQuoted(_ s: String) -> String {
        // POSIX-safe single-quote escape: ' -> '\''
        let escaped = s.replacingOccurrences(of: "'", with: "'\\''")
        return "'\(escaped)'"
    }

    private func makePaths() throws -> FendPaths {
        let home = try makeTempDir(prefix: "fend-home")
        let paths = FendPaths(home: home)
        try paths.ensureDirectories()
        return paths
    }

    // MARK: - Happy path

    func testInstallsRuntimeFromFileURL() throws {
        let version = "0.1.0-test.\(UUID().uuidString.prefix(8))"
        let (bundleURL, sha) = try makeFixtureBundle(version: version)
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: version,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: sha,
            bundleName: bundleURL.lastPathComponent
        )

        let installed = try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)
        XCTAssertTrue(installed)

        for name in RuntimeBootstrap.requiredFiles {
            let p = paths.runtimeDir.appendingPathComponent(name)
            XCTAssertTrue(FileManager.default.fileExists(atPath: p.path), "missing \(name)")
        }
        let version_ = try String(contentsOf: paths.runtimeDir.appendingPathComponent(".version"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(version_, version)
    }

    func testIdempotentNoOpOnSecondCall() throws {
        let version = "0.1.0-test.\(UUID().uuidString.prefix(8))"
        let (bundleURL, sha) = try makeFixtureBundle(version: version)
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: version,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: sha,
            bundleName: bundleURL.lastPathComponent
        )

        let firstInstalled = try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)
        XCTAssertTrue(firstInstalled, "first call should install")

        var sawAlreadyPresent = false
        let secondInstalled = try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec) { event in
            if case .alreadyPresent = event { sawAlreadyPresent = true }
        }
        XCTAssertFalse(secondInstalled, "second call should be a no-op")
        XCTAssertTrue(sawAlreadyPresent, "second call should emit alreadyPresent")
    }

    func testForceTriggersReinstallEvenWhenPresent() throws {
        let version = "0.1.0-test.\(UUID().uuidString.prefix(8))"
        let (bundleURL, sha) = try makeFixtureBundle(version: version)
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: version,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: sha,
            bundleName: bundleURL.lastPathComponent
        )

        _ = try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)
        let kernelPath = paths.runtimeDir.appendingPathComponent("vmlinuz")
        let before = try Data(contentsOf: kernelPath)

        // Touch the kernel file to a different mtime then re-run with
        // --force. We don't have a way to easily prove the file was
        // overwritten without inspecting inode ids, but a successful
        // install (no throw) + correct content is enough.
        let installed = try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec, force: true)
        XCTAssertTrue(installed, "force should reinstall")
        let after = try Data(contentsOf: kernelPath)
        XCTAssertEqual(before, after, "reinstalled kernel should match fixture bytes")
    }

    // MARK: - Verification failures

    func testRejectsBundleWithWrongSHA() throws {
        let version = "0.1.0-test.\(UUID().uuidString.prefix(8))"
        let (bundleURL, _) = try makeFixtureBundle(version: version)
        let paths = try makePaths()
        let wrongSHA = String(repeating: "a", count: 64)
        let spec = BootstrapSpec(
            runtimeVersion: version,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: wrongSHA,
            bundleName: bundleURL.lastPathComponent
        )

        XCTAssertThrowsError(try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)) { error in
            guard case BootstrapError.integrityFailed(let expected, _, _) = error else {
                return XCTFail("expected integrityFailed, got \(error)")
            }
            XCTAssertEqual(expected, wrongSHA)
        }

        // Staging cleanup should not have left the runtime dir populated.
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: paths.runtimeDir.appendingPathComponent("vmlinuz").path),
            "failed install must not leave runtime files"
        )
    }

    func testRejectsBundleWithTamperedInnerSHA() throws {
        let version = "0.1.0-test.\(UUID().uuidString.prefix(8))"
        // The bundle's outer SHA matches (we compute it after building),
        // but the manifest.json lies about the kernel's SHA. The per-file
        // verification step should catch this even though the outer check
        // passes.
        let (bundleURL, sha) = try makeFixtureBundle(version: version, tamperPerFileSHA: true)
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: version,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: sha,
            bundleName: bundleURL.lastPathComponent
        )

        XCTAssertThrowsError(try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)) { error in
            guard case BootstrapError.integrityFailed(_, _, let file) = error else {
                return XCTFail("expected integrityFailed, got \(error)")
            }
            XCTAssertEqual(file, "vmlinuz")
        }
    }

    func testRejectsBundleWithVersionMismatch() throws {
        let realVersion = "0.1.0-real"
        let (bundleURL, sha) = try makeFixtureBundle(
            version: realVersion,
            manifestVersionOverride: "0.1.0-different"
        )
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: realVersion,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: sha,
            bundleName: bundleURL.lastPathComponent
        )

        XCTAssertThrowsError(try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)) { error in
            guard case BootstrapError.manifestInvalid = error else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
        }
    }

    func testRejectsBundleWithFutureSchemaVersion() throws {
        let version = "0.1.0-test.\(UUID().uuidString.prefix(8))"
        let (bundleURL, sha) = try makeFixtureBundle(version: version, schemaVersion: 99)
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: version,
            bundleURL: "file://\(bundleURL.path)",
            bundleSHA256: sha,
            bundleName: bundleURL.lastPathComponent
        )

        XCTAssertThrowsError(try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)) { error in
            guard case BootstrapError.manifestInvalid(let msg) = error else {
                return XCTFail("expected manifestInvalid, got \(error)")
            }
            XCTAssertTrue(msg.contains("schema_version"), msg)
        }
    }

    // MARK: - Download failures

    func testDownloadFailureWhenURLMissing() throws {
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: "0.1.0-test",
            bundleURL: "file:///definitely/not/here-\(UUID().uuidString).tar.zst",
            bundleSHA256: String(repeating: "a", count: 64),
            bundleName: "missing.tar.zst"
        )

        XCTAssertThrowsError(try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)) { error in
            guard case BootstrapError.downloadFailed = error else {
                return XCTFail("expected downloadFailed, got \(error)")
            }
        }
    }

    // MARK: - Dev build guard

    func testDevBuildRefusesPrebuiltPath() throws {
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: "dev",
            bundleURL: "",
            bundleSHA256: "",
            bundleName: "",
            isDevBuild: true
        )

        XCTAssertThrowsError(try RuntimeBootstrap.ensureRuntime(paths: paths, spec: spec)) { error in
            guard case BootstrapError.devBuildNeedsSource = error else {
                return XCTFail("expected devBuildNeedsSource, got \(error)")
            }
        }
    }

    // MARK: - Readiness probe

    func testIsRuntimeReadyChecksVersionSentinel() throws {
        let paths = try makePaths()
        let spec = BootstrapSpec(
            runtimeVersion: "1.2.3",
            bundleURL: "ignored",
            bundleSHA256: "ignored",
            bundleName: "ignored"
        )

        XCTAssertFalse(RuntimeBootstrap.isRuntimeReady(paths, spec: spec), "empty dir not ready")

        // Drop a file in place to simulate a partial install missing the
        // sentinel; should still be not-ready.
        for name in RuntimeBootstrap.requiredFiles {
            try Data("x".utf8).write(to: paths.runtimeDir.appendingPathComponent(name))
        }
        XCTAssertFalse(RuntimeBootstrap.isRuntimeReady(paths, spec: spec), "missing .version sentinel not ready")

        try "1.2.3".write(
            to: paths.runtimeDir.appendingPathComponent(".version"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertTrue(RuntimeBootstrap.isRuntimeReady(paths, spec: spec))

        // Differing on-disk version is also not-ready (forces re-download).
        try "9.9.9".write(
            to: paths.runtimeDir.appendingPathComponent(".version"),
            atomically: true,
            encoding: .utf8
        )
        XCTAssertFalse(RuntimeBootstrap.isRuntimeReady(paths, spec: spec))
    }
}
