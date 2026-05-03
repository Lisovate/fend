import Foundation
import FendCommon

/// Surface unexpected writes to the project directory during a sandboxed
/// command. An install that touches `.env`, `src/`, or writes a second
/// lockfile is much more suspicious than one that touches only the expected
/// lockfile / node_modules — this lets `fend log` tell you which.
enum FsDiff {
    /// Files that every package manager legitimately writes during install.
    /// Writes to these are not surprising and aren't reported.
    private static let expectedLockfiles: Set<String> = [
        "package.json",
        "package-lock.json",
        "npm-shrinkwrap.json",
        "yarn.lock",
        "pnpm-lock.yaml",
        "bun.lock",
        "bun.lockb",
    ]

    /// Top-level directories we skip entirely — too big to walk, and writes
    /// inside them during install are expected.
    private static let skipDirs: Set<String> = [
        "node_modules",
        ".git",
        ".fend",
        ".pnpm-store",
        "target",
        "build",
        "dist",
        "out",
        ".next",
        ".nuxt",
        ".cache",
        ".venv",
        "venv",
        "__pycache__",
    ]

    /// Snapshot the project tree's file mtimes (excluding heavy dirs).
    /// Used as the "before" state; after the install, call `changes(since:)`
    /// to find files written during the command.
    static func snapshotStart() -> Date { Date() }

    /// Return files in `projectDir` whose mtime is newer than `after`.
    /// Skips directories in `skipDirs` to keep the walk cheap.
    static func changes(in projectDir: URL, after: Date) -> FsDiffSummary {
        let fm = FileManager.default
        var changed: [String] = []
        var outsideCount = 0

        guard let enumerator = fm.enumerator(
            at: projectDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: []
        ) else {
            return FsDiffSummary(outsideNodeModules: 0, touchedFiles: [])
        }

        for case let url as URL in enumerator {
            let name = url.lastPathComponent

            // If we've descended into a skipped top-level dir, prune.
            let rel = relativePath(of: url, in: projectDir)
            if rel.components(separatedBy: "/").first.map(skipDirs.contains) == true {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isDirectoryKey]),
                  let mtime = values.contentModificationDate,
                  values.isDirectory == false else {
                continue
            }
            if mtime <= after { continue }

            // Skip hidden files named e.g. .DS_Store.
            if name == ".DS_Store" { continue }

            outsideCount += 1
            if expectedLockfiles.contains(name) { continue }
            changed.append(rel)
        }

        changed.sort()
        let sensitive = changed.filter(isSensitivePath)
        let risk = riskLevel(touchedFiles: changed, sensitiveFiles: sensitive)
        // Keep the log entry bounded — up to 50 unusual paths is plenty for triage.
        return FsDiffSummary(
            outsideNodeModules: outsideCount,
            touchedFiles: Array(changed.prefix(50)),
            risk: risk,
            sensitiveFiles: Array(sensitive.prefix(50))
        )
    }

    /// Print a short summary to stderr when unusual files were touched.
    /// Suppresses when only expected lockfiles changed.
    static func report(_ diff: FsDiffSummary) {
        guard !diff.touchedFiles.isEmpty else { return }
        let risk = diff.risk ?? "unknown"
        TerminalUI.blank()
        TerminalUI.warning("install touched files outside node_modules", detail: "\(diff.touchedFiles.count) file(s), \(risk) risk")
        for path in diff.touchedFiles.prefix(10) {
            let prefix = diff.sensitiveFiles?.contains(path) == true ? "  sensitive" : "  changed  "
            TerminalUI.line("\(prefix) \(path)", stream: .stderr)
        }
        if diff.touchedFiles.count > 10 {
            TerminalUI.hint("\(diff.touchedFiles.count - 10) more file(s)", detail: "see `fend log --json`")
        }
    }

    static func isSensitivePath(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        if name == ".env" || name.hasPrefix(".env.") { return true }
        if [".npmrc", ".yarnrc", ".pypirc", ".netrc"].contains(name) { return true }
        if ["id_rsa", "id_ed25519", "id_ecdsa"].contains(name) { return true }
        if lower.hasSuffix(".pem") || lower.hasSuffix(".key") || lower.hasSuffix(".p12") {
            return true
        }
        return false
    }

    private static func riskLevel(touchedFiles: [String], sensitiveFiles: [String]) -> String {
        if !sensitiveFiles.isEmpty { return "high" }
        if touchedFiles.contains(where: isSourceOrConfigPath) { return "medium" }
        return touchedFiles.isEmpty ? "low" : "medium"
    }

    private static func isSourceOrConfigPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        if lower.hasPrefix("src/") || lower.hasPrefix("app/") || lower.hasPrefix("pages/") {
            return true
        }
        let name = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        return [
            "vite.config.js",
            "vite.config.ts",
            "next.config.js",
            "next.config.mjs",
            "webpack.config.js",
            "tsconfig.json",
        ].contains(name)
    }

    private static func relativePath(of url: URL, in base: URL) -> String {
        let full = url.standardizedFileURL.path
        let root = base.standardizedFileURL.path
        if full.hasPrefix(root + "/") {
            return String(full.dropFirst(root.count + 1))
        }
        return full
    }
}
