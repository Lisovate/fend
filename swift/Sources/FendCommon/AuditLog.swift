import Foundation

/// One line in `~/.fend/audit.jsonl`. Structured record of a single `fend`
/// invocation — command, project, duration, exit, and (optionally) the
/// audit decision and network activity captured during the run.
public struct AuditEntry: Codable {
    public var timestamp: String
    public var project: String
    public var cmd: String
    public var args: [String]
    public var envKeys: [String]
    public var durationMs: Int
    public var exitCode: Int32
    public var audit: AuditSummary?
    public var network: [String]?
    public var networkMode: String?
    public var networkEvents: [NetworkEvent]?
    public var watchMode: String?
    public var fsDiff: FsDiffSummary?

    public init(
        timestamp: String,
        project: String,
        cmd: String,
        args: [String],
        envKeys: [String],
        durationMs: Int,
        exitCode: Int32,
        audit: AuditSummary? = nil,
        network: [String]? = nil,
        networkMode: String? = nil,
        networkEvents: [NetworkEvent]? = nil,
        watchMode: String? = nil,
        fsDiff: FsDiffSummary? = nil
    ) {
        self.timestamp = timestamp
        self.project = project
        self.cmd = cmd
        self.args = args
        self.envKeys = envKeys
        self.durationMs = durationMs
        self.exitCode = exitCode
        self.audit = audit
        self.network = network
        self.networkMode = networkMode
        self.networkEvents = networkEvents
        self.watchMode = watchMode
        self.fsDiff = fsDiff
    }
}

/// Summary of audit findings for an install command. Detailed advisories live
/// in the audit cache; this is just enough for `fend log` to show a count.
public struct AuditSummary: Codable {
    public var totalPackages: Int
    public var findings: Int
    public var bySeverity: [String: Int]
    public var decision: String // "clean" | "approved" | "blocked" | "denied" | "skipped"

    public init(totalPackages: Int, findings: Int, bySeverity: [String: Int], decision: String) {
        self.totalPackages = totalPackages
        self.findings = findings
        self.bySeverity = bySeverity
        self.decision = decision
    }
}

/// Summary of project tree changes between pre/post install.
public struct FsDiffSummary: Codable {
    public var outsideNodeModules: Int
    public var touchedFiles: [String]
    public var risk: String?
    public var sensitiveFiles: [String]?

    public init(
        outsideNodeModules: Int,
        touchedFiles: [String],
        risk: String? = nil,
        sensitiveFiles: [String]? = nil
    ) {
        self.outsideNodeModules = outsideNodeModules
        self.touchedFiles = touchedFiles
        self.risk = risk
        self.sensitiveFiles = sensitiveFiles
    }
}

public enum AuditLog {
    /// Append a single entry to `~/.fend/audit.jsonl`. Best-effort: silently
    /// swallows IO errors so logging failures never affect the user's command.
    public static func append(_ entry: AuditEntry, paths: FendPaths = FendPaths()) {
        guard let data = try? JSONEncoder.jsonl.encode(entry) else { return }
        var line = data
        line.append(0x0A) // newline

        let url = paths.auditLogPath
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: line)
        } else {
            // File doesn't exist yet — create it with the first line.
            try? line.write(to: url, options: .atomic)
        }
    }

    /// Stream entries from the audit log, newest last. Each callback gets the
    /// decoded entry or nil if the line couldn't be parsed.
    public static func read(paths: FendPaths = FendPaths()) -> [AuditEntry] {
        guard let data = try? Data(contentsOf: paths.auditLogPath),
              let content = String(data: data, encoding: .utf8) else {
            return []
        }
        var entries: [AuditEntry] = []
        for line in content.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if let entry = try? JSONDecoder().decode(AuditEntry.self, from: Data(trimmed.utf8)) {
                entries.append(entry)
            }
        }
        return entries
    }

    /// Current UTC timestamp in ISO-8601 format.
    public static func now() -> String {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.string(from: Date())
    }
}

extension JSONEncoder {
    fileprivate static let jsonl: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        return e
    }()
}
