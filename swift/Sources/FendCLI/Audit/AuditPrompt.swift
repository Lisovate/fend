import Foundation

enum AuditDecision {
    case clean          // no findings
    case approved       // findings, user approved (or CI auto-approved)
    case blocked        // findings at or above block severity
    case denied         // user pressed N at prompt
    case skipped        // audit.level = off, or no lockfile found
}

struct AuditReport {
    let totalPackages: Int
    let findings: [(LockedPackage, [Advisory])]
    let decision: AuditDecision
    /// Wall-clock time the network audit took. Propagates from AuditEngine.run
    /// so the printer can say "(1.1s)" without passing it separately.
    let elapsedSeconds: Double

    init(
        totalPackages: Int,
        findings: [(LockedPackage, [Advisory])],
        decision: AuditDecision,
        elapsedSeconds: Double = 0
    ) {
        self.totalPackages = totalPackages
        self.findings = findings
        self.decision = decision
        self.elapsedSeconds = elapsedSeconds
    }

    var bySeverity: [String: Int] {
        var counts: [String: Int] = [:]
        for (_, advisories) in findings {
            for a in advisories {
                counts[a.severity, default: 0] += 1
            }
        }
        return counts
    }

    var worstSeverity: String {
        let order = ["malware", "critical", "high", "medium", "low", "unknown"]
        for sev in order {
            if bySeverity[sev, default: 0] > 0 { return sev }
        }
        return "unknown"
    }
}

