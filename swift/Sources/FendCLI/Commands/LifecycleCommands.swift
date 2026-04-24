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
            print("fend: daemon is not running")
            return
        }
        defer { Darwin.close(daemonFd) }

        do {
            try FramedMessage(type: .daemonStatus, payload: Data()).write(to: daemonFd)
            let response = try FramedMessage.read(from: daemonFd)

            if response.type == .daemonError {
                let err = try JSONDecoder().decode(DaemonErrorMsg.self, from: response.payload)
                fputs("fend: \(err.message)\n", stderr)
                return
            }

            guard response.type == .daemonStatusResponse else {
                fputs("fend: unexpected response\n", stderr)
                return
            }

            let status = try JSONDecoder().decode(DaemonStatusResponse.self, from: response.payload)
            if status.vms.isEmpty {
                print("fend: no running VMs")
            } else {
                print("PROJECT                          STATE       UPTIME     PORTS")
                for vm in status.vms {
                    let name = URL(fileURLWithPath: vm.projectDir).lastPathComponent
                    let uptime = formatUptime(vm.uptimeSeconds)
                    let ports = vm.forwardedPorts.map(String.init).joined(separator: ",")
                    print("\(name.padding(toLength: 32, withPad: " ", startingAt: 0)) \(vm.state.padding(toLength: 11, withPad: " ", startingAt: 0)) \(uptime.padding(toLength: 10, withPad: " ", startingAt: 0)) \(ports)")
                }
            }
        } catch {
            fputs("fend: \(error)\n", stderr)
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
            print("fend: daemon is not running")
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
                fputs("fend: \(err.message)\n", stderr)
            } else if response.type == .ready {
                print("fend: VM stopped for \(URL(fileURLWithPath: projectDir).lastPathComponent)")
            }
        } catch {
            fputs("fend: \(error)\n", stderr)
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

        print("fend: cleaning \(projectDir.lastPathComponent)...")

        let fm = FileManager.default
        if fm.fileExists(atPath: projectStateDir.path) {
            do {
                try fm.removeItem(at: projectStateDir)
                print("fend: removed per-project state (\(hash))")
            } catch {
                fputs("fend: failed to remove \(projectStateDir.path): \(error.localizedDescription)\n", stderr)
            }
        } else {
            print("fend: no project state found")
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

        print("fend doctor")
        print("  macOS version: \(ProcessInfo.processInfo.operatingSystemVersionString)")

        #if arch(arm64)
        print("  Architecture:  Apple Silicon (arm64)")
        #else
        print("  Architecture:  Intel (x86_64)")
        #endif

        print("  Kernel:        \(kernelExists ? paths.runtimeDir.appendingPathComponent("vmlinuz").path : "NOT FOUND")")
        print("  Initrd:        \(initrdExists ? paths.runtimeDir.appendingPathComponent("initrd").path : "NOT FOUND")")
        print("  Rootfs:        \(rootfsExists ? paths.rootfsImagePath.path : "NOT FOUND")")
        print("  Docker:        \(dockerAvailable ? "available" : "NOT FOUND")")
        print("  Config:        node=\(config.runtime.node ?? "auto") bun=\(config.runtime.bun ?? "auto") cpus=\(config.vm.cpus) mem=\(config.vm.memoryMB)MB")

        var issues: [String] = []
        if !kernelExists || !initrdExists || !rootfsExists {
            issues.append("Run scripts/prepare-runtime.sh to build runtime artifacts.")
        }
        if !dockerAvailable {
            issues.append("Docker is required to build rootfs.img. Install Docker Desktop for Mac.")
        }

        if issues.isEmpty {
            print("")
            print("  All checks passed.")
        } else {
            print("")
            for issue in issues {
                print("  \(issue)")
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
            print("fend: daemon is not running")
            return
        }
        if kill(pid, SIGTERM) == 0 {
            print("fend: daemon stopped (pid \(pid))")
        } else {
            print("fend: daemon is not running (stale pid file)")
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
