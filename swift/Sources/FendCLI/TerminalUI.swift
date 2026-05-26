import Foundation

enum TerminalUI {
    enum Stream {
        case stdout
        case stderr

        var fd: Int32 {
            switch self {
            case .stdout: return STDOUT_FILENO
            case .stderr: return STDERR_FILENO
            }
        }
    }

    enum StatusKind {
        case step
        case success
        case info
        case warning
        case error
        case hint
        case debug

        var label: String {
            switch self {
            case .step: return "run"
            case .success: return "ok"
            case .info: return "info"
            case .warning: return "warn"
            case .error: return "error"
            case .hint: return "hint"
            case .debug: return "debug"
            }
        }

        var color: ANSIColor {
            switch self {
            case .step: return .cyan
            case .success: return .green
            case .info: return .cyan
            case .warning: return .yellow
            case .error: return .red
            case .hint: return .dim
            case .debug: return .dim
            }
        }
    }

    enum ANSIColor {
        case bold
        case dim
        case red
        case green
        case yellow
        case cyan

        var code: String {
            switch self {
            case .bold: return "1"
            case .dim: return "2"
            case .red: return "31"
            case .green: return "32"
            case .yellow: return "33"
            case .cyan: return "36"
            }
        }
    }

    static func step(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        status(.step, message, detail: detail, stream: stream)
    }

    static func success(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        status(.success, message, detail: detail, stream: stream)
    }

    static func info(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        status(.info, message, detail: detail, stream: stream)
    }

    static func warning(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        status(.warning, message, detail: detail, stream: stream)
    }

    static func error(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        status(.error, message, detail: detail, stream: stream)
    }

    static func hint(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        status(.hint, message, detail: detail, stream: stream)
    }

    static func debug(_ message: String, detail: String? = nil, stream: Stream = .stderr) {
        guard isVerbose else { return }
        status(.debug, message, detail: detail, stream: stream)
    }

    static func blank(_ stream: Stream = .stderr) {
        writeLine("", stream: stream)
    }

    static func line(_ message: String, stream: Stream = .stderr) {
        guard !isQuiet || stream == .stdout else { return }
        writeLine(message, stream: stream)
    }

    static func status(
        _ kind: StatusKind,
        _ message: String,
        detail: String? = nil,
        stream: Stream = .stderr
    ) {
        if isQuiet, kind != .error, kind != .warning {
            return
        }
        if kind == .debug, !isVerbose {
            return
        }
        let text = renderStatus(
            kind,
            message,
            detail: detail,
            colorEnabled: shouldUseColor(stream: stream)
        )
        writeLine(text, stream: stream)
    }

    static func section(_ title: String, stream: Stream = .stdout) {
        let text = style(title, .bold, enabled: shouldUseColor(stream: stream))
        writeLine(text, stream: stream)
    }

    static func fields(_ rows: [(String, String)], stream: Stream = .stdout) {
        guard !rows.isEmpty else { return }
        let width = min(max(rows.map { $0.0.count }.max() ?? 0, 1), 18)
        let color = shouldUseColor(stream: stream)
        for (key, value) in rows {
            let label = style(key.padding(toLength: width, withPad: " ", startingAt: 0), .dim, enabled: color)
            writeLine("  \(label)  \(value)", stream: stream)
        }
    }

    static func table(headers: [String], rows: [[String]], stream: Stream = .stdout) {
        guard !headers.isEmpty else { return }
        let normalizedRows = rows.map { row in
            row.count >= headers.count
                ? Array(row.prefix(headers.count))
                : row + Array(repeating: "", count: headers.count - row.count)
        }
        let widths = headers.enumerated().map { index, header in
            let values = normalizedRows.map { $0[index].count }
            return min(max(values.max() ?? 0, header.count), 36)
        }
        let color = shouldUseColor(stream: stream)

        let headerLine = zip(headers, widths)
            .map { pad($0.0, width: $0.1) }
            .joined(separator: "  ")
        writeLine(style(headerLine, .dim, enabled: color), stream: stream)

        for row in normalizedRows {
            let line = row.enumerated()
                .map { index, value in pad(value, width: widths[index]) }
                .joined(separator: "  ")
            writeLine(line, stream: stream)
        }
    }