/// User-facing prompt to approve/reject findings. Writes to stderr so stdout
/// stays clean for scripting. Reads a single line from /dev/tty (not stdin)
/// so piped input doesn't force a decision.
enum AuditPrompt {
    /// Read a single y/N answer from /dev/tty. Default is N (empty/Enter = no).
    static func readYN() -> Bool {
        guard let tty = fopen("/dev/tty", "r") else {
            TerminalUI.blank()
            TerminalUI.warning("no tty available", detail: "denying by default")
            return false
        }
        defer { fclose(tty) }

        var buffer = [CChar](repeating: 0, count: 16)
        guard fgets(&buffer, Int32(buffer.count), tty) != nil else {
            fputs("\n", stderr)
            return false
        }
        let answer = String(cString: buffer)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Unified report — one block per package, advisories nested under a
    /// header that carries the fix (or the reason there isn't one). Replaces
    /// the old `printFindings` + `printFixPlan` pair so every surface shows
    /// the same layout.
    static func printReport(_ report: AuditReport, plan: FixPlan) {
        if report.findings.isEmpty {
            let time = report.elapsedSeconds > 0
                ? String(format: " (%.1fs)", report.elapsedSeconds) : ""
            TerminalUI.success("audit clean", detail: "\(report.totalPackages) packages\(time)")
            return
        }

        let advisoryCount = report.findings.reduce(0) { $0 + $1.1.count }
        let worst = report.worstSeverity.uppercased()
        let time = report.elapsedSeconds > 0 ? String(format: "%.1fs", report.elapsedSeconds) : "-"
        let advWord = advisoryCount == 1 ? "advisory" : "advisories"
        let pkgWord = report.findings.count == 1 ? "package" : "packages"
        TerminalUI.warning("\(advisoryCount) \(advWord) found", detail: "worst \(worst)")
        TerminalUI.fields([
            ("packages", "\(report.findings.count) of \(report.totalPackages) \(pkgWord)"),
            ("duration", time),
        ], stream: .stderr)
        TerminalUI.blank()

        let classes = classify(plan: plan)

        // Sort: worst severity first, then alphabetical — mirrors npm audit.
        let sorted = report.findings.sorted { lhs, rhs in
            let lOrder = severityOrder(FixPlanner.worstSeverity(lhs.1))
            let rOrder = severityOrder(FixPlanner.worstSeverity(rhs.1))
            if lOrder != rOrder { return lOrder < rOrder }
            return lhs.0.name < rhs.0.name
        }

        let rows = sorted.map { item in
            let pkg = item.0
            let advisories = item.1
            let cls = classes[pkg.name] ?? .noFix
            let ids = advisories
                .sorted { severityOrder($0.severity) < severityOrder($1.severity) }
                .prefix(3)
                .map(\.id)
                .joined(separator: ",")
            let suffix = advisories.count > 3 ? ",+\(advisories.count - 3)" : ""
            return [
                pkg.name,
                pkg.version,
                fixText(for: cls),
                FixPlanner.worstSeverity(advisories).uppercased(),
                ids + suffix,
            ]
        }
        TerminalUI.table(
            headers: ["Package", "Current", "Fix", "Worst", "Advisories"],
            rows: rows,
            stream: .stderr
        )

        let topAdvisories = sorted.flatMap { item in
            let pkg = item.0
            let advisories = item.1
            return advisories
                .sorted { severityOrder($0.severity) < severityOrder($1.severity) }
                .prefix(2)
                .map { (pkg.name, $0) }
        }
        if !topAdvisories.isEmpty {
            TerminalUI.blank()
            for (package, advisory) in topAdvisories.prefix(8) {
                let summary = String(advisory.summary.prefix(80))
                TerminalUI.line(
                    "  \(advisory.severity.uppercased()) \(package): \(summary) [\(advisory.id)]",
                    stream: .stderr
                )
            }
            if topAdvisories.count > 8 {
                TerminalUI.hint("showing 8 advisory summaries", detail: "use `fend audit --json` for full data")
            }
        }

        var parts: [String] = []
        if plan.safeCount > 0 { parts.append("\(plan.safeCount) auto-fixable") }
        if !plan.breaking.isEmpty {
            parts.append("\(plan.breaking.count) major bump\(plan.breaking.count == 1 ? "" : "s") (--force)")
        }
        if !plan.prerelease.isEmpty {
            parts.append("\(plan.prerelease.count) pre-release only (--include-prerelease)")
        }
        if !plan.noFix.isEmpty {
            parts.append("\(plan.noFix.count) unfixable")
        }
        if !parts.isEmpty {
            TerminalUI.blank()
            TerminalUI.info("fix plan", detail: parts.joined(separator: ", "))
        }
    }

    private enum PackageClass {
        case direct(target: String)
        case overrideEntry(target: String)
        case breaking(target: String)
        case prerelease(target: String)
        case noFix
    }

    private static func classify(plan: FixPlan) -> [String: PackageClass] {
        var m: [String: PackageClass] = [:]
        for i in plan.safeDirect { m[i.package.name] = .direct(target: i.targetVersion) }
        for i in plan.safeOverride { m[i.package.name] = .overrideEntry(target: i.targetVersion) }
        for i in plan.breaking { m[i.package.name] = .breaking(target: i.targetVersion) }
        for i in plan.prerelease { m[i.package.name] = .prerelease(target: i.targetVersion) }
        for (p, _) in plan.noFix { m[p.name] = .noFix }
        return m
    }

    private static func fixText(for cls: PackageClass) -> String {
        switch cls {
        case .direct(let t):
            return "\(t) direct"
        case .overrideEntry(let t):
            return "\(t) override"
        case .breaking(let t):
            return "\(t) needs --force"
        case .prerelease(let t):
            return "\(t) prerelease"
        case .noFix:
            return "no patched version"
        }
    }

    private static func severityOrder(_ s: String) -> Int {
        switch s {
        case "malware": return 0
        case "critical": return 1
        case "high": return 2
        case "medium": return 3
        case "low": return 4
        default: return 5
        }
    }
}

// MARK: - Fix prompts

extension AuditPrompt {
    /// Ask the user whether to apply the safe portion of a plan. Breaking /
    /// prerelease items are surfaced in the plan output but require explicit
    /// flags — no per-class prompt chain, which mirrors npm/bun behavior.
    /// Returns true on y/Y/yes or Enter (default yes — it's a safety win).
    static func askApplyPlan(_ plan: FixPlan) -> Bool {
        let count = plan.safeCount
        let word = count == 1 ? "fix" : "fixes"
        TerminalUI.blank()
        fputs("Apply \(count) \(word)? [Y/n] ", stderr)

        guard let tty = fopen("/dev/tty", "r") else {
            TerminalUI.blank()
            TerminalUI.warning("no tty available", detail: "declining by default")
            return false
        }
        defer { fclose(tty) }

        var buf = [CChar](repeating: 0, count: 16)
        guard fgets(&buf, Int32(buf.count), tty) != nil else {
            fputs("\n", stderr)
            return false
        }
        let ans = String(cString: buf)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // Empty (Enter) defaults to yes — consistent with [Y/n] convention.
        return ans.isEmpty || ans == "y" || ans == "yes"
    }

    /// Install-flow variant: after the audit has findings AND we have a fix
    /// plan, ask the user whether to apply the fixes first (and then proceed
    /// with their original install), skip the fix and continue with the
    /// original install anyway, or cancel entirely.
    /// Returns `.apply`, `.skip`, or `.cancel`.
    static func askFixBeforeInstall(plan: FixPlan) -> FixInstallChoice {
        let count = plan.safeCount
        let word = count == 1 ? "fix" : "fixes"
        TerminalUI.blank()
        fputs("Apply \(count) \(word) before installing? [Y/n/c (cancel)] ", stderr)

        guard let tty = fopen("/dev/tty", "r") else {
            return .skip
        }
        defer { fclose(tty) }

        var buf = [CChar](repeating: 0, count: 16)
        guard fgets(&buf, Int32(buf.count), tty) != nil else {
            return .skip
        }
        let ans = String(cString: buf)
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch ans {
        case "", "y", "yes": return .apply
        case "c", "cancel": return .cancel
        default: return .skip
        }
    }
}

enum FixInstallChoice {
    case apply
    case skip
    case cancel
}
