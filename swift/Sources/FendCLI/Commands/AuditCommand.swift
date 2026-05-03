import ArgumentParser
import Foundation
import FendCommon

struct Audit: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "audit",
        abstract: "Audit the current project's package-lock.json against OSV.dev.",
        discussion: """
            Pure lookup by default. With --fix, computes and (optionally)
            applies an upgrade plan via `npm install` inside the sandbox.

            Flags mirror npm's muscle memory:
              --fix                 apply the safe portion of the plan
              --force               also apply major-version bumps
              --include-prerelease  consider RC / pre-release fix versions
              --dry-run             print the plan, touch nothing
              --yes                 skip prompts (CI-friendly)
              --json                emit structured output
              --update-db           re-query advisories (ignore cache)
            """
    )

    @Flag(name: .long, help: "Compute and apply an upgrade plan for the audit findings.")
    var fix: Bool = false

    @Flag(name: .long, help: "When applying fixes, also apply major-version bumps.")
    var force: Bool = false

    @Flag(name: .long, help: "Consider pre-release versions when picking fix targets.")
    var includePrerelease: Bool = false

    @Flag(name: .long, help: "Print the plan without applying it.")
    var dryRun: Bool = false

    @Flag(name: .shortAndLong, help: "Skip all prompts (use in CI).")
    var yes: Bool = false

    @Flag(name: .long, help: "Emit JSON instead of a human-readable report.")
    var json: Bool = false

    @Flag(name: .long, help: "Re-query advisories even if we have a fresh cache.")
    var updateDb: Bool = false

    func run() async throws {
        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = FendPaths()
        try paths.ensureDirectories()
        let config = FendConfig.load(from: projectDir)

        if updateDb {
            AuditCache(paths: paths).clear()
            TerminalUI.success("audit cache cleared")
        }

        // Audit always runs at "warn" here — we're just looking, not gating an
        // install. The install flow uses the user's real policy.
        let effectivePolicy = AuditConfig(
            level: .warn,
            rebuild: config.audit.rebuild,
            autoApproveInCI: config.audit.autoApproveInCI,
            block: config.audit.block,
            prompt: config.audit.prompt,
            fixOnInstall: config.audit.fixOnInstall,
            includePrerelease: includePrerelease || config.audit.includePrerelease
        )

        let report: AuditReport
        do {
            report = try await AuditEngine.run(
                projectDir: projectDir,
                policy: effectivePolicy,
                paths: paths
            )
        } catch {
            TerminalUI.error("audit failed", detail: TerminalUI.describe(error))
            throw ExitCode(1)
        }

        let plan = FixPlanner.compute(
            report: report,
            projectDir: projectDir,
            includePrerelease: effectivePolicy.includePrerelease,
            allowBreaking: force
        )

        if json {
            try emitJSON(report: report, plan: plan)
            return
        }

        AuditPrompt.printReport(report, plan: plan)

        if report.findings.isEmpty {
            return
        }

        // Non-fix invocation — we're done. Print a one-liner with next steps.
        if !fix {
            printNextSteps(plan: plan)
            return
        }

        // --fix path.
        if !plan.hasSafe {
            TerminalUI.blank()
            TerminalUI.warning("nothing to auto-fix")
            if !plan.breaking.isEmpty {
                TerminalUI.hint("\(plan.breaking.count) advisor\(plan.breaking.count == 1 ? "y requires" : "ies require") a major bump", detail: "re-run with --force")
            }
            if !plan.prerelease.isEmpty {
                TerminalUI.hint("\(plan.prerelease.count) advisor\(plan.prerelease.count == 1 ? "y is" : "ies are") only patched in a pre-release", detail: "re-run with --include-prerelease")
            }
            if !plan.noFix.isEmpty {
                TerminalUI.hint("\(plan.noFix.count) advisor\(plan.noFix.count == 1 ? "y has" : "ies have") no patched version")
            }
            throw ExitCode(1)
        }

        if dryRun {
            TerminalUI.blank()
            TerminalUI.info("dry run", detail: "no changes applied")
            return
        }

        if !yes && !AuditPrompt.askApplyPlan(plan) {
            TerminalUI.warning("fix cancelled")
            throw ExitCode(130)
        }

        try await applyPlan(plan, projectDir: projectDir, paths: paths, config: config)
    }

    private func printNextSteps(plan: FixPlan) {
        TerminalUI.blank()
        if plan.hasSafe {
            TerminalUI.hint("run `fend audit --fix`", detail: "apply \(plan.safeCount) safe fix(es)")
        }
        if !plan.breaking.isEmpty {
            TerminalUI.hint("run `fend audit --fix --force`", detail: "also apply \(plan.breaking.count) major bump(s)")
        }
        if !plan.prerelease.isEmpty {
            TerminalUI.hint("run `fend audit --fix --include-prerelease`", detail: "apply \(plan.prerelease.count) pre-release fix(es)")
        }
    }

    /// Actually apply the fix plan. Mutates package.json (for overrides),
    /// then invokes `fend npm install …` via the normal install flow, so the
    /// work happens in the sandbox and the audit/log paths all fire again on
    /// the resolved tree.
    private func applyPlan(
        _ plan: FixPlan,
        projectDir: URL,
        paths: FendPaths,
        config: FendConfig
    ) async throws {
        let overrideKeys = try FixApplier.writeOverrides(plan, projectDir: projectDir)
        if !overrideKeys.isEmpty {
            TerminalUI.success("package.json updated", detail: "\(overrideKeys.count) override(s)")
        }

        let installCmd = FixApplier.installArgv(for: plan)
        TerminalUI.step("applying fix", detail: "`\(installCmd.joined(separator: " "))`")
        TerminalUI.blank()

        try await Run.execute(command: installCmd, extraEnv: [:], claudeMode: false)
    }

    private func emitJSON(report: AuditReport, plan: FixPlan) throws {
        struct Output: Codable {
            struct Item: Codable {
                let name: String
                let from: String
                let to: String
                let severity: String
                let advisoryIds: [String]
            }
            let clean: Bool
            let totalPackages: Int
            let findings: Int
            let safe: [Item]
            let safeOverride: [Item]
            let breaking: [Item]
            let prerelease: [Item]
            let noFix: [String]
        }

        func convert(_ items: [FixItem]) -> [Output.Item] {
            items.map {
                Output.Item(
                    name: $0.package.name, from: $0.package.version,
                    to: $0.targetVersion, severity: $0.worstSeverity,
                    advisoryIds: $0.advisoryIds
                )
            }
        }

        let out = Output(
            clean: report.findings.isEmpty,
            totalPackages: report.totalPackages,
            findings: report.findings.count,
            safe: convert(plan.safeDirect),
            safeOverride: convert(plan.safeOverride),
            breaking: convert(plan.breaking),
            prerelease: convert(plan.prerelease),
            noFix: plan.noFix.map { $0.0.name }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(out)
        if let text = String(data: data, encoding: .utf8) {
            print(text)
        }
    }
}
