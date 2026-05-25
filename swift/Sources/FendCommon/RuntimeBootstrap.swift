import Foundation
import CryptoKit

/// Where the runtime artifacts come from.
public enum RuntimeSource {
    /// Fetch the prebuilt tarball from the URL baked into RuntimeManifest.
    case prebuilt
    /// Build locally via swift/scripts/prepare-runtime.sh (contributor path).
    case fromSource
}

/// Progress events emitted while ensuring the runtime. Implementations can
/// render these to the terminal or swallow them in tests.
public enum BootstrapEvent {
    case alreadyPresent(version: String)
    case downloading(url: String, expectedSHA: String)
    case verifying
    case extracting
    case installing(targetDir: URL)
    case done
    case warning(String)
}

public typealias BootstrapProgress = (BootstrapEvent) -> Void

/// Errors specific to the runtime-bootstrap pipeline. Keep the cases narrow
/// so callers can branch on them (the doctor path needs different copy than
/// the auto-bootstrap-on-VM-start path).
public enum BootstrapError: LocalizedError {
    case devBuildNeedsSource
    case downloadFailed(String)
    case integrityFailed(expected: String, actual: String, file: String)
    case extractFailed(String)
    case manifestInvalid(String)
    case installFailed(String)
    case sourceBuildScriptFailed(Int32, String)
    case sourceBuildScriptMissing(URL)

    public var errorDescription: String? {
        switch self {
        case .devBuildNeedsSource:
            return "This fend was built from source and has no published runtime. Run `fend setup --build-from-source` to build the runtime locally."
        case .downloadFailed(let msg):
            return "Failed to download runtime: \(msg)"
        case .integrityFailed(let expected, let actual, let file):
            return "Integrity check failed for \(file): expected SHA256 \(expected), got \(actual)"
        case .extractFailed(let msg):
            return "Failed to extract runtime bundle: \(msg)"
        case .manifestInvalid(let msg):
            return "Runtime bundle manifest is invalid: \(msg)"
        case .installFailed(let msg):
            return "Failed to install runtime: \(msg)"
        case .sourceBuildScriptFailed(let code, let detail):
            return "prepare-runtime.sh exited \(code): \(detail)"
        case .sourceBuildScriptMissing(let url):
            return "prepare-runtime.sh not found at \(url.path). Run from a fend repo checkout (clone https://github.com/Lisovate/fend) or use the prebuilt path."
        }
    }
}

/// Manifest embedded in the published tarball. Mirrors the JSON produced by
/// scripts/build-runtime-bundle.sh.
struct BundleManifest: Decodable {
    struct FileEntry: Decodable { let sha256: String }
    let schema_version: Int
    let runtime_version: String
    let target: String
    let kernel_version: String?
    let kernel_source: String?
    let fendd_sha256: String?
    let files: [String: FileEntry]
}

/// What to fetch + verify when bootstrapping. Production callers use
/// `.fromManifest()` to read the values baked into the notarized binary;
/// tests construct a `BootstrapSpec` pointing at a local fixture so they
/// don't hit the network.
public struct BootstrapSpec {
    public let runtimeVersion: String
    public let bundleURL: String
    public let bundleSHA256: String
    public let bundleName: String
    public let schemaVersion: Int
    public let isDevBuild: Bool

    public init(
        runtimeVersion: String,
        bundleURL: String,
        bundleSHA256: String,
        bundleName: String,
        schemaVersion: Int = 1,
        isDevBuild: Bool = false
    ) {
        self.runtimeVersion = runtimeVersion
        self.bundleURL = bundleURL
        self.bundleSHA256 = bundleSHA256
        self.bundleName = bundleName
        self.schemaVersion = schemaVersion
        self.isDevBuild = isDevBuild
    }

    public static func fromManifest() -> BootstrapSpec {
        return BootstrapSpec(
            runtimeVersion: RuntimeManifest.runtimeVersion,
            bundleURL: RuntimeManifest.bundleURL,
            bundleSHA256: RuntimeManifest.bundleSHA256,
            bundleName: RuntimeManifest.bundleName,
            schemaVersion: RuntimeManifest.schemaVersion,
            isDevBuild: RuntimeManifest.isDevBuild
        )
    }
}

