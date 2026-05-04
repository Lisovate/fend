import Foundation
import FendCommon

#if os(Linux)
import Glibc
#else
import Darwin
#endif

enum DoctorPlatform: Equatable {
    case macOS
    case linux
    case other(String)
}

struct DoctorDeviceStatus: Equatable {
    var path: String
    var exists: Bool
    var readable: Bool
    var writable: Bool

    var description: String {
        if !exists { return "missing" }
        if readable && writable { return path }
        return "permission denied"
    }
}

struct DoctorProbe: Equatable {
    var platform: DoctorPlatform
    var osDescription: String
    var architecture: String
    var runtimeDir: URL
    var kernelPath: URL
    var initrdPath: URL
    var rootfsPath: URL
    var kernelExists: Bool
    var initrdExists: Bool
    var rootfsExists: Bool
    var dockerAvailable: Bool
    var qemuAvailable: Bool
    var virtiofsdAvailable: Bool
    var passtAvailable: Bool
    var kvm: DoctorDeviceStatus?
    var vhostVsock: DoctorDeviceStatus?
    var cpuVirtualizationAvailable: Bool?
    var rustMuslTargetInstalled: Bool?
    var configSummary: String
}

struct DoctorReport {
    var title: String
    var fields: [(String, String)]
    var issues: [String]
}

enum DoctorChecks {
    static func currentProbe(paths: FendPaths, config: FendConfig) -> DoctorProbe {
        let platform = currentPlatform()
        let runtimeDir: URL
        let rootfsPath: URL

        switch platform {
        case .linux:
            runtimeDir = paths.home.appendingPathComponent("runtime/linux-x86_64")
            rootfsPath = runtimeDir.appendingPathComponent("rootfs.img")
        case .macOS, .other:
            runtimeDir = paths.runtimeDir
            rootfsPath = paths.rootfsImagePath
        }

        let fm = FileManager.default
        return DoctorProbe(
            platform: platform,
            osDescription: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: currentArchitecture(),
            runtimeDir: runtimeDir,
            kernelPath: runtimeDir.appendingPathComponent("vmlinuz"),
            initrdPath: runtimeDir.appendingPathComponent("initrd"),
            rootfsPath: rootfsPath,
            kernelExists: fm.fileExists(atPath: runtimeDir.appendingPathComponent("vmlinuz").path),
            initrdExists: fm.fileExists(atPath: runtimeDir.appendingPathComponent("initrd").path),
            rootfsExists: fm.fileExists(atPath: rootfsPath.path),
            dockerAvailable: processSucceeds("docker", arguments: ["info"]),
            qemuAvailable: commandExists("qemu-system-x86_64"),
            virtiofsdAvailable: commandExists("virtiofsd"),
            passtAvailable: commandExists("passt"),
            kvm: deviceStatus(path: "/dev/kvm"),
            vhostVsock: deviceStatus(path: "/dev/vhost-vsock"),
            cpuVirtualizationAvailable: cpuVirtualizationAvailable(),
            rustMuslTargetInstalled: rustTargetInstalled("x86_64-unknown-linux-musl"),
            configSummary: "node=\(config.runtime.node ?? "auto") bun=\(config.runtime.bun ?? "auto") cpus=\(config.vm.cpus) mem=\(config.vm.memoryMB)MB"
        )
    }

    static func evaluate(_ probe: DoctorProbe) -> DoctorReport {
        switch probe.platform {
        case .linux:
            return linuxReport(probe)
        case .macOS:
            return macOSReport(probe)
        case .other(let name):
            var report = macOSReport(probe)
            report.fields.insert(("platform", name), at: 0)
            report.issues.insert("This host platform is not supported yet.", at: 0)
            return report
        }
    }

    private static func macOSReport(_ probe: DoctorProbe) -> DoctorReport {
        var issues: [String] = []
        if !probe.kernelExists || !probe.initrdExists || !probe.rootfsExists {
            issues.append("Run scripts/prepare-runtime.sh to build runtime artifacts.")
        }
        if !probe.dockerAvailable {
            issues.append("Docker is required to build rootfs.img. Install Docker Desktop for Mac.")
        }

        return DoctorReport(
            title: "fend doctor",
            fields: [
                ("macOS", probe.osDescription),
                ("architecture", probe.architecture),
                ("kernel", artifactValue(probe.kernelPath, exists: probe.kernelExists)),
                ("initrd", artifactValue(probe.initrdPath, exists: probe.initrdExists)),
                ("rootfs", artifactValue(probe.rootfsPath, exists: probe.rootfsExists)),
                ("docker", probe.dockerAvailable ? "available" : "missing"),
                ("config", probe.configSummary),
            ],
            issues: issues
        )
    }