    static func renderStatus(
        _ kind: StatusKind,
        _ message: String,
        detail: String? = nil,
        colorEnabled: Bool
    ) -> String {
        let label = style(
            kind.label.padding(toLength: 5, withPad: " ", startingAt: 0),
            kind.color,
            enabled: colorEnabled
        )
        let suffix = detail.map { "  \(style($0, .dim, enabled: colorEnabled))" } ?? ""
        return "\(label) \(message)\(suffix)"
    }

    /// Flutter-doctor-style section: bracketed status, title bolded, then
    /// indented fields (each with its own per-row [✓]/[!]/[✗] when set),
    /// then any explanatory notes.
    static func renderDoctorSection(_ section: DoctorSection) {
        let color = shouldUseColor(stream: .stdout)
        let bracket = style(section.status.bracket, section.status.color, enabled: color)
        let title = style(section.title, .bold, enabled: color)
        writeLine("\(bracket) \(title)", stream: .stdout)

        let labelWidth = section.fields
            .map { $0.label.count }
            .max() ?? 0
        let width = min(max(labelWidth, 1), 18)

        for field in section.fields {
            let labelPadded = field.label.padding(toLength: width, withPad: " ", startingAt: 0)
            let labelStyled = style(labelPadded, .dim, enabled: color)
            if let status = field.status {
                let rowBracket = style(status.bracket, status.color, enabled: color)
                writeLine("    \(rowBracket) \(labelStyled)  \(field.value)", stream: .stdout)
            } else {
                writeLine("        \(labelStyled)  \(field.value)", stream: .stdout)
            }
        }

        for note in section.notes {
            writeLine("    \(style(note, .dim, enabled: color))", stream: .stdout)
        }
    }

    static func style(_ text: String, _ color: ANSIColor, enabled: Bool) -> String {
        guard enabled else { return text }
        return "\u{001B}[\(color.code)m\(text)\u{001B}[0m"
    }

    static func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        let nsError = error as NSError
        if let reason = nsError.localizedFailureReason, !reason.isEmpty {
            return reason
        }
        return nsError.localizedDescription
    }

    static var isVerbose: Bool {
        let env = ProcessInfo.processInfo.environment
        return truthy(env["FEND_VERBOSE"]) || truthy(env["DEBUG"])
    }

    static var isQuiet: Bool {
        truthy(ProcessInfo.processInfo.environment["FEND_QUIET"])
    }

    static func shouldUseColor(stream: Stream) -> Bool {
        let env = ProcessInfo.processInfo.environment
        if truthy(env["FEND_FORCE_COLOR"]) || truthy(env["FORCE_COLOR"]) || truthy(env["CLICOLOR_FORCE"]) {
            return true
        }
        if hasNonEmpty(env["FEND_NO_COLOR"]) || hasNonEmpty(env["NO_COLOR"]) {
            return false
        }
        if env["TERM"] == "dumb" {
            return false
        }
        return isatty(stream.fd) != 0
    }

    private static func writeLine(_ message: String, stream: Stream) {
        switch stream {
        case .stderr:
            writeStatusLine(message)
        case .stdout:
            fputs(message + "\n", stdout)
        }
    }

    private static func pad(_ value: String, width: Int) -> String {
        if value.count <= width {
            return value.padding(toLength: width, withPad: " ", startingAt: 0)
        }
        guard width > 1 else { return String(value.prefix(width)) }
        return String(value.prefix(width - 1)) + "…"
    }

    private static func truthy(_ value: String?) -> Bool {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !raw.isEmpty else {
            return false
        }
        return raw != "0" && raw != "false" && raw != "no" && raw != "off"
    }

    private static func hasNonEmpty(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.isEmpty
    }
}