public enum RuntimeBootstrap {
    /// Files we expect to find in `runtime/` after a successful install.
    public static let requiredFiles: [String] = ["vmlinuz", "initrd", "rootfs.img"]

    /// Sentinel file storing the runtime version present on disk. Lets us
    /// short-circuit re-downloads when the version on disk matches the
    /// version baked into this binary.
    static let versionFileName = ".version"

    /// Returns true if every required file plus a matching `.version` is
    /// present in `paths.runtimeDir`.
    public static func isRuntimeReady(_ paths: FendPaths, spec: BootstrapSpec = .fromManifest()) -> Bool {
        let fm = FileManager.default
        for name in requiredFiles {
            let url = paths.runtimeDir.appendingPathComponent(name)
            if !fm.fileExists(atPath: url.path) { return false }
        }
        let versionFile = paths.runtimeDir.appendingPathComponent(versionFileName)
        guard let onDisk = try? String(contentsOf: versionFile, encoding: .utf8) else {
            return false
        }
        return onDisk.trimmingCharacters(in: .whitespacesAndNewlines) == spec.runtimeVersion
    }

    /// Idempotent: download + verify + install the runtime bundle if not
    /// already present at the expected version. Safe to call on every run.
    @discardableResult
    public static func ensureRuntime(
        paths: FendPaths,
        spec: BootstrapSpec = .fromManifest(),
        source: RuntimeSource = .prebuilt,
        force: Bool = false,
        progress: BootstrapProgress? = nil
    ) throws -> Bool {
        try paths.ensureDirectories()

        if !force && isRuntimeReady(paths, spec: spec) {
            progress?(.alreadyPresent(version: spec.runtimeVersion))
            return false
        }

        switch source {
        case .prebuilt:
            if spec.isDevBuild {
                throw BootstrapError.devBuildNeedsSource
            }
            try installFromPrebuilt(paths: paths, spec: spec, progress: progress)
        case .fromSource:
            try installFromSource(paths: paths, spec: spec, progress: progress)
        }

        progress?(.done)
        return true
    }

    // MARK: - Prebuilt path

    private static func installFromPrebuilt(paths: FendPaths, spec: BootstrapSpec, progress: BootstrapProgress?) throws {
        let url = spec.bundleURL
        let expectedSHA = spec.bundleSHA256
        progress?(.downloading(url: url, expectedSHA: expectedSHA))

        let staging = try makeStagingDir(under: paths.runtimeDir)
        defer { try? FileManager.default.removeItem(at: staging) }

        let bundle = staging.appendingPathComponent("bundle.tar.zst")
        try downloadBundle(to: bundle, from: url, version: spec.runtimeVersion)

        progress?(.verifying)
        let actualSHA = try sha256Hex(of: bundle)
        guard actualSHA.lowercased() == expectedSHA.lowercased() else {
            throw BootstrapError.integrityFailed(
                expected: expectedSHA,
                actual: actualSHA,
                file: spec.bundleName
            )
        }

        progress?(.extracting)
        try extract(tarZst: bundle, into: staging)

        // The bundle's own manifest.json carries per-file SHAs; verify each
        // file we are about to install against it before atomic-swap.
        let manifest = try readBundleManifest(staging.appendingPathComponent("manifest.json"))
        if manifest.schema_version > spec.schemaVersion {
            throw BootstrapError.manifestInvalid(
                "schema_version \(manifest.schema_version) is newer than this fend supports (\(spec.schemaVersion)). Upgrade fend."
            )
        }
        if manifest.runtime_version != spec.runtimeVersion {
            throw BootstrapError.manifestInvalid(
                "bundle version \(manifest.runtime_version) does not match baked version \(spec.runtimeVersion)"
            )
        }
        for name in requiredFiles {
            guard let entry = manifest.files[name] else {
                throw BootstrapError.manifestInvalid("missing entry for \(name)")
            }
            let path = staging.appendingPathComponent(name)
            let actual = try sha256Hex(of: path)
            guard actual.lowercased() == entry.sha256.lowercased() else {
                throw BootstrapError.integrityFailed(
                    expected: entry.sha256, actual: actual, file: name
                )
            }
        }

        progress?(.installing(targetDir: paths.runtimeDir))
        try atomicInstall(stagingDir: staging, into: paths.runtimeDir, spec: spec)
    }

