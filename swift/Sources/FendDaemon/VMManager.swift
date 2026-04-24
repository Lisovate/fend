import Foundation
@preconcurrency import Virtualization
import FendCommon

/// Manages VM instances, one per project directory.
/// Handles VM creation, warm pool, and idle timeout.
public final class VMManager {
    private let paths: FendPaths
    /// Active VMs keyed by project directory path.
    private var vms: [String: VMInstance] = [:]
    private let lock = NSLock()

    public init(paths: FendPaths) {
        self.paths = paths
    }

    /// Get or create a VM for the given project directory.
    /// Phase 2C fix: insert VM into map before unlocking to prevent double-boot race.
    public func vmForProject(_ projectDir: URL, config: FendConfig) async throws -> VMInstance {
        let key = projectDir.standardizedFileURL.path

        lock.lock()
        if let existing = vms[key] {
            switch existing.state {
            case .running:
                lock.unlock()
                return existing
            case .paused:
                lock.unlock()
                try await existing.resume()
                return existing
            case .stopped, .error:
                break
            case .booting:
                lock.unlock()
                return existing
            }
        }

        // Insert before unlocking so concurrent callers see .booting state (Phase 2C)
        let vm = try VMInstance(projectDir: projectDir, config: config, paths: paths)
        vms[key] = vm
        lock.unlock()

        try await vm.start()
        return vm
    }

    /// Stop all managed VMs.
    public func stopAll() {
        lock.lock()
        let allVMs = vms.values
        vms.removeAll()
        lock.unlock()
        for vm in allVMs {
            vm.forceStop()
        }
    }

    /// Reap idle VMs: pause after `pauseAfter` seconds, force-stop after
    /// `stopAfter` seconds of continued idle. Paused VMs resume in ~100ms
    /// vs ~800ms cold boot, so the staircase keeps warm resume snappy for
    /// recent projects without holding memory indefinitely.
    public func reapIdle(pauseAfter: TimeInterval, stopAfter: TimeInterval) {
        lock.lock()
        let now = Date()
        var toPause: [VMInstance] = []
        var toStopKeys: [String] = []
        for (key, vm) in vms {
            let idle = now.timeIntervalSince(vm.lastUsed)
            switch vm.state {
            case .running where idle > pauseAfter:
                toPause.append(vm)
            case .paused where idle > stopAfter:
                toStopKeys.append(key)
            default:
                break
            }
        }
        let toStop = toStopKeys.compactMap { vms.removeValue(forKey: $0) }
        lock.unlock()

        for vm in toPause {
            fputs("fend: pausing idle VM for \(vm.projectDir.lastPathComponent)\n", stderr)
            Task {
                do {
                    try await vm.pause()
                } catch {
                    fputs("fend: pause failed for \(vm.projectDir.lastPathComponent): \(error)\n", stderr)
                }
            }
        }

        for vm in toStop {
            fputs("fend: stopping long-idle VM for \(vm.projectDir.lastPathComponent)\n", stderr)
            vm.forceStop()
        }
    }

    /// Deprecated shim — old daemon timer path.
    @available(*, deprecated, renamed: "reapIdle(pauseAfter:stopAfter:)")
    public func stopIdleVMs(olderThan interval: TimeInterval) {
        reapIdle(pauseAfter: interval, stopAfter: interval * 6)
    }

    /// Get status of all running VMs.
    public func status() -> [VMInfo] {
        lock.lock()
        let snapshot = Array(vms.values)
        lock.unlock()

        let now = Date()
        return snapshot.map { vm in
            VMInfo(
                projectDir: vm.projectDir.path,
                state: vm.state.rawValue,
                uptimeSeconds: Int(now.timeIntervalSince(vm.startTime)),
                forwardedPorts: vm.portForwarder?.forwardedPorts ?? []
            )
        }
    }

    /// Stop the VM for a specific project directory.
    public func stopVM(forProjectDir dir: String) -> Bool {
        let key = URL(fileURLWithPath: dir).standardizedFileURL.path
        lock.lock()
        guard let vm = vms.removeValue(forKey: key) else {
            lock.unlock()
            return false
        }
        lock.unlock()
        vm.forceStop()
        return true
    }

    /// GC per-project rootfs clones. Removes entries whose project directory
    /// no longer exists, OR whose rootfs hasn't been touched in `maxAgeDays`.
    /// Safe to call concurrently with VM boot — protected by `lock` so we
    /// don't delete a clone for a VM that's about to start using it.
    public func gcProjectState(maxAgeDays: Int = 30) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: paths.stateDir, includingPropertiesForKeys: [.contentModificationDateKey]) else {
            return
        }

        let cutoff = Date().addingTimeInterval(-Double(maxAgeDays) * 86400)
        var reclaimed = 0

        for entry in entries {
            let hash = entry.lastPathComponent
            let rootfs = entry.appendingPathComponent("rootfs.img")
            let pathFile = entry.appendingPathComponent("project-path")

            // Skip if this hash belongs to a live VM.
            var isLive = false
            lock.lock()
            for vm in vms.values where FendPaths.projectHash(for: vm.projectDir) == hash {
                isLive = true
                break
            }
            lock.unlock()
            if isLive { continue }

            // Reason 1: sidecar says the project dir is gone.
            if let original = try? String(contentsOf: pathFile, encoding: .utf8), !original.isEmpty,
               !fm.fileExists(atPath: original) {
                try? fm.removeItem(at: entry)
                reclaimed += 1
                fputs("fend: gc reclaimed \(hash) (project dir gone: \(original))\n", stderr)
                continue
            }

            // Reason 2: rootfs older than cutoff.
            if let attrs = try? fm.attributesOfItem(atPath: rootfs.path),
               let mtime = attrs[.modificationDate] as? Date,
               mtime < cutoff {
                try? fm.removeItem(at: entry)
                reclaimed += 1
                fputs("fend: gc reclaimed \(hash) (idle for >\(maxAgeDays)d)\n", stderr)
            }
        }

        if reclaimed > 0 {
            fputs("fend: gc freed \(reclaimed) stale project rootfs(es)\n", stderr)
        }
    }
}
