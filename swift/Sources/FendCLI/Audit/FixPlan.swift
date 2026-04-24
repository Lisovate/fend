import Foundation

/// One package we're proposing to update.
struct FixItem: Hashable {
    /// Current state from the lockfile.
    let package: LockedPackage
    /// Max(fixedIn) across advisories covering this package.
    let targetVersion: String
    /// Advisory IDs this bump resolves (so we can report "fixes N advisories").
    let advisoryIds: [String]
    /// Worst severity bucket across resolved advisories.
    let worstSeverity: String
    /// Direct = appears in package.json; Transitive = add via overrides.
    let kind: FixKind
}

enum FixKind: Hashable {
    case direct
    case transitive
}

/// A computed upgrade plan, bucketed by how aggressive the change is.
/// Every bucket is a distinct UX story; never merge them for display.
struct FixPlan {
    /// In-range (or same-major) bumps for direct deps — `npm install pkg@X`.
    var safeDirect: [FixItem] = []
    /// In-range bumps for transitive deps — written to `overrides`.
    var safeOverride: [FixItem] = []
    /// Major-version bumps. Gated by `--force` because they can break the build.
    var breaking: [FixItem] = []
    /// Only a pre-release fix exists. Gated by `--include-prerelease`.
    var prerelease: [FixItem] = []
    /// Advisories with no published patched version.
    var noFix: [(LockedPackage, [Advisory])] = []

    var safeCount: Int { safeDirect.count + safeOverride.count }
    var hasSafe: Bool { safeCount > 0 }
    var isEmpty: Bool {
        safeDirect.isEmpty && safeOverride.isEmpty
            && breaking.isEmpty && prerelease.isEmpty && noFix.isEmpty
    }
}

/// Classify audit findings into an actionable fix plan.
/// Pure function over the audit report + the project's package.json.
enum FixPlanner {
    static func compute(
        report: AuditReport,
        projectDir: URL,
        includePrerelease: Bool,
        allowBreaking: Bool
    ) -> FixPlan {
        let directDeps = readDirectDeps(from: projectDir)
        var plan = FixPlan()

        // Group findings by package name. For each advisory, pick the smallest
        // published fix that's > current (never a downgrade). Final target is
        // max of those per-advisory targets — the smallest bump that patches
        // every advisory against this package.
        //
        // If an advisory has NO fix that's greater than current (either because
        // OSV lists no fix at all, or only backports into older lines), we skip
        // it when computing the target but surface it separately below.
        for (pkg, advisories) in report.findings {
            var perAdvisoryTargets: [String] = []
            for adv in advisories {
                let viable = adv.fixedVersions.filter {
                    compareVersions($0, pkg.version) > 0
                }
                if let minViable = viable.min(by: { compareVersions($0, $1) < 0 }) {
                    perAdvisoryTargets.append(minViable)
                }
            }

            guard let target = maxVersion(perAdvisoryTargets) else {
                // No advisory has a forward-fix. Unfixable for this package.
                plan.noFix.append((pkg, advisories))
                continue
            }

            let isPrerelease = target.contains("-")
            let isBreaking = majorsDiffer(current: pkg.version, target: target)
            let kind: FixKind = directDeps.contains(pkg.name) ? .direct : .transitive
            let worst = worstSeverity(advisories)

            let item = FixItem(
                package: pkg,
                targetVersion: target,
                advisoryIds: advisories.map { $0.id },
                worstSeverity: worst,
                kind: kind
            )

            if isPrerelease && !includePrerelease {
                plan.prerelease.append(item)
                continue
            }
            if isBreaking && !allowBreaking {
                plan.breaking.append(item)
                continue
            }

            // Passed both gates — treat as safe-to-apply.
            if kind == .direct {
                plan.safeDirect.append(item)
            } else {
                plan.safeOverride.append(item)
            }
        }

        // Sort every bucket alphabetically so output is deterministic.
        plan.safeDirect.sort { $0.package.name < $1.package.name }
        plan.safeOverride.sort { $0.package.name < $1.package.name }
        plan.breaking.sort { $0.package.name < $1.package.name }
        plan.prerelease.sort { $0.package.name < $1.package.name }
        plan.noFix.sort { $0.0.name < $1.0.name }

        return plan
    }

    /// Read dependencies / devDependencies / peerDependencies / optionalDependencies
    /// from package.json. Anything in those keys is a "direct" dep from npm's POV;
    /// anything only in the lockfile is transitive.
    static func readDirectDeps(from projectDir: URL) -> Set<String> {
        let url = projectDir.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var deps: Set<String> = []
        for key in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            if let dict = json[key] as? [String: Any] {
                for name in dict.keys {
                    deps.insert(name)
                }
            }
        }
        return deps
    }

    /// Pick the highest version from a list using SemVer major.minor.patch order.
    /// Pre-release suffixes (1.2.3-rc.1) sort below their release (1.2.3).
    static func maxVersion(_ versions: [String]) -> String? {
        versions.max { lhs, rhs in compareVersions(lhs, rhs) < 0 }
    }

    /// True if `current` and `target` differ in major version (the `X` in X.Y.Z).
    /// Used as a cheap "in range" heuristic — same-major fixes almost always
    /// satisfy a caret range (`^1.2.3`); different-major almost never does.
    static func majorsDiffer(current: String, target: String) -> Bool {
        let cMajor = current.split(separator: "-").first.map { String($0) } ?? current
        let tMajor = target.split(separator: "-").first.map { String($0) } ?? target
        let c = cMajor.split(separator: ".").first.map { String($0) } ?? ""
        let t = tMajor.split(separator: ".").first.map { String($0) } ?? ""
        return c != t
    }

    /// Highest-priority severity bucket present in the advisory list.
    static func worstSeverity(_ advisories: [Advisory]) -> String {
        let order = ["malware", "critical", "high", "medium", "low", "unknown"]
        for sev in order {
            if advisories.contains(where: { $0.severity == sev }) {
                return sev
            }
        }
        return "unknown"
    }
}

/// SemVer-ish comparison used across the audit module. Splits on `.`, compares
/// numeric components left-to-right. Pre-release (anything after `-`) sorts
/// *below* the same triple without a suffix — e.g. `1.2.3-rc.1 < 1.2.3`.
func compareVersions(_ a: String, _ b: String) -> Int {
    let aBase = a.split(separator: "-").first.map { String($0) } ?? a
    let bBase = b.split(separator: "-").first.map { String($0) } ?? b
    let aNums = aBase.split(separator: ".").map { Int($0) ?? 0 }
    let bNums = bBase.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(aNums.count, bNums.count) {
        let av = i < aNums.count ? aNums[i] : 0
        let bv = i < bNums.count ? bNums[i] : 0
        if av != bv { return av < bv ? -1 : 1 }
    }
    let aIsPre = a.contains("-") ? 1 : 0
    let bIsPre = b.contains("-") ? 1 : 0
    if aIsPre != bIsPre { return bIsPre - aIsPre }
    return 0
}
