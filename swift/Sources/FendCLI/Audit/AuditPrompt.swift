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
            fputs("\nfend: no tty available — denying by default\n", stderr)
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
            fputs("fend audit: \(report.totalPackages) packages clean\(time)\n", stderr)
            return
        }

        let advisoryCount = report.findings.reduce(0) { $0 + $1.1.count }
        let worst = report.worstSeverity.uppercased()
        let time = report.elapsedSeconds > 0
            ? String(format: "%.1fs, ", report.elapsedSeconds) : ""
        let advWord = advisoryCount == 1 ? "advisory" : "advisories"
        let pkgWord = report.findings.count == 1 ? "package" : "packages"
        fputs(
            "fend audit: \(advisoryCount) \(advWord) in \(report.findings.count) of \(report.totalPackages) \(pkgWord) (\(time)worst \(worst))\n\n",
            stderr
        )

        let classes = classify(plan: plan)

        // Sort: worst severity first, then alphabetical — mirrors npm audit.
        let sorted = report.findings.sorted { lhs, rhs in
            let lOrder = severityOrder(FixPlanner.worstSeverity(lhs.1))
            let rOrder = severityOrder(FixPlanner.worstSeverity(rhs.1))
            if lOrder != rOrder { return lOrder < rOrder }
            return lhs.0.name < rhs.0.name
        }

        for (pkg, advisories) in sorted {
            let cls = classes[pkg.name] ?? .noFix
            fputs("  \(formatHeader(pkg: pkg, cls: cls))\n", stderr)
            let advSorted = advisories.sorted {
                severityOrder($0.severity) < severityOrder($1.severity)
            }
            for adv in advSorted {
                let sev = adv.severity.uppercased()
                    .padding(toLength: 7, withPad: " ", startingAt: 0)
                let summary = String(adv.summary.prefix(58))
                let padded = summary.padding(toLength: 58, withPad: " ", startingAt: 0)
                fputs("    \(sev) \(padded) [\(adv.id)]\n", stderr)
            }
            fputs("\n", stderr)
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
            fputs("Summary: \(parts.joined(separator: ", ")).\n", stderr)
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

    private static func formatHeader(pkg: LockedPackage, cls: PackageClass) -> String {
        switch cls {
        case .direct(let t):
            return "\(pkg.name) \(pkg.version) → \(t)  [direct]"
        case .overrideEntry(let t):
            return "\(pkg.name) \(pkg.version) → \(t)  [override]"
        case .breaking(let t):
            return "\(pkg.name) \(pkg.version) → \(t)  [BREAKING — needs --force]"
        case .prerelease(let t):
            return "\(pkg.name) \(pkg.version) → \(t)  [pre-release — needs --include-prerelease]"
        case .noFix:
            return "\(pkg.name) \(pkg.version)  [no patched version]"
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
        fputs("\nApply \(count) \(word)? [Y/n] ", stderr)

        guard let tty = fopen("/dev/tty", "r") else {
            fputs("\nfend: no tty — declining by default\n", stderr)
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
        fputs("\nApply \(count) \(word) before installing? [Y/n/c (cancel)] ", stderr)

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
