import ArgumentParser
import Foundation
import FendCommon

struct Log: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Show the fend activity log (~/.fend/audit.jsonl)."
    )

    @Option(name: .long, help: "Filter by project path substring.")
    var project: String?

    @Option(name: .long, help: "Show entries from the last N minutes.")
    var since: Int?

    @Option(name: .long, help: "Show at most N most recent entries.")
    var tail: Int = 50

    @Option(name: .long, help: "Filter by network mode: on or off.")
    var network: String?

    @Option(name: .long, help: "Filter by filesystem risk: low, medium, high, or unknown.")
    var fsRisk: String?

    @Option(name: .long, help: "Filter by audit decision, e.g. clean, approved, blocked, denied, skipped.")
    var auditDecision: String?

    @Flag(name: .long, help: "Only show commands with non-zero exit codes.")
    var failed: Bool = false

    @Flag(name: .long, help: "Only show commands with observed outbound network events.")
    var networkEvents: Bool = false

    @Flag(name: .long, help: "Emit one JSON object per line (raw log).")
    var json: Bool = false

    func run() throws {
        let paths = FendPaths()
        var entries = AuditLog.read(paths: paths)

        let networkFilter = try parseNetworkFilter(network)
        let fsRiskFilter = try parseFsRiskFilter(fsRisk)
        let auditDecisionFilter = try parseAuditDecisionFilter(auditDecision)

        if let project = project {
            entries = entries.filter { $0.project.contains(project) }
        }

        if let networkFilter {
            entries = entries.filter { $0.networkMode == networkFilter.rawValue }
        }

        if let fsRiskFilter {
            entries = entries.filter { ($0.fsDiff?.risk ?? "unknown").lowercased() == fsRiskFilter }
        }

        if let auditDecisionFilter {
            entries = entries.filter { ($0.audit?.decision ?? "-").lowercased() == auditDecisionFilter }
        }

        if failed {
            entries = entries.filter { $0.exitCode != 0 }
        }

        if networkEvents {
            entries = entries.filter { ($0.networkEvents?.isEmpty == false) }
        }

        if let minutes = since {
            let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            entries = entries.filter {
                guard let ts = iso.date(from: $0.timestamp) else { return true }
                return ts >= cutoff
            }
        }

        if entries.count > tail {
            entries = Array(entries.suffix(tail))
        }

        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
            for e in entries {
                if let data = try? encoder.encode(e),
                   let line = String(data: data, encoding: .utf8) {
                    print(line)
                }
            }
            return
        }

        if entries.isEmpty {
            TerminalUI.info("no log entries", stream: .stdout)
            return
        }

        let rows = entries.map { e in
            let ts = e.timestamp.replacingOccurrences(of: "T", with: " ").prefix(19)
            let proj = URL(fileURLWithPath: e.project).lastPathComponent
            let cmd = ([e.cmd] + e.args.prefix(2)).joined(separator: " ")
            let dur = "\(e.durationMs)ms"
            let exit = "\(e.exitCode)"
            let networkCount = e.networkEvents?.count ?? 0
            let net = networkCount > 0
                ? "\((e.networkMode ?? "-"))+\(networkCount)"
                : (e.networkMode ?? "-")
            let audit = e.audit.map { "\($0.decision)(\($0.findings))" } ?? "-"
            let watch = e.watchMode ?? "-"
            let fs = e.fsDiff.flatMap { diff in
                guard !diff.touchedFiles.isEmpty else { return nil }
                return "\(diff.risk ?? "unknown")(\(diff.touchedFiles.count))"
            } ?? "-"
            return [String(ts), proj, cmd, dur, exit, net, watch, audit, fs]
        }
        TerminalUI.table(
            headers: ["Timestamp", "Project", "Cmd", "Duration", "Exit", "Net", "Watch", "Audit", "FS"],
            rows: rows
        )
    }

    private func parseNetworkFilter(_ raw: String?) throws -> NetworkMode? {
        guard let raw else { return nil }
        guard let mode = NetworkMode.parse(raw) else {
            throw ValidationError("--network must be 'on' or 'off'")
        }
        return mode
    }

    private func parseFsRiskFilter(_ raw: String?) throws -> String? {
        guard let value = raw?.lowercased() else { return nil }
        guard ["low", "medium", "high", "unknown"].contains(value) else {
            throw ValidationError("--fs-risk must be 'low', 'medium', 'high', or 'unknown'")
        }
        return value
    }

    private func parseAuditDecisionFilter(_ raw: String?) throws -> String? {
        guard let value = raw?.lowercased() else { return nil }
        guard ["clean", "approved", "blocked", "denied", "skipped"].contains(value) else {
            throw ValidationError("--audit-decision must be 'clean', 'approved', 'blocked', 'denied', or 'skipped'")
        }
        return value
    }
}