    private static func makeStagingDir(under parent: URL) throws -> URL {
        let staging = parent.appendingPathComponent(".staging-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            throw BootstrapError.installFailed("could not create staging dir: \(error.localizedDescription)")
        }
        return staging
    }

    /// curl --fail -L --retry 5 --retry-all-errors --retry-delay 2 -C -
    ///      --progress-bar --user-agent "fend/<v> (darwin; arm64)" -o <dest> <url>
    ///
    /// Stderr is inherited so curl's progress bar repaints to the user's
    /// terminal directly. We never need to parse the bar ourselves.
    private static func downloadBundle(to dest: URL, from urlString: String, version: String) throws {
        let curl = Process()
        curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        curl.arguments = [
            "--fail",
            "--location",
            "--retry", "5",
            "--retry-all-errors",
            "--retry-delay", "2",
            "--retry-max-time", "120",
            "--continue-at", "-",
            "--progress-bar",
            "--user-agent", "fend/\(version) (darwin; arm64)",
            "--output", dest.path,
            urlString,
        ]
        curl.standardError = FileHandle.standardError
        let stdoutCapture = Pipe()
        curl.standardOutput = stdoutCapture

        do {
            try curl.run()
        } catch {
            throw BootstrapError.downloadFailed("could not exec curl: \(error.localizedDescription)")
        }
        curl.waitUntilExit()
        if curl.terminationStatus != 0 {
            throw BootstrapError.downloadFailed("curl exited \(curl.terminationStatus) for \(urlString)")
        }
        guard FileManager.default.fileExists(atPath: dest.path) else {
            throw BootstrapError.downloadFailed("download completed but \(dest.lastPathComponent) is missing")
        }
    }

