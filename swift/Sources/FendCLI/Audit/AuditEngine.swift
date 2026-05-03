import Foundation
import FendCommon

enum AuditEngineError: Error, LocalizedError {
    case noLockfile(String)
    case lockfileUnsupported(String)
    case networkUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .noLockfile(let msg): return msg
        case .lockfileUnsupported(let msg): return msg
        case .networkUnavailable(let msg): return msg
        }
    }
}

enum AuditEngine {
    /// Run an audit for the given project. Applies policy and (when needed)
    /// prompts the user to approve findings. Returns a report the caller
    /// uses to pick a command (two-phase with rebuild vs skip).
    static func run(
        projectDir: URL,
        policy: AuditConfig,
        paths: FendPaths
    ) async throws -> AuditReport {
        if policy.level == .off {
            return AuditReport(totalPackages: 0, findings: [], decision: .skipped)
        }

        let packages: [LockedPackage]
        do {
            (packages, _) = try NPMLockfile.load(from: projectDir)
        } catch LockfileError.notFound {
            TerminalUI.warning("audit skipped", detail: "no package-lock.json")
            TerminalUI.hint("run `npm install --package-lock-only` first to enable auditing")
            return AuditReport(totalPackages: 0, findings: [], decision: .skipped)
        } catch LockfileError.unsupportedFormat(let m) {
            TerminalUI.warning("audit skipped", detail: m)
            return AuditReport(totalPackages: 0, findings: [], decision: .skipped)
        }

        if packages.isEmpty {
            return AuditReport(totalPackages: 0, findings: [], decision: .clean)
        }

        // Always run the batch query — it's one HTTP round trip regardless of
        // tree size, so it picks up newly-published advisories without a
        // --update-db dance. Detail fetches are cached per advisory ID.
        let cache = AuditCache(paths: paths)
        let results: [AdvisoryResult]
        TerminalUI.step("auditing dependencies", detail: "\(packages.count) packages via OSV.dev")
        let started = Date()
        do {
            results = try await OSVClient.query(packages: packages, cache: cache)
        } catch {
            TerminalUI.warning("audit unavailable", detail: TerminalUI.describe(error))
            TerminalUI.hint("continuing because audit policy is \(policy.level.rawValue)")
            if policy.level == .strict {
                throw AuditEngineError.networkUnavailable("audit required but OSV unreachable: \(error)")
            }
            return AuditReport(totalPackages: packages.count, findings: [], decision: .skipped)
        }
        let elapsed = Date().timeIntervalSince(started)

        let findings: [(LockedPackage, [Advisory])] = results.compactMap { r in
            guard !r.advisories.isEmpty else { return nil }
            return (LockedPackage(name: r.package, version: r.version), r.advisories)
        }

        if findings.isEmpty {
            return AuditReport(
                totalPackages: packages.count,
                findings: [],
                decision: .clean,
                elapsedSeconds: elapsed
            )
        }

        let decision = pickDecision(findings: findings, policy: policy)
        return AuditReport(
            totalPackages: packages.count,
            findings: findings,
            decision: decision,
            elapsedSeconds: elapsed
        )
    }

    private static func pickDecision(
        findings: [(LockedPackage, [Advisory])],
        policy: AuditConfig
    ) -> AuditDecision {
        if policy.level == .warn {
            return .approved
        }
        let worstInFindings = AuditReport(
            totalPackages: 0, findings: findings, decision: .approved
        ).worstSeverity
        if policy.block.contains(worstInFindings) {
            return .blocked
        }
        return .approved
    }

    /// Produce an AuditSummary (for the jsonl log) from a full report.
    static func summary(for report: AuditReport) -> AuditSummary {
        AuditSummary(
            totalPackages: report.totalPackages,
            findings: report.findings.count,
            bySeverity: report.bySeverity,
            decision: {
                switch report.decision {
                case .clean: return "clean"
                case .approved: return "approved"
                case .blocked: return "blocked"
                case .denied: return "denied"
                case .skipped: return "skipped"
                }
            }()
        )
    }
}
