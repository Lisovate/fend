import ArgumentParser
import Foundation
import FendCommon
import FendDaemon

struct Run: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a command in the sandbox (default subcommand)",
        discussion: "When invoked as `fend npm install`, ArgumentParser routes to this subcommand."
    )

    @Option(name: .shortAndLong, parsing: .singleValue,
            help: "Additional env var to inject (KEY=VALUE). Repeatable.")
    var env: [String] = []

    @Option(name: .long, parsing: .singleValue,
            help: "Load env vars from a .env-style file. Repeatable; later files win on conflict.")
    var envFile: [String] = []

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run in the sandbox")
    var command: [String] = []

    func run() async throws {
        guard !command.isEmpty else {
            throw ValidationError("No command specified. Usage: fend <command> [args...]")
        }
        let extra = try parseExtraEnv(pairs: env, files: envFile)
        try await Run.execute(command: command, extraEnv: extra, claudeMode: false)
    }

    /// Execute a command in the sandbox. Shared by `fend <cmd>` and `fend claude <cmd>`.
    static func execute(command: [String], extraEnv: [String: String], claudeMode: Bool) async throws {
        // Bail out early on obvious argparse mistakes (e.g. `fend --update-db`
        // where the user meant `fend audit --update-db`). Without this we'd
        // boot a VM just to have fendd fail with ENOENT on `--update-db`.
        if let first = command.first, first.hasPrefix("-"), first != "-" {
            fputs("fend: '\(first)' looks like a flag, not a command.\n", stderr)
            fputs("      Top-level flags go before the subcommand; use `fend <subcommand> \(first)`.\n", stderr)
            fputs("      Run `fend --help` to see available subcommands.\n", stderr)
            throw ExitCode(2)
        }

        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = FendPaths()
        try paths.ensureDirectories()
        let config = FendConfig.load(from: projectDir)

        // Install-intent detection + audit. Must happen BEFORE enableRawMode()
        // so the interactive prompt reads a normal line from the tty.
        var finalCommand = command
        var auditSummary: AuditSummary?
        let detectedIntent = InstallIntent.detect(command)
        let diffStart: Date? = detectedIntent != nil ? FsDiff.snapshotStart() : nil

        if let intent = detectedIntent, intent.supportsAudit {
            // 1. Raw audit — no prompts, no policy applied yet.
            let rawReport = try await AuditEngine.run(
                projectDir: projectDir,
                policy: config.audit,
                paths: paths
            )

            // 2. Print unified report once (summary + per-package blocks).
            //    If we can auto-fix, offer it — answering yes merges the fix
            //    pins into the install args and skips the policy prompt
            //    (the user already approved via this prompt).
            var fixApplied = false
            if !rawReport.findings.isEmpty {
                let plan = FixPlanner.compute(
                    report: rawReport,
                    projectDir: projectDir,
                    includePrerelease: config.audit.includePrerelease,
                    allowBreaking: false
                )
                AuditPrompt.printReport(rawReport, plan: plan)

                if config.audit.fixOnInstall && plan.hasSafe {
                    switch AuditPrompt.askFixBeforeInstall(plan: plan) {
                    case .apply:
                        try FixApplier.writeOverrides(plan, projectDir: projectDir)
                        // Merge user's original install args with the direct-dep
                        // fix pins. Overrides are already in package.json, so a
                        // plain `npm install` would pick them up — the explicit
                        // pins ensure direct deps jump to the fixed version even
                        // if their caret range doesn't already allow it.
                        let pins = plan.safeDirect.map {
                            "\($0.package.name)@\($0.targetVersion)"
                        }
                        let merged = InstallIntent(
                            packageManager: intent.packageManager,
                            subcommand: intent.subcommand,
                            packagesGiven: intent.packagesGiven + pins,
                            extraFlags: intent.extraFlags
                        )
                        finalCommand = merged.twoPhaseCommand(rebuild: config.audit.rebuild)
                        fputs("fend: applying fixes and running install…\n\n", stderr)
                        fixApplied = true
                    case .skip:
                        break // fall through to policy prompt
                    case .cancel:
                        fputs("fend: install cancelled.\n", stderr)
                        Foundation.exit(130)
                    }
                }
            }

            // 3. If we didn't auto-fix, apply the audit policy (block / prompt /
            //    approve). When we did auto-fix, the user's consent there
            //    already covered the install, so we skip this step.
            if !fixApplied {
                let report = applyAuditPolicy(
                    to: rawReport,
                    policy: config.audit,
                    alreadyPrintedFindings: !rawReport.findings.isEmpty
                )
                auditSummary = AuditEngine.summary(for: report)

                switch report.decision {
                case .blocked:
                    fputs("fend: aborting — policy=\(config.audit.level.rawValue) blocks severity \(report.worstSeverity).\n", stderr)
                    AuditLog.append(AuditEntry(
                        timestamp: AuditLog.now(),
                        project: projectDir.path,
                        cmd: command[0],
                        args: Array(command.dropFirst()),
                        envKeys: [],
                        durationMs: 0,
                        exitCode: 2,
                        audit: auditSummary
                    ), paths: paths)
                    Foundation.exit(2)
                case .denied:
                    fputs("fend: install cancelled.\n", stderr)
                    AuditLog.append(AuditEntry(
                        timestamp: AuditLog.now(),
                        project: projectDir.path,
                        cmd: command[0],
                        args: Array(command.dropFirst()),
                        envKeys: [],
                        durationMs: 0,
                        exitCode: 130,
                        audit: auditSummary
                    ), paths: paths)
                    Foundation.exit(130)
                case .clean, .approved:
                    finalCommand = intent.twoPhaseCommand(rebuild: config.audit.rebuild)
                case .skipped:
                    // No lockfile or audit disabled — pass through untouched.
                    break
                }
            } else {
                auditSummary = AuditEngine.summary(for: rawReport)
            }
        }

        let isTTY = isatty(STDIN_FILENO) != 0
        SignalState.shared.ttyMode = isTTY

        // Tight env passthrough allowlist. Explicitly excludes ANTHROPIC_*, CLAUDE_*,
        // HTTP(S)_PROXY, AWS_*, GITHUB_TOKEN, NPM_CONFIG_* — these commonly carry
        // auth or can be abused by malicious installs. Use --env / `fend claude`
        // to opt in when actually needed.
        let hostEnv = ProcessInfo.processInfo.environment
        let passthrough: Set<String> = [
            "TERM", "LANG", "LC_ALL", "LC_CTYPE", "COLORTERM", "NO_COLOR", "FORCE_COLOR",
            "EDITOR", "VISUAL",
            "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
            "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL",
        ]
        var env: [String: String] = [:]
        for key in passthrough {
            if let val = hostEnv[key] { env[key] = val }
        }
        env["FEND_PROJECT"] = projectDir.lastPathComponent

        for (k, v) in extraEnv { env[k] = v }

        if claudeMode, let token = extractClaudeOAuthToken() {
            env["CLAUDE_CODE_OAUTH_TOKEN"] = token
        }

        // Set up Ctrl+C handler
        signal(SIGINT, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        sigintSource.setEventHandler {
            let fd = SignalState.shared.fd
            if fd >= 0 {
                sendSignal(SIGINT, to: fd)
            } else {
                Foundation.exit(130)
            }
        }
        sigintSource.resume()

        // Set up SIGWINCH handler (TTY mode only)
        var sigwinchSource: DispatchSourceSignal?
        if isTTY {
            signal(SIGWINCH, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
            source.setEventHandler {
                let fd = SignalState.shared.fd
                if fd >= 0 {
                    sendWindowSize(to: fd)
                }
            }
            source.resume()
            sigwinchSource = source
        }

        if isTTY {
            enableRawMode()
        }

        let start = CFAbsoluteTimeGetCurrent()

        // Try daemon first, then auto-start, then direct boot
        let exitCode: Int32
        if let code = try? runViaDaemon(paths: paths, projectDir: projectDir, command: finalCommand, env: env, tty: isTTY) {
            exitCode = code
        } else if autoStartDaemon(fendPath: ProcessInfo.processInfo.arguments[0]),
                  let code = try? runViaDaemon(paths: paths, projectDir: projectDir, command: finalCommand, env: env, tty: isTTY) {
            exitCode = code
        } else {
            exitCode = try await runDirect(paths: paths, projectDir: projectDir, command: finalCommand, env: env, start: start, tty: isTTY)
        }

        if isTTY {
            restoreTerminal()
        }

        let durationMs = Int((CFAbsoluteTimeGetCurrent() - start) * 1000)

        var fsDiff: FsDiffSummary?
        if let diffStart = diffStart, exitCode == 0 {
            let diff = FsDiff.changes(in: projectDir, after: diffStart)
            if !diff.touchedFiles.isEmpty {
                FsDiff.report(diff)
            }
            fsDiff = diff
        }

        AuditLog.append(AuditEntry(
            timestamp: AuditLog.now(),
            project: projectDir.path,
            cmd: command[0],
            args: Array(command.dropFirst()),
            envKeys: env.keys.sorted(),
            durationMs: durationMs,
            exitCode: exitCode,
            audit: auditSummary,
            fsDiff: fsDiff
        ), paths: paths)

        SignalState.shared.fd = -1
        _ = sigwinchSource
        fflush(stdout)
        fflush(stderr)
        Foundation.exit(exitCode)
    }

    /// Run via the daemon (relay through Unix socket).
    private static func runViaDaemon(paths: FendPaths, projectDir: URL, command: [String], env: [String: String], tty: Bool) throws -> Int32 {
        let daemonFd = connectToDaemon(socketPath: paths.socketPath)
        guard daemonFd >= 0 else { throw FendError.connectionClosed }
        defer {
            SignalState.shared.fd = -1
            Darwin.close(daemonFd)
        }

        let start = CFAbsoluteTimeGetCurrent()

        let request = DaemonRunRequest(
            projectDir: projectDir.path,
            cmd: command[0],
            args: Array(command.dropFirst()),
            env: env,
            tty: tty
        )
        let payload = try JSONEncoder().encode(request)
        try FramedMessage(type: .daemonRun, payload: payload).write(to: daemonFd)

        let readyFrame = try FramedMessage.read(from: daemonFd)
        if readyFrame.type == .daemonError {
            let err = try JSONDecoder().decode(DaemonErrorMsg.self, from: readyFrame.payload)
            throw FendError.connectionError(err.message)
        }
        guard readyFrame.type == .ready else {
            throw FendError.protocolError("Expected Ready from daemon")
        }

        let elapsed = CFAbsoluteTimeGetCurrent() - start
        fputs("fend: ready (\(String(format: "%.1f", elapsed))s)\n", stderr)

        SignalState.shared.fd = daemonFd
        if tty { sendWindowSize(to: daemonFd) }
        let stdinForwarder = startStdinForwarding(fd: daemonFd)
        defer { stdinForwarder.cancel() }

        return try relayOutput(from: daemonFd)
    }

    /// Second half of the install-flow audit decision: take a raw report and
    /// apply the user's policy. Called after the fix-offer, so findings have
    /// already been printed — `alreadyPrintedFindings` suppresses a redundant
    /// second dump inside the prompt path.
    private static func applyAuditPolicy(
        to report: AuditReport,
        policy: AuditConfig,
        alreadyPrintedFindings: Bool
    ) -> AuditReport {
        guard !report.findings.isEmpty else { return report }

        // Decide block / approved based on worst severity vs policy.
        let worst = report.worstSeverity
        let isBlocked = policy.block.contains(worst)
        if isBlocked {
            return AuditReport(
                totalPackages: report.totalPackages,
                findings: report.findings,
                decision: .blocked
            )
        }

        let needsPrompt = policy.prompt.contains(worst)
        let inCI = ProcessInfo.processInfo.environment["CI"] != nil
        let skipPrompt = !needsPrompt || (inCI && policy.autoApproveInCI)

        if skipPrompt {
            let reason: String
            switch policy.level {
            case .warn: reason = "level=warn"
            case .strict: reason = "below prompt threshold (worst=\(worst))"
            case .off: reason = "level=off"
            }
            fputs("\nfend: proceeding despite findings (\(reason)).\n", stderr)
            return AuditReport(
                totalPackages: report.totalPackages,
                findings: report.findings,
                decision: .approved
            )
        }

        // Findings were already printed by the caller (unified report above).
        // Just ask the y/N question.
        _ = alreadyPrintedFindings
        fputs("\nProceed with install scripts? [y/N] ", stderr)
        let approved = AuditPrompt.readYN()
        return AuditReport(
            totalPackages: report.totalPackages,
            findings: report.findings,
            decision: approved ? .approved : .denied
        )
    }

    /// Run directly (boot VM in-process, no daemon).
    private static func runDirect(paths: FendPaths, projectDir: URL, command: [String], env: [String: String], start: CFAbsoluteTime, tty: Bool) async throws -> Int32 {
        let config = FendConfig.load(from: projectDir)
        let vmManager = VMManager(paths: paths)
        let vmInstance = try await vmManager.vmForProject(projectDir, config: config)
        try await vmInstance.waitForReady()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        let vsockConnection = try await vmInstance.connectToGuest(port: vsockPort)
        let guest = GuestConnection(connection: vsockConnection)
        try guest.waitForReady()

        fputs("fend: ready (\(String(format: "%.1f", elapsed))s)\n", stderr)

        try guest.sendCommand(
            cmd: command[0],
            args: Array(command.dropFirst()),
            env: env,
            cwd: projectDir.path,
            tty: tty
        )

        SignalState.shared.fd = guest.fd
        if tty { sendWindowSize(to: guest.fd) }
        let stdinForwarder = startStdinForwarding(fd: guest.fd)
        defer {
            stdinForwarder.cancel()
            SignalState.shared.fd = -1
        }

        let exitCode = try relayOutput(from: guest.fd)
        vmInstance.forceStop()
        return exitCode
    }
}
