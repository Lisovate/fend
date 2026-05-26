import Foundation
import FendCommon

/// Severity of a single doctor check.
enum CheckStatus {
    case pass
    case warn
    case fail

    var bracket: String {
        switch self {
        case .pass: return "[✓]"
        case .warn: return "[!]"
        case .fail: return "[✗]"
        }
    }

    var color: TerminalUI.ANSIColor {
        switch self {
        case .pass: return .green
        case .warn: return .yellow
        case .fail: return .red
        }
    }
}

/// A logical grouping of related checks. `required: false` sections never
/// influence the process exit code — a failed optional section renders as
/// `[!]` and explains itself.
struct DoctorSection {
    let title: String
    let required: Bool
    var status: CheckStatus
    var fields: [(label: String, value: String, status: CheckStatus?)]
    var notes: [String]
}

/// Why this check thinks we're in developer mode (or not).
enum DevModeSource: Equatable {
    case envOverride           // FEND_DEV=1
    case repoCheckout(String)  // .git directory found at <path>
    case unsignedBinary        // codesign reports unsigned
    case none
}

enum DoctorChecks {
    /// Build the full set of sections for the current host.
    static func sections(paths: FendPaths, config: FendConfig) -> [DoctorSection] {
        var sections: [DoctorSection] = []

        sections.append(systemSection())
        sections.append(runtimeSection(paths: paths))
        sections.append(signatureSection())

        let dev = detectDevMode()
        sections.append(contributorSection(devMode: dev))

        return sections
    }

    /// Process exit code derived from a doctor report: 0 unless a required
    /// section failed. Mirrors flutter doctor's "optional failures don't
    /// change the exit code" behaviour.
    static func exitCode(for sections: [DoctorSection]) -> Int32 {
        for section in sections where section.required && section.status == .fail {
            return 1
        }
        return 0
    }

    // MARK: - System

    private static func systemSection() -> DoctorSection {
        let info = ProcessInfo.processInfo
        let fields: [(String, String, CheckStatus?)] = [
            ("macOS", info.operatingSystemVersionString, nil),
            ("architecture", currentArchitecture(), nil),
        ]
        return DoctorSection(
            title: "System",
            required: true,
            status: .pass,
            fields: fields,
            notes: []
        )
    }

    // MARK: - Guest runtime

