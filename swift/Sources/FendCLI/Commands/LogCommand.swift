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

    @Flag(name: .long, help: "Emit one JSON object per line (raw log).")
    var json: Bool = false

    func run() throws {
        let paths = FendPaths()
        var entries = AuditLog.read(paths: paths)

        if let project = project {
            entries = entries.filter { $0.project.contains(project) }
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
            print("fend: no entries")
            return
        }

        print("TIMESTAMP                 PROJECT                   CMD              DURATION  EXIT  AUDIT")
        for e in entries {
            let ts = e.timestamp.replacingOccurrences(of: "T", with: " ").prefix(19)
            let proj = URL(fileURLWithPath: e.project).lastPathComponent
            let cmd = ([e.cmd] + e.args.prefix(2)).joined(separator: " ")
            let dur = "\(e.durationMs)ms"
            let exit = "\(e.exitCode)"
            let audit = e.audit.map { "\($0.decision)(\($0.findings))" } ?? "-"
            print("\(ts.padding(toLength: 25, withPad: " ", startingAt: 0)) \(proj.padding(toLength: 25, withPad: " ", startingAt: 0)) \(cmd.padding(toLength: 16, withPad: " ", startingAt: 0)) \(dur.padding(toLength: 9, withPad: " ", startingAt: 0)) \(exit.padding(toLength: 5, withPad: " ", startingAt: 0)) \(audit)")
        }
    }
}
