import Foundation

/// Controls how `fend` handles install-time dependency auditing.
public struct AuditConfig {
    public let level: AuditLevel
    /// When true, after `npm install --ignore-scripts` succeeds, run
    /// `npm rebuild` automatically so postinstall scripts execute for the
    /// audited tree. Default true — matches users' expectation that
    /// `fend npm install` leaves a working node_modules.
    public let rebuild: Bool
    /// When `$CI` is set and this is true, skip the interactive prompt and
    /// auto-approve everything below the block level. For unattended runs.
    public let autoApproveInCI: Bool
    /// Severities that are blocked outright, no prompt.
    public let block: [String]
    /// Severities that require an interactive y/N prompt.
    public let prompt: [String]
    /// When true, `fend npm install` offers to apply safe fixes before running
    /// the install. Default true — the prompt is still an explicit step, and
    /// users strongly prefer a clear "want to fix?" over finding out later.
    public let fixOnInstall: Bool
    /// When true, audit-fix considers pre-release versions (`1.2.3-rc.1`) as
    /// candidate fixes. Off by default; most projects don't want RCs silently
    /// substituted.
    public let includePrerelease: Bool

    public init(
        level: AuditLevel = .strict,
        rebuild: Bool = true,
        autoApproveInCI: Bool = false,
        block: [String] = ["malware", "critical"],
        prompt: [String] = ["high"],
        fixOnInstall: Bool = true,
        includePrerelease: Bool = false
    ) {
        self.level = level
        self.rebuild = rebuild
        self.autoApproveInCI = autoApproveInCI
        self.block = block
        self.prompt = prompt
        self.fixOnInstall = fixOnInstall
        self.includePrerelease = includePrerelease
    }
}

public enum AuditLevel: String {
    /// Always audit install commands; prompt/block as policy dictates.
    case strict
    /// Show findings but never block.
    case warn
    /// Never audit. Install runs as if fend weren't wrapping it.
    case off

    public static func parse(_ raw: String?) -> AuditLevel? {
        guard let raw = raw?.lowercased() else { return nil }
        return AuditLevel(rawValue: raw)
    }
}