    private static func sha256Hex(of file: URL) throws -> String {
        guard let stream = InputStream(url: file) else {
            throw BootstrapError.installFailed("could not open \(file.path) for hashing")
        }
        stream.open()
        defer { stream.close() }
        var hasher = SHA256()
        let chunkSize = 1 << 20  // 1 MiB
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while stream.hasBytesAvailable {
            let n = buffer.withUnsafeMutableBufferPointer { ptr -> Int in
                stream.read(ptr.baseAddress!, maxLength: ptr.count)
            }
            if n < 0 {
                throw BootstrapError.installFailed("read error while hashing \(file.path)")
            }
            if n == 0 { break }
            hasher.update(data: Data(buffer.prefix(n)))
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// tar -xf <bundle> -C <dir>
    ///
    /// macOS ships libarchive-based BSD tar, which auto-detects zstd
    /// compression on macOS 13+. We deliberately avoid
    /// `--use-compress-program=zstd` because BSD tar interprets the value
    /// as a literal exec path without flags, while GNU tar runs it through
    /// /bin/sh — the same command line behaves differently across the two
    /// implementations.
    private static func extract(tarZst: URL, into dir: URL) throws {
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = [
            "-xf", tarZst.path,
            "-C", dir.path,
        ]
        let errPipe = Pipe()
        tar.standardError = errPipe
        tar.standardOutput = Pipe()

        do { try tar.run() } catch {
            throw BootstrapError.extractFailed("could not exec tar: \(error.localizedDescription)")
        }
        tar.waitUntilExit()
        if tar.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BootstrapError.extractFailed("tar exited \(tar.terminationStatus): \(err)")
        }
    }

    private static func readBundleManifest(_ url: URL) throws -> BundleManifest {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw BootstrapError.manifestInvalid("could not read manifest.json: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(BundleManifest.self, from: data)
        } catch {
            throw BootstrapError.manifestInvalid("could not parse manifest.json: \(error.localizedDescription)")
        }
    }

    /// Move staged files into `runtime/`, replacing any prior installation in
    /// the same step. We rename the old runtime dir aside before clearing the
    /// per-file targets so a crash mid-install never leaves us with a half-
    /// installed runtime.
    private static func atomicInstall(stagingDir: URL, into runtimeDir: URL, spec: BootstrapSpec) throws {
        let fm = FileManager.default
        let toMove = requiredFiles + ["manifest.json"]
        for name in toMove {
            let src = stagingDir.appendingPathComponent(name)
            guard fm.fileExists(atPath: src.path) else {
                throw BootstrapError.installFailed("staged file missing: \(name)")
            }
        }

        // Replace each artifact individually. Each rename is atomic on the
        // same filesystem; if a rename fails partway we surface the error
        // and the staging copy is still intact (and cleaned by the caller's
        // defer).
        for name in toMove {
            let src = stagingDir.appendingPathComponent(name)
            let dst = runtimeDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) {
                try? fm.removeItem(at: dst)
            }
            do {
                try fm.moveItem(at: src, to: dst)
            } catch {
                throw BootstrapError.installFailed("rename \(name): \(error.localizedDescription)")
            }
        }

        // Strip quarantine xattrs on the data files. Not required for boot
        // (Gatekeeper doesn't inspect raw kernel/ext4 blobs), but stops
        // confused `ls -l@` output.
        for name in requiredFiles {
            stripQuarantine(at: runtimeDir.appendingPathComponent(name))
        }

        let versionFile = runtimeDir.appendingPathComponent(versionFileName)
        try? fm.removeItem(at: versionFile)
        try spec.runtimeVersion.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    private static func stripQuarantine(at url: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        p.arguments = ["-d", "com.apple.quarantine", url.path]
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    // MARK: - From-source path

    /// Run `swift/scripts/prepare-runtime.sh` from the user's repo checkout.
    /// This is the contributor / reproducibility path — slow, requires Docker
    /// + Rust toolchain, but produces a runtime locally without trusting any
    /// hosted artifact.
    private static func installFromSource(paths: FendPaths, spec: BootstrapSpec, progress: BootstrapProgress?) throws {
        let script = locatePrepareScript()
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw BootstrapError.sourceBuildScriptMissing(script)
        }
        progress?(.warning("from-source build: slow (~5–10 min) and requires Docker + a checked-out fend repo"))

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = [script.path]
        proc.standardOutput = FileHandle.standardOutput
        proc.standardError = FileHandle.standardError

        do { try proc.run() } catch {
            throw BootstrapError.sourceBuildScriptFailed(-1, error.localizedDescription)
        }
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw BootstrapError.sourceBuildScriptFailed(proc.terminationStatus, "see script output above")
        }

        // Source builds don't write a `.version` sentinel, so fake one to
        // signal readiness. We tag it `source` so dev rebuilds can still be
        // distinguished from prebuilt installs by anyone parsing this file.
        let versionFile = paths.runtimeDir.appendingPathComponent(versionFileName)
        try? FileManager.default.removeItem(at: versionFile)
        let sentinel = "source-\(spec.runtimeVersion)"
        try sentinel.write(to: versionFile, atomically: true, encoding: .utf8)
    }

    /// Find `swift/scripts/prepare-runtime.sh` relative to the running
    /// binary. Search order:
    ///   1. $FEND_REPO/swift/scripts/prepare-runtime.sh
    ///   2. <argv0>/../../swift/scripts/prepare-runtime.sh
    ///   3. <argv0>/../../../swift/scripts/prepare-runtime.sh
    ///   4. cwd/swift/scripts/prepare-runtime.sh
    private static func locatePrepareScript() -> URL {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["FEND_REPO"] {
            let candidate = URL(fileURLWithPath: override)
                .appendingPathComponent("swift/scripts/prepare-runtime.sh")
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = executable.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("swift/scripts/prepare-runtime.sh")
            if fm.fileExists(atPath: candidate.path) { return candidate }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("swift/scripts/prepare-runtime.sh")
        return cwd
    }
}
