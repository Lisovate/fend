import Foundation
import ArgumentParser

/// Parse `--env KEY=VALUE` pairs and `--env-file <path>` files into a single
/// env map. Later sources override earlier ones; --env (direct) always wins
/// over --env-file since it's more explicit.
func parseExtraEnv(pairs: [String], files: [String]) throws -> [String: String] {
    var env: [String: String] = [:]

    for file in files {
        let url = URL(fileURLWithPath: file)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            throw ValidationError("fend: --env-file: cannot read \(file)")
        }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let stripped = trimmed.hasPrefix("export ") ? String(trimmed.dropFirst(7)) : trimmed
            guard let eq = stripped.firstIndex(of: "=") else { continue }
            let key = String(stripped[stripped.startIndex..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(stripped[stripped.index(after: eq)...])
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")),
               value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                env[key] = value
            }
        }
    }

    for pair in pairs {
        guard let eq = pair.firstIndex(of: "=") else {
            throw ValidationError("fend: --env expects KEY=VALUE, got '\(pair)'")
        }
        let key = String(pair[pair.startIndex..<eq])
        let value = String(pair[pair.index(after: eq)...])
        env[key] = value
    }

    return env
}
