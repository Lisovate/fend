import Foundation

/// A single advisory found against a package version.
struct Advisory: Codable, Hashable {
    let id: String
    let summary: String
    let severity: String
    let source: String // "osv" for now; "github" / "socket" later
    let url: String?
    /// Every `fixed` version the advisory lists across all its `affected`
    /// ranges. OSV commonly lists multiple — e.g. a fix in a 2.x release
    /// AND a fix in the current 4.x line — so picking "the" fix requires
    /// knowing the caller's current version (see FixPlanner).
    /// Empty = no patched version published.
    let fixedVersions: [String]
}

/// Query result for one package@version.
struct AdvisoryResult: Codable {
    let package: String
    let version: String
    let advisories: [Advisory]
}

enum OSVError: Error {
    case networkError(String)
    case badResponse(String)
}

/// Client for https://api.osv.dev/v1/querybatch. No auth required.
/// OSV aggregates GitHub Advisory DB, PyPI, RustSec, Go, OSS-Fuzz,
/// and (importantly) the OSSF malicious-packages database.
enum OSVClient {
    private static let batchEndpoint = URL(string: "https://api.osv.dev/v1/querybatch")!
    private static let vulnEndpoint = "https://api.osv.dev/v1/vulns/"
    private static let batchSize = 200
    private static let timeout: TimeInterval = 20
    private static let detailConcurrency = 8

    /// Query OSV for a batch of npm packages. Returns one AdvisoryResult per
    /// input package (empty advisories array means clean).
    ///
    /// Two-phase because OSV's `querybatch` endpoint returns only `{id, modified}`
    /// per vuln — the severity/summary we need live on the per-ID detail endpoint.
    /// The ID query is always fresh (cheap, 1 HTTP request regardless of tree
    /// size); detail fetches are cached per-ID since advisory data is
    /// effectively immutable.
    static func query(packages: [LockedPackage], cache: AuditCache) async throws -> [AdvisoryResult] {
        guard !packages.isEmpty else { return [] }

        var packageIds: [(LockedPackage, [String])] = []
        for chunk in packages.chunked(into: batchSize) {
            let chunkIds = try await queryChunkIds(chunk)
            packageIds.append(contentsOf: chunkIds)
        }

        let uniqueIds = Set(packageIds.flatMap { $0.1 })
        let detailsById = await fetchDetails(ids: Array(uniqueIds), cache: cache)

        return packageIds.map { pkg, ids in
            AdvisoryResult(
                package: pkg.name,
                version: pkg.version,
                advisories: ids.compactMap { detailsById[$0] }
            )
        }
    }

    private static func queryChunkIds(_ chunk: [LockedPackage]) async throws -> [(LockedPackage, [String])] {
        var request = URLRequest(url: batchEndpoint, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("fend-cli", forHTTPHeaderField: "User-Agent")

        let payload: [String: Any] = [
            "queries": chunk.map { pkg in
                [
                    "package": ["name": pkg.name, "ecosystem": "npm"],
                    "version": pkg.version,
                ]
            }
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OSVError.badResponse("OSV returned non-200")
        }

        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let resultsArray = obj["results"] as? [[String: Any]] else {
            throw OSVError.badResponse("OSV response missing 'results'")
        }

        var out: [(LockedPackage, [String])] = []
        for (pkg, result) in zip(chunk, resultsArray) {
            let vulns = (result["vulns"] as? [[String: Any]]) ?? []
            let ids = vulns.compactMap { $0["id"] as? String }
            out.append((pkg, ids))
        }
        return out
    }

    /// Fetch full vuln details for each ID. Checks the per-ID cache first;
    /// only IDs we haven't seen before (or whose cache has expired) hit the
    /// network. Concurrent fetches are capped so a huge findings set doesn't
    /// hammer OSV. Returns ID → Advisory; IDs that failed detail fetch are
    /// omitted.
    private static func fetchDetails(ids: [String], cache: AuditCache) async -> [String: Advisory] {
        guard !ids.isEmpty else { return [:] }

        var results: [String: Advisory] = [:]
        var missingIds: [String] = []
        for id in ids {
            if let cached = cache.loadAdvisory(id: id) {
                results[id] = cached
            } else {
                missingIds.append(id)
            }
        }

        guard !missingIds.isEmpty else { return results }

        await withTaskGroup(of: (String, Advisory?).self) { group in
            var running = 0
            var idx = 0

            while idx < missingIds.count || running > 0 {
                while running < detailConcurrency && idx < missingIds.count {
                    let id = missingIds[idx]
                    idx += 1
                    running += 1
                    group.addTask {
                        (id, try? await fetchOneDetail(id: id))
                    }
                }
                if let (id, adv) = await group.next() {
                    running -= 1
                    if let adv = adv {
                        results[id] = adv
                        cache.storeAdvisory(adv)
                    }
                }
            }
        }

        return results
    }

    private static func fetchOneDetail(id: String) async throws -> Advisory {
        guard let url = URL(string: vulnEndpoint + id) else {
            throw OSVError.badResponse("bad vuln id \(id)")
        }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("fend-cli", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw OSVError.badResponse("OSV vuln \(id) returned non-200")
        }

        guard let vuln = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OSVError.badResponse("OSV vuln \(id) not a JSON object")
        }

        let summary = (vuln["summary"] as? String) ?? id
        let severity = extractSeverity(vuln)
        let fixedVersions = extractFixedVersions(vuln)
        return Advisory(
            id: id,
            summary: summary,
            severity: severity,
            source: "osv",
            url: "https://osv.dev/vulnerability/\(id)",
            fixedVersions: fixedVersions
        )
    }

