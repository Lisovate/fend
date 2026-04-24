import Foundation

/// Parsed .fend.toml configuration.
public struct FendConfig {
    public let runtime: RuntimeConfig
    public let vm: VMConfig
    public let audit: AuditConfig

    public init(runtime: RuntimeConfig = .init(), vm: VMConfig = .init(), audit: AuditConfig = .init()) {
        self.runtime = runtime
        self.vm = vm
        self.audit = audit
    }

    /// Load config from a .fend.toml file, or return defaults if not found.
    public static func load(from projectDir: URL) -> FendConfig {
        let configPath = projectDir.appendingPathComponent(".fend.toml")
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return FendConfig()
        }
        return parse(toml: content)
    }

    /// Parse minimal TOML config. Supports [runtime], [vm], and [audit] sections.
    internal static func parse(toml content: String) -> FendConfig {
        var section = ""
        var nodeVersion: String? = nil
        var bunVersion: String? = nil
        var cpus: Int? = nil
        var memoryMB: UInt64? = nil
        var auditLevel: String? = nil
        var auditRebuild: Bool? = nil
        var auditAutoApproveCI: Bool? = nil
        var auditBlockSeverities: [String]? = nil
        var auditPromptSeverities: [String]? = nil
        var auditFixOnInstall: Bool? = nil
        var auditIncludePrerelease: Bool? = nil

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }

            // Key = value
            guard let eqIdx = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[trimmed.startIndex..<eqIdx].trimmingCharacters(in: .whitespaces)
            var value = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespaces)

            // Strip inline comments (only if not inside quotes)
            if let commentIdx = value.firstIndex(of: "#") {
                let beforeComment = value[value.startIndex..<commentIdx]
                let quoteCount = beforeComment.filter { $0 == "\"" }.count
                if quoteCount % 2 == 0 {
                    value = String(beforeComment).trimmingCharacters(in: .whitespaces)
                }
            }

            // Strip quotes
            if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }

            switch (section, key) {
            case ("runtime", "node"): nodeVersion = value
            case ("runtime", "bun"): bunVersion = value
            case ("vm", "cpus"): cpus = Int(value)
            case ("vm", "memory"): memoryMB = parseMemory(value)
            case ("audit", "level"): auditLevel = value
            case ("audit", "rebuild"): auditRebuild = (value.lowercased() == "true")
            case ("audit", "auto_approve_in_ci"): auditAutoApproveCI = (value.lowercased() == "true")
            case ("audit", "block"): auditBlockSeverities = parseArray(value)
            case ("audit", "prompt"): auditPromptSeverities = parseArray(value)
            case ("audit", "fix_on_install"): auditFixOnInstall = (value.lowercased() == "true")
            case ("audit", "include_prerelease"): auditIncludePrerelease = (value.lowercased() == "true")
            default: break
            }
        }

        return FendConfig(
            runtime: RuntimeConfig(node: nodeVersion, bun: bunVersion),
            vm: VMConfig(
                cpus: cpus ?? VMConfig().cpus,
                memoryMB: memoryMB ?? VMConfig().memoryMB
            ),
            audit: AuditConfig(
                level: AuditLevel.parse(auditLevel) ?? AuditConfig().level,
                rebuild: auditRebuild ?? AuditConfig().rebuild,
                autoApproveInCI: auditAutoApproveCI ?? AuditConfig().autoApproveInCI,
                block: auditBlockSeverities ?? AuditConfig().block,
                prompt: auditPromptSeverities ?? AuditConfig().prompt,
                fixOnInstall: auditFixOnInstall ?? AuditConfig().fixOnInstall,
                includePrerelease: auditIncludePrerelease ?? AuditConfig().includePrerelease
            )
        )
    }

    private static func parseArray(_ value: String) -> [String]? {
        var s = value.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("[") && s.hasSuffix("]") else { return nil }
        s = String(s.dropFirst().dropLast())
        return s.split(separator: ",").compactMap {
            var token = $0.trimmingCharacters(in: .whitespaces)
            if token.hasPrefix("\"") && token.hasSuffix("\"") && token.count >= 2 {
                token = String(token.dropFirst().dropLast())
            }
            return token.isEmpty ? nil : token
        }
    }

    private static func parseMemory(_ value: String) -> UInt64? {
        let upper = value.uppercased()
        if upper.hasSuffix("GB") {
            if let n = UInt64(upper.dropLast(2).trimmingCharacters(in: .whitespaces)) {
                return n * 1024
            }
        } else if upper.hasSuffix("MB") {
            return UInt64(upper.dropLast(2).trimmingCharacters(in: .whitespaces))
        }
        return UInt64(value)
    }
}

public struct RuntimeConfig {
    public let node: String?
    public let bun: String?

    public init(node: String? = nil, bun: String? = nil) {
        self.node = node
        self.bun = bun
    }
}

public struct VMConfig {
    public let cpus: Int
    public let memoryMB: UInt64

    public init(cpus: Int = 2, memoryMB: UInt64 = 2048) {
        self.cpus = cpus
        self.memoryMB = memoryMB
    }
}