    private static func linuxReport(_ probe: DoctorProbe) -> DoctorReport {
        var issues: [String] = []
        let artifactsMissing = !probe.kernelExists || !probe.initrdExists || !probe.rootfsExists

        if probe.architecture != "x86_64" {
            issues.append("Linux spike currently requires x86_64.")
        }
        if probe.cpuVirtualizationAvailable == false {
            issues.append("CPU virtualization flags are missing. Enable VT-x/AMD-V or nested virtualization.")
        }
        if !probe.qemuAvailable {
            issues.append("Install qemu-system-x86_64, for example Arch package qemu-full.")
        }
        if !probe.virtiofsdAvailable {
            issues.append("Install virtiofsd.")
        }
        if !probe.passtAvailable {
            issues.append("Install passt, or launch the spike with FEND_QEMU_NETWORK=user/off.")
        }

        if let kvm = probe.kvm {
            if !kvm.exists {
                issues.append("/dev/kvm is missing. Enable virtualization and load the KVM module.")
            } else if !kvm.readable || !kvm.writable {
                issues.append("Current user cannot access /dev/kvm. Add the user to the kvm group and log in again.")
            }
        }

        if let vhostVsock = probe.vhostVsock, !vhostVsock.exists {
            issues.append("/dev/vhost-vsock is missing. Try: sudo modprobe vhost_vsock.")
        }

        if artifactsMissing {
            issues.append("Run scripts/prepare-linux-x86_64-runtime.sh to build Linux runtime artifacts.")
            if !probe.dockerAvailable {
                issues.append("Docker is required by the current Linux runtime builder.")
            }
            if probe.rustMuslTargetInstalled == false {
                issues.append("Install Rust target x86_64-unknown-linux-musl before building fendd.")
            }
        }

        return DoctorReport(
            title: "fend doctor",
            fields: [
                ("Linux", probe.osDescription),
                ("architecture", probe.architecture),
                ("runtime", probe.runtimeDir.path),
                ("kernel", artifactValue(probe.kernelPath, exists: probe.kernelExists)),
                ("initrd", artifactValue(probe.initrdPath, exists: probe.initrdExists)),
                ("rootfs", artifactValue(probe.rootfsPath, exists: probe.rootfsExists)),
                ("qemu", probe.qemuAvailable ? "available" : "missing"),
                ("virtiofsd", probe.virtiofsdAvailable ? "available" : "missing"),
                ("passt", probe.passtAvailable ? "available" : "missing"),
                ("docker", probe.dockerAvailable ? "available" : "missing"),
                ("rust target", rustTargetValue(probe.rustMuslTargetInstalled)),
                ("/dev/kvm", probe.kvm?.description ?? "not checked"),
                ("/dev/vhost-vsock", probe.vhostVsock?.description ?? "not checked"),
                ("cpu virt", cpuVirtValue(probe.cpuVirtualizationAvailable)),
                ("config", probe.configSummary),
            ],
            issues: issues
        )
    }

    private static func artifactValue(_ path: URL, exists: Bool) -> String {
        exists ? path.path : "missing"
    }

    private static func rustTargetValue(_ installed: Bool?) -> String {
        guard let installed else { return "not checked" }
        return installed ? "installed" : "missing"
    }

    private static func cpuVirtValue(_ available: Bool?) -> String {
        guard let available else { return "not checked" }
        return available ? "available" : "missing"
    }

    private static func currentPlatform() -> DoctorPlatform {
        #if os(Linux)
        return .linux
        #elseif os(macOS)
        return .macOS
        #else
        return .other(ProcessInfo.processInfo.operatingSystemVersionString)
        #endif
    }

    private static func currentArchitecture() -> String {
        #if arch(x86_64)
        return "x86_64"
        #elseif arch(arm64)
        return "arm64"
        #else
        return "unknown"
        #endif
    }

    private static func deviceStatus(path: String) -> DoctorDeviceStatus {
        DoctorDeviceStatus(
            path: path,
            exists: FileManager.default.fileExists(atPath: path),
            readable: access(path, R_OK) == 0,
            writable: access(path, W_OK) == 0
        )
    }

    private static func commandExists(_ name: String) -> Bool {
        let paths = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":") ?? []
        return paths.contains { dir in
            let candidate = URL(fileURLWithPath: String(dir)).appendingPathComponent(name).path
            return FileManager.default.isExecutableFile(atPath: candidate)
        }
    }

    private static func processSucceeds(_ executable: String, arguments: [String]) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [executable] + arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func rustTargetInstalled(_ target: String) -> Bool? {
        guard commandExists("rustup") else { return false }
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = ["rustup", "target", "list", "--installed"]
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return false }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return output.split(whereSeparator: \.isNewline).contains { $0 == target }
        } catch {
            return false
        }
    }

    private static func cpuVirtualizationAvailable() -> Bool? {
        #if os(Linux)
        guard let cpuinfo = try? String(contentsOfFile: "/proc/cpuinfo", encoding: .utf8) else {
            return nil
        }
        return cpuinfo.contains(" vmx ") || cpuinfo.contains(" svm ")
        #else
        return nil
        #endif
    }
}
