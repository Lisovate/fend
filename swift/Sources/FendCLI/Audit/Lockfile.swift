import Foundation
import CryptoKit

/// A single name@version entry resolved from a lockfile.
struct LockedPackage: Hashable {
    let name: String
    let version: String
}

enum LockfileError: Error {
    case notFound
    case unsupportedFormat(String)
    case parseError(String)
}

/// Minimal package-lock.json parser. Supports v1, v2, v3 schemas.
/// We only care about the flat set of {name, version} pairs to audit —
/// we don't care about the dep graph.
enum NPMLockfile {
    /// Find and parse a lockfile in the given project. Returns the resolved
    /// tree + a stable hash of the lockfile bytes (for the tree-level cache).
    static func load(from projectDir: URL) throws -> (packages: [LockedPackage], hash: String) {
        let url = projectDir.appendingPathComponent("package-lock.json")
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else {
            throw LockfileError.notFound
        }

        let digest = SHA256.hash(data: data)
        let hash = digest.prefix(16).map { String(format: "%02x", $0) }.joined()

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LockfileError.parseError("package-lock.json is not a JSON object")
        }

        let version = (json["lockfileVersion"] as? Int) ?? 1

        var packages: Set<LockedPackage> = []

        switch version {
        case 1:
            if let deps = json["dependencies"] as? [String: Any] {
                collectV1(deps: deps, into: &packages)
            }
        case 2, 3:
            // v2/v3 have "packages" keyed by path. The root is "".
            if let pkgs = json["packages"] as? [String: Any] {
                for (path, value) in pkgs {
                    guard let entry = value as? [String: Any] else { continue }
                    guard let version = entry["version"] as? String else { continue }
                    let name: String
                    if let explicit = entry["name"] as? String {
                        name = explicit
                    } else if path.isEmpty {
                        continue // root project — skip
                    } else if let idx = path.range(of: "node_modules/", options: .backwards) {
                        name = String(path[idx.upperBound...])
                    } else {
                        continue
                    }
                    packages.insert(LockedPackage(name: name, version: version))
                }
            }
            // v2 ALSO has v1-style "dependencies" for backwards compatibility.
            // Skipping it — packages[] is authoritative in v2/v3.
        default:
            throw LockfileError.unsupportedFormat("lockfileVersion \(version) is not supported")
        }

        return (packages.sorted { ($0.name, $0.version) < ($1.name, $1.version) }, hash)
    }

    private static func collectV1(deps: [String: Any], into out: inout Set<LockedPackage>) {
        for (name, value) in deps {
            guard let entry = value as? [String: Any] else { continue }
            if let version = entry["version"] as? String {
                out.insert(LockedPackage(name: name, version: version))
            }
            if let nested = entry["dependencies"] as? [String: Any] {
                collectV1(deps: nested, into: &out)
            }
        }
    }
}
