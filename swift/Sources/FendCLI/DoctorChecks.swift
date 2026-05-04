import Foundation
import FendCommon

enum DoctorPlatform: Equatable {
    case macOS
    case other(String)
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
    var configSummary: String
}

struct DoctorReport {
    var title: String
    var fields: [(String, String)]
    var issues: [String]
}

enum DoctorChecks {
    static func currentProbe(paths: FendPaths, config: FendConfig) -> DoctorProbe {
        let runtimeDir = paths.runtimeDir
        let rootfsPath = paths.rootfsImagePath
        let fm = FileManager.default

        return DoctorProbe(
            platform: currentPlatform(),
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
            configSummary: "node=\(config.runtime.node ?? "auto") bun=\(config.runtime.bun ?? "auto") cpus=\(config.vm.cpus) mem=\(config.vm.memoryMB)MB"
        )
    }

    static func evaluate(_ probe: DoctorProbe) -> DoctorReport {
        switch probe.platform {
        case .macOS:
            return macOSReport(probe)
        case .other(let name):
            var report = macOSReport(probe)
            report.fields.insert(("platform", name), at: 0)
            report.issues.insert("This host platform is not supported by the Swift macOS CLI.", at: 0)
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

    private static func artifactValue(_ path: URL, exists: Bool) -> String {
        exists ? path.path : "missing"
    }

    private static func currentPlatform() -> DoctorPlatform {
        #if os(macOS)
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
}
