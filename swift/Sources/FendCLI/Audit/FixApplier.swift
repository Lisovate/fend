import Foundation

enum FixApplyError: Error, LocalizedError {
    case missingPackageJSON
    case packageJSONUnreadable(String)
    case packageJSONWriteFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingPackageJSON:
            return "fend: package.json missing — can't apply fixes."
        case .packageJSONUnreadable(let m):
            return "fend: package.json unreadable: \(m)"
        case .packageJSONWriteFailed(let m):
            return "fend: could not write package.json: \(m)"
        }
    }
}

/// Turn a FixPlan into concrete side effects:
///   1. Merge transitive fixes into `overrides` in `package.json`.
///   2. Return the argv for `npm install <pkg@target> …` (direct fixes).
///
/// We deliberately don't touch `package-lock.json` — let npm resolve. That
/// keeps fend's trust boundary clean (it picks the plan, npm applies it)
/// and means the install still runs in the sandbox via the existing flow.
enum FixApplier {
    /// Write any `overrides` required by `plan.safeOverride` into package.json.
    /// Returns the set of override keys that were added/updated (for reporting).
    @discardableResult
    static func writeOverrides(_ plan: FixPlan, projectDir: URL) throws -> [String] {
        let overrides = plan.safeOverride
        guard !overrides.isEmpty else { return [] }

        let url = projectDir.appendingPathComponent("package.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw FixApplyError.missingPackageJSON
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw FixApplyError.packageJSONUnreadable(error.localizedDescription)
        }

        guard var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FixApplyError.packageJSONUnreadable("not a JSON object")
        }

        var merged = (json["overrides"] as? [String: Any]) ?? [:]
        var changedKeys: [String] = []
        for item in overrides {
            let existing = merged[item.package.name] as? String
            if existing != item.targetVersion {
                merged[item.package.name] = item.targetVersion
                changedKeys.append(item.package.name)
            }
        }
        json["overrides"] = merged

        do {
            let output = try JSONSerialization.data(
                withJSONObject: json,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            // Preserve a trailing newline — tools like `prettier` expect one.
            var final = output
            if final.last != 0x0A { final.append(0x0A) }
            try final.write(to: url, options: .atomic)
        } catch {
            throw FixApplyError.packageJSONWriteFailed(error.localizedDescription)
        }

        return changedKeys
    }

    /// Build the `npm install` argv that applies all direct-dep fixes in the plan.
    /// If the plan has no direct fixes (only overrides), returns a plain
    /// `npm install` which re-resolves the lockfile to honor the new overrides.
    static func installArgv(for plan: FixPlan) -> [String] {
        var args = ["npm", "install"]
        for item in plan.safeDirect {
            args.append("\(item.package.name)@\(item.targetVersion)")
        }
        return args
    }
}
