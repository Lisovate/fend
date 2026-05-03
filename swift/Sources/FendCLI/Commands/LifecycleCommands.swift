import ArgumentParser
import Foundation
import FendCommon
import FendDaemon

// MARK: - fend status

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show running VMs and their state"
    )

    func run() {
        let paths = FendPaths()
        let daemonFd = connectToDaemon(socketPath: paths.socketPath)
        guard daemonFd >= 0 else {
            TerminalUI.info("daemon not running")
            return
        }
        defer { Darwin.close(daemonFd) }

        do {
            try FramedMessage(type: .daemonStatus, payload: Data()).write(to: daemonFd)
            let response = try FramedMessage.read(from: daemonFd)

            if response.type == .daemonError {
                let err = try JSONDecoder().decode(DaemonErrorMsg.self, from: response.payload)
                TerminalUI.error(err.message)
                return
            }

            guard response.type == .daemonStatusResponse else {
                TerminalUI.error("unexpected daemon response")
                return
            }

            let status = try JSONDecoder().decode(DaemonStatusResponse.self, from: response.payload)
            if status.vms.isEmpty {
                TerminalUI.info("no running VMs", stream: .stdout)
            } else {
                TerminalUI.section("Running VMs")
                let rows = status.vms.map { vm in
                    let name = URL(fileURLWithPath: vm.projectDir).lastPathComponent
                    let uptime = formatUptime(vm.uptimeSeconds)
                    let ports = vm.forwardedPorts.isEmpty ? "-" : vm.forwardedPorts.map(String.init).joined(separator: ",")
                    return [name, vm.state, uptime, ports]
                }
                TerminalUI.table(headers: ["Project", "State", "Uptime", "Ports"], rows: rows)
            }
        } catch {
            TerminalUI.error(TerminalUI.describe(error))
        }
    }
}

// MARK: - fend stop

struct Stop: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop the VM for the current project"
    )

    func run() {
        let paths = FendPaths()
        let projectDir = FileManager.default.currentDirectoryPath

        let daemonFd = connectToDaemon(socketPath: paths.socketPath)
        guard daemonFd >= 0 else {
            TerminalUI.info("daemon not running")
            return
        }
        defer { Darwin.close(daemonFd) }

        do {
            let request = DaemonStopRequest(projectDir: projectDir)
            let payload = try JSONEncoder().encode(request)
            try FramedMessage(type: .daemonStopVM, payload: payload).write(to: daemonFd)

            let response = try FramedMessage.read(from: daemonFd)
            if response.type == .daemonError {
                let err = try JSONDecoder().decode(DaemonErrorMsg.self, from: response.payload)
                TerminalUI.error(err.message)
            } else if response.type == .ready {
                TerminalUI.success("VM stopped", detail: URL(fileURLWithPath: projectDir).lastPathComponent)
            }
        } catch {
            TerminalUI.error(TerminalUI.describe(error))
        }
    }
}

// MARK: - fend clean

struct Clean: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Destroy VM and caches for the current project"
    )

    func run() {
        let projectDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let paths = FendPaths()
        let hash = FendPaths.projectHash(for: projectDir)
        let projectStateDir = paths.stateDir.appendingPathComponent(hash)

        TerminalUI.step("cleaning project", detail: projectDir.lastPathComponent)

        let fm = FileManager.default
        if fm.fileExists(atPath: projectStateDir.path) {
            do {
                try fm.removeItem(at: projectStateDir)
                TerminalUI.success("removed per-project state", detail: hash)
            } catch {
                TerminalUI.error("failed to remove project state", detail: error.localizedDescription)
            }
        } else {
            TerminalUI.info("no project state found")
        }
    }
}

// MARK: - fend doctor

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check prerequisites and system compatibility"
    )

    func run() {
        let paths = FendPaths()
        let config = FendConfig.load(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        let fm = FileManager.default
        let kernelExists = fm.fileExists(atPath: paths.runtimeDir.appendingPathComponent("vmlinuz").path)
        let initrdExists = fm.fileExists(atPath: paths.runtimeDir.appendingPathComponent("initrd").path)
        let rootfsExists = fm.fileExists(atPath: paths.rootfsImagePath.path)

        let dockerAvailable: Bool = {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            task.arguments = ["docker", "info"]
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            do {
                try task.run()
                task.waitUntilExit()
                return task.terminationStatus == 0
            } catch {
                return false
            }
        }()

        TerminalUI.section("fend doctor")
        TerminalUI.fields([
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
        ])

        #if arch(arm64)
        let architecture = "Apple Silicon (arm64)"
        #else
        let architecture = "Intel (x86_64)"
        #endif

        TerminalUI.fields([
            ("architecture", architecture),
            ("kernel", kernelExists ? paths.runtimeDir.appendingPathComponent("vmlinuz").path : "missing"),
            ("initrd", initrdExists ? paths.runtimeDir.appendingPathComponent("initrd").path : "missing"),
            ("rootfs", rootfsExists ? paths.rootfsImagePath.path : "missing"),
            ("docker", dockerAvailable ? "available" : "missing"),
            ("config", "node=\(config.runtime.node ?? "auto") bun=\(config.runtime.bun ?? "auto") cpus=\(config.vm.cpus) mem=\(config.vm.memoryMB)MB"),
        ])

        var issues: [String] = []
        if !kernelExists || !initrdExists || !rootfsExists {
            issues.append("Run scripts/prepare-runtime.sh to build runtime artifacts.")
        }
        if !dockerAvailable {
            issues.append("Docker is required to build rootfs.img. Install Docker Desktop for Mac.")
        }

        if issues.isEmpty {
            TerminalUI.blank(.stdout)
            TerminalUI.success("all checks passed", stream: .stdout)
        } else {
            TerminalUI.blank(.stdout)
            for issue in issues {
                TerminalUI.warning(issue, stream: .stdout)
            }
        }
    }
}

// MARK: - fend daemon

struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Manage the fend daemon",
        subcommands: [DaemonStart.self, DaemonStop.self]
    )
}

struct DaemonStart: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start",
        abstract: "Start the fend daemon"
    )

    @Flag(name: .long, help: "Run in the foreground (don't detach). Useful for debugging.")
    var foreground: Bool = false

    func run() throws {
        let paths = FendPaths()
        try paths.ensureDirectories()

        if !foreground {
            // Must detach BEFORE any Dispatch queue or Task is created.
            daemonize(logPath: paths.daemonLogPath)
        }

        let daemon = Daemon(paths: paths)
        try daemon.start()
    }
}

struct DaemonStop: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop the fend daemon"
    )

    func run() {
        let paths = FendPaths()
        guard let pidStr = try? String(contentsOf: paths.pidPath, encoding: .utf8),
              let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            TerminalUI.info("daemon not running")
            return
        }
        if kill(pid, SIGTERM) == 0 {
            TerminalUI.success("daemon stopped", detail: "pid \(pid)")
        } else {
            TerminalUI.warning("daemon not running", detail: "removed stale pid/socket files")
            try? FileManager.default.removeItem(at: paths.pidPath)
            try? FileManager.default.removeItem(at: paths.socketPath)
        }
    }
}

// MARK: - Helpers

private func formatUptime(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
    return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
}