    private static func runtimeSection(paths: FendPaths) -> DoctorSection {
        let fm = FileManager.default
        let kernel = paths.runtimeDir.appendingPathComponent("vmlinuz")
        let initrd = paths.runtimeDir.appendingPathComponent("initrd")
        let rootfs = paths.rootfsImagePath
        let versionFile = paths.runtimeDir.appendingPathComponent(".version")

        let kernelOK = fm.fileExists(atPath: kernel.path)
        let initrdOK = fm.fileExists(atPath: initrd.path)
        let rootfsOK = fm.fileExists(atPath: rootfs.path)

        let onDisk = (try? String(contentsOf: versionFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = RuntimeManifest.runtimeVersion

        var versionLabel: String
        var versionStatus: CheckStatus
        if let onDisk = onDisk, !onDisk.isEmpty {
            if onDisk == expected || onDisk == "source-\(expected)" {
                versionLabel = onDisk
                versionStatus = .pass
            } else {
                versionLabel = "\(onDisk) (expected \(expected)) — out of date"
                versionStatus = .warn
            }
        } else if kernelOK && initrdOK && rootfsOK {
            versionLabel = "unknown (no .version sentinel)"
            versionStatus = .warn
        } else {
            versionLabel = "not installed (expected \(expected))"
            versionStatus = .fail
        }

        let fields: [(String, String, CheckStatus?)] = [
            ("version", versionLabel, versionStatus),
            ("kernel", artifactValue(kernel, exists: kernelOK), kernelOK ? .pass : .fail),
            ("initrd", artifactValue(initrd, exists: initrdOK), initrdOK ? .pass : .fail),
            ("rootfs", artifactValue(rootfs, exists: rootfsOK), rootfsOK ? .pass : .fail),
        ]

        let allPresent = kernelOK && initrdOK && rootfsOK
        let status: CheckStatus
        var notes: [String] = []
        if allPresent && versionStatus == .pass {
            status = .pass
        } else if allPresent && versionStatus == .warn {
            status = .warn
            notes.append("Runtime artifacts are an older fend version. Run `fend setup` to refresh.")
        } else {
            status = .fail
            if RuntimeManifest.isDevBuild {
                notes.append("This fend was built from source. Run `fend setup --build-from-source` to populate the runtime locally.")
            } else {
                notes.append("Run `fend setup` to download and install the runtime (~600 MB, one-time).")
            }
        }

        return DoctorSection(
            title: "Guest runtime",
            required: true,
            status: status,
            fields: fields,
            notes: notes
        )
    }

    // MARK: - Binary signature

    private static func signatureSection() -> DoctorSection {
        let signing = readSigningInfo()
        let fields: [(String, String, CheckStatus?)] = [
            ("identity", signing.identity ?? "unsigned", signing.identity == nil ? .warn : .pass),
            ("notarized", signing.notarized ? "yes" : "no", signing.notarized ? .pass : .warn),
        ]

        let status: CheckStatus = signing.identity != nil ? .pass : .warn
        var notes: [String] = []
        if signing.identity == nil {
            notes.append("Running an unsigned fend (likely a from-source build).")
        }

        return DoctorSection(
            title: "Binary signature",
            required: false,
            status: status,
            fields: fields,
            notes: notes
        )
    }

    // MARK: - Contributor tools

    private static func contributorSection(devMode: DevModeSource) -> DoctorSection {
        let dockerRunning = processSucceeds("/usr/bin/env", arguments: ["docker", "info"])
        let dockerInstalled = processSucceeds("/usr/bin/env", arguments: ["which", "docker"])
        let rustInstalled = processSucceeds("/usr/bin/env", arguments: ["which", "cargo"])

        let modeLabel: String
        switch devMode {
        case .envOverride: modeLabel = "developer (FEND_DEV=1)"
        case .repoCheckout(let path): modeLabel = "developer (.git at \(path))"
        case .unsignedBinary: modeLabel = "developer (unsigned binary)"
        case .none: modeLabel = "end user"
        }

        let dockerLabel: String
        let dockerStatus: CheckStatus
        if dockerRunning {
            dockerLabel = "running"
            dockerStatus = .pass
        } else if dockerInstalled {
            dockerLabel = "installed but daemon not running"
            dockerStatus = .warn
        } else {
            dockerLabel = "not installed"
            dockerStatus = .warn
        }

        let rustLabel = rustInstalled ? "installed" : "not installed"
        let rustStatus: CheckStatus = rustInstalled ? .pass : .warn

        let fields: [(String, String, CheckStatus?)] = [
            ("mode", modeLabel, nil),
            ("docker", dockerLabel, dockerStatus),
            ("rust toolchain", rustLabel, rustStatus),
        ]

        // The section status reflects worst-of, but it is non-required so
        // it never changes exit code. We use [!] when anything is missing
        // and the user is plausibly going to build from source.
        let isDev = devMode != .none
        let anyMissing = dockerStatus != .pass || rustStatus != .pass
        let status: CheckStatus = anyMissing ? .warn : .pass

        var notes: [String] = []
        if isDev && anyMissing {
            notes.append("Docker + Rust are only needed if you run `fend setup --build-from-source`.")
        } else if !isDev {
            notes.append("These tools are only needed by contributors; end-user setup uses the prebuilt runtime.")
        }

        return DoctorSection(
            title: "Contributor tools (optional)",
            required: false,
            status: status,
            fields: fields,
            notes: notes
        )
    }

    // MARK: - Dev mode detection

    /// Decide whether this fend appears to be running as part of a
    /// contributor / from-source build (we want `fend doctor` to soften
    /// missing-Docker complaints in that case, and harden them when we're
    /// sure we're talking to an end user).
    ///
    /// Order of signals:
    ///   1. FEND_DEV=1 env var — explicit, wins.
    ///   2. .git ancestor of the running binary's path — strongest passive
    ///      signal that we are inside a checkout.
    ///   3. Unsigned binary — release builds are always Developer-ID-signed
    ///      and notarized; unsigned means a local `swift build`.
    static func detectDevMode() -> DevModeSource {
        if let v = ProcessInfo.processInfo.environment["FEND_DEV"],
           v == "1" || v.lowercased() == "true" {
            return .envOverride
        }

        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        var dir = exe.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<8 {
            let dotGit = dir.appendingPathComponent(".git")
            if fm.fileExists(atPath: dotGit.path) {
                return .repoCheckout(dir.path)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        if readSigningInfo().identity == nil {
            return .unsignedBinary
        }

        return .none
    }

    // MARK: - Helpers

    /// Codesign info for the running binary. The release pipeline signs
    /// every macOS build with a Developer ID + notarizes it, so an unsigned
    /// binary is a strong tell that we're in a from-source build.
    struct SigningInfo {
        let identity: String?
        let notarized: Bool
    }

    static func readSigningInfo() -> SigningInfo {
        let exe = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? "/usr/bin/fend"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["-dv", "--verbose=2", exe]
        let stderr = Pipe()
        task.standardError = stderr
        task.standardOutput = Pipe()
        do { try task.run() } catch { return SigningInfo(identity: nil, notarized: false) }
        task.waitUntilExit()
        let raw = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        var identity: String?
        for line in raw.split(separator: "\n") {
            if line.hasPrefix("Authority=Developer ID Application:") {
                identity = String(line.dropFirst("Authority=".count))
                break
            }
        }

        let notarized = raw.contains("flags=0x10000(runtime)")
            || raw.contains("CodeDirectory") && raw.contains("notarized=true")
        return SigningInfo(identity: identity, notarized: notarized && identity != nil)
    }

    private static func artifactValue(_ url: URL, exists: Bool) -> String {
        exists ? url.path : "missing"
    }

    private static func currentArchitecture() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    private static func processSucceeds(_ executable: String, arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: executable)
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
