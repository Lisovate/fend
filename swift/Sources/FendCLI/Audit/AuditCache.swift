import Foundation
import FendCommon

/// On-disk cache keyed by advisory ID. Advisory metadata is effectively
/// immutable — once `GHSA-xxxx` exists, its severity and fix version don't
/// change. So we can cache aggressively. We still rerun the batch ID query
/// on every audit (~500ms for a typical tree) so new advisories against
/// already-pinned versions are caught as soon as they're published; the
/// per-ID cache just skips the detail fetch for IDs we've already seen.
///
/// Layout:  ~/.fend/cache/audit/adv-<sanitized-id>.json
struct AuditCache {
    private let dir: URL
    /// TTL after which we refetch an advisory's full detail. Short enough that
    /// material updates (new severity, new fix) land within a day; long enough
    /// that steady-state audits are ~free.
    private let ttl: TimeInterval = 7 * 24 * 3600 // 7 days

    init(paths: FendPaths = FendPaths()) {
        self.dir = paths.auditCacheDir
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        migrateLegacyFiles()
    }

    func loadAdvisory(id: String) -> Advisory? {
        let url = advisoryFile(id)
        guard let data = try? Data(contentsOf: url),
              let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            return nil
        }
        if Date().timeIntervalSince(entry.fetchedAt) > ttl {
            return nil
        }
        return entry.advisory
    }

    func storeAdvisory(_ advisory: Advisory) {
        let entry = Entry(advisory: advisory, fetchedAt: Date())
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: advisoryFile(advisory.id), options: .atomic)
    }

    /// Wipe all per-advisory entries (used by `fend audit --update-db`).
    func clear() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix("adv-") {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    private func advisoryFile(_ id: String) -> URL {
        // Keep filenames filesystem-safe for IDs like `RUSTSEC-2024/0001`.
        let safe = id
            .replacingOccurrences(of: "/", with: "%2F")
            .replacingOccurrences(of: ":", with: "%3A")
        return dir.appendingPathComponent("adv-\(safe).json")
    }

    /// Delete cache files produced by older fend versions. Cheap one-time
    /// migration so users don't need to manually clear `~/.fend/cache/audit/`.
    private func migrateLegacyFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasPrefix("pkg-") || name.hasPrefix("tree-") {
                try? FileManager.default.removeItem(at: entry)
            }
        }
    }

    private struct Entry: Codable {
        let advisory: Advisory
        let fetchedAt: Date
    }
}
