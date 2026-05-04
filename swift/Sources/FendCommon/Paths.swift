import Foundation
import CryptoKit

/// Paths used by the fend runtime.
public struct FendPaths {
    public let home: URL
    public let runtimeDir: URL
    public let cacheDir: URL
    public let toolsDir: URL
    public let socketPath: URL
    public let pidPath: URL
    public let stateDir: URL
    public let logsDir: URL
    public let auditCacheDir: URL

    public init() {
        let homeDir = FileManager.default.homeDirectoryForCurrentUser
        self.home = homeDir.appendingPathComponent(".fend")
        self.runtimeDir = home.appendingPathComponent("runtime")
        self.cacheDir = home.appendingPathComponent("cache")
        self.toolsDir = home.appendingPathComponent("tools")
        self.socketPath = home.appendingPathComponent("fend.sock")
        self.pidPath = home.appendingPathComponent("fend.pid")
        self.stateDir = home.appendingPathComponent("state")
        self.logsDir = home.appendingPathComponent("logs")
        self.auditCacheDir = cacheDir.appendingPathComponent("audit")
    }

    /// Path to the daemon's log file.
    public var daemonLogPath: URL { logsDir.appendingPathComponent("daemon.log") }

    /// Path to the structured fend activity log (JSONL).
    public var auditLogPath: URL { home.appendingPathComponent("audit.jsonl") }

    /// Sidecar file next to a per-project rootfs clone that stores the original
    /// project path. Used by the GC pass to decide which clones to reclaim.
    public func projectPathFile(hash: String) -> URL {
        stateDir.appendingPathComponent(hash).appendingPathComponent("project-path")
    }

    /// Directory containing a Node.js guest Linux installation for a given version.
    public func nodeDir(version: String, platform: GuestRuntimePlatform = .current) -> URL {
        let name = platform.usesLegacyToolDirectoryName
            ? "node-\(version)"
            : "node-\(version)-\(platform.rawValue)"
        return toolsDir.appendingPathComponent(name)
    }

    /// Directory containing a Bun guest Linux installation.
    public func bunDir(version: String, platform: GuestRuntimePlatform = .current) -> URL {
        let name = platform.usesLegacyToolDirectoryName
            ? "bun-\(version)"
            : "bun-\(version)-\(platform.rawValue)"
        return toolsDir.appendingPathComponent(name)
    }

    /// Path to the base rootfs.img in the runtime directory.
    public var rootfsImagePath: URL {
        runtimeDir.appendingPathComponent("rootfs.img")
    }

    /// Compute a stable hash for a project directory path.
    public static func projectHash(for projectDir: URL) -> String {
        let data = Data(projectDir.standardizedFileURL.path.utf8)
        let digest = SHA256.hash(data: data)
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Path to the per-project rootfs clone.
    public func projectRootfsPath(hash: String) -> URL {
        stateDir.appendingPathComponent(hash).appendingPathComponent("rootfs.img")
    }

    /// Ensure all directories exist.
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [home, runtimeDir, cacheDir, toolsDir, stateDir, logsDir, auditCacheDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