    /// Collect every `fixed` version from the vuln's `affected` schema — across
    /// all affected entries and all ranges. The caller picks the right one based
    /// on the current version; we keep the full set so a package with a
    /// backported fix and a main-line fix doesn't look like a downgrade.
    private static func extractFixedVersions(_ vuln: [String: Any]) -> [String] {
        guard let affected = vuln["affected"] as? [[String: Any]] else { return [] }
        var result: [String] = []
        for entry in affected {
            guard let ranges = entry["ranges"] as? [[String: Any]] else { continue }
            for range in ranges {
                guard let events = range["events"] as? [[String: Any]] else { continue }
                for event in events {
                    if let fixed = event["fixed"] as? String, !fixed.isEmpty {
                        result.append(fixed)
                    }
                }
            }
        }
        return result
    }

    /// Map OSV's CVSS / database_specific severity to our buckets:
    /// "malware" | "critical" | "high" | "medium" | "low" | "unknown".
    /// Malicious-packages DB entries are the "malware" bucket; CVSS scores
    /// collapse to the standard critical/high/medium/low bands.
    private static func extractSeverity(_ vuln: [String: Any]) -> String {
        // GitHub's database_specific.severity is the most reliable bucket.
        if let dbSpecific = vuln["database_specific"] as? [String: Any] {
            if let sev = dbSpecific["severity"] as? String {
                let norm = sev.lowercased()
                if norm == "malware" || norm == "critical" || norm == "high"
                    || norm == "moderate" || norm == "medium" || norm == "low" {
                    return norm == "moderate" ? "medium" : norm
                }
            }
        }

        // OSSF malicious-packages DB IDs start with "MAL-".
        if let id = vuln["id"] as? String, id.hasPrefix("MAL-") {
            return "malware"
        }

        // Fall back to CVSS v3/v4 score → band. OSV's severity[].score can be
        // either a raw number ("7.5") or a vector ("CVSS:3.1/AV:N/AC:L/..."),
        // or both with a separate `baseScore`. Try each.
        if let severities = vuln["severity"] as? [[String: Any]] {
            for sev in severities {
                if let score = sev["score"] as? String,
                   let cvss = parseCVSSScore(score) {
                    return cvssBand(cvss)
                }
                if let score = sev["score"] as? Double {
                    return cvssBand(score)
                }
                if let base = sev["baseScore"] as? Double {
                    return cvssBand(base)
                }
            }
        }

        return "unknown"
    }

    /// Parse an OSV severity.score field. Accepts a raw float like "7.5" or
    /// a CVSS vector like "CVSS:3.1/AV:N/AC:L/…" — for vector strings we can't
    /// recover the numeric base score without a CVSS calculator, so we return
    /// nil and fall through to the next severity entry.
    private static func parseCVSSScore(_ s: String) -> Double? {
        if let d = Double(s) { return d }
        return nil
    }

    private static func cvssBand(_ score: Double) -> String {
        switch score {
        case 9.0...: return "critical"
        case 7.0..<9.0: return "high"
        case 4.0..<7.0: return "medium"
        case 0.1..<4.0: return "low"
        default: return "unknown"
        }
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
