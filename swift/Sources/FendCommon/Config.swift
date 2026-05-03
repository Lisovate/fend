import Foundation

/// Parsed .fend.toml configuration.
public struct FendConfig {
    public let runtime: RuntimeConfig
    public let vm: VMConfig
    public let audit: AuditConfig
    public let network: NetworkConfig

    public init(
        runtime: RuntimeConfig = .init(),
        vm: VMConfig = .init(),
        audit: AuditConfig = .init(),
        network: NetworkConfig = .init()
    ) {
        self.runtime = runtime
        self.vm = vm
        self.audit = audit
        self.network = network
    }

    /// Load config from a .fend.toml file, or return defaults if not found.
    public static func load(from projectDir: URL) -> FendConfig {
        let configPath = projectDir.appendingPathComponent(".fend.toml")
        guard let content = try? String(contentsOf: configPath, encoding: .utf8) else {
            return FendConfig()
        }
        let result = parseWithDiagnostics(toml: content)
        emitDiagnostics(result.diagnostics, path: configPath.path)
        return result.config
    }

    /// Parse minimal TOML config. Supports [runtime], [vm], [audit], and
    /// [network] sections.
    internal static func parse(toml content: String) -> FendConfig {
        parseWithDiagnostics(toml: content).config
    }

    internal static func parseWithDiagnostics(toml content: String) -> ConfigParseResult {
        var section = ""
        var nodeVersion: String? = nil
        var bunVersion: String? = nil
        var cpus: Int? = nil
        var memoryMB: UInt64? = nil
        var networkMode: NetworkMode? = nil
        var auditLevel: AuditLevel? = nil
        var auditRebuild: Bool? = nil
        var auditAutoApproveCI: Bool? = nil
        var auditBlockSeverities: [String]? = nil
        var auditPromptSeverities: [String]? = nil
        var auditFixOnInstall: Bool? = nil
        var auditIncludePrerelease: Bool? = nil
        var diagnostics: [ConfigDiagnostic] = []
        let knownSections: Set<String> = ["runtime", "vm", "network", "audit"]

        for (idx, line) in content.components(separatedBy: .newlines).enumerated() {
            let lineNumber = idx + 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            // Section header
            if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
                section = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if !knownSections.contains(section) {
                    diagnostics.append(ConfigDiagnostic(
                        line: lineNumber,
                        message: "unknown section [\(section)] ignored"
                    ))
                }
                continue
            }

            // Key = value
            guard let eqIdx = trimmed.firstIndex(of: "=") else {
                diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid line ignored"))
                continue
            }
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
            case ("vm", "cpus"):
                if let parsed = Int(value), parsed > 0 {
                    cpus = parsed
                } else {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid vm.cpus value '\(value)' ignored"))
                }
            case ("vm", "memory"):
                if let parsed = parseMemory(value), parsed > 0 {
                    memoryMB = parsed
                } else {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid vm.memory value '\(value)' ignored"))
                }
            case ("network", "mode"):
                if let parsed = NetworkMode.parse(value) {
                    networkMode = parsed
                } else {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid network.mode value '\(value)' ignored"))
                }
            case ("audit", "level"):
                if let parsed = AuditLevel.parse(value) {
                    auditLevel = parsed
                } else {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid audit.level value '\(value)' ignored"))
                }
            case ("audit", "rebuild"):
                auditRebuild = parseBool(value, key: "audit.rebuild", line: lineNumber, diagnostics: &diagnostics)
            case ("audit", "auto_approve_in_ci"):
                auditAutoApproveCI = parseBool(value, key: "audit.auto_approve_in_ci", line: lineNumber, diagnostics: &diagnostics)
            case ("audit", "block"):
                if let parsed = parseArray(value) {
                    auditBlockSeverities = parsed
                } else {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid audit.block array ignored"))
                }
            case ("audit", "prompt"):
                if let parsed = parseArray(value) {
                    auditPromptSeverities = parsed
                } else {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "invalid audit.prompt array ignored"))
                }
            case ("audit", "fix_on_install"):
                auditFixOnInstall = parseBool(value, key: "audit.fix_on_install", line: lineNumber, diagnostics: &diagnostics)
            case ("audit", "include_prerelease"):
                auditIncludePrerelease = parseBool(value, key: "audit.include_prerelease", line: lineNumber, diagnostics: &diagnostics)
            default:
                if knownSections.contains(section) {
                    diagnostics.append(ConfigDiagnostic(line: lineNumber, message: "unknown key \(section).\(key) ignored"))
                }
            }
        }

        let config = FendConfig(
            runtime: RuntimeConfig(node: nodeVersion, bun: bunVersion),
            vm: VMConfig(
                cpus: cpus ?? VMConfig().cpus,
                memoryMB: memoryMB ?? VMConfig().memoryMB
            ),
            audit: AuditConfig(
                level: auditLevel ?? AuditConfig().level,
                rebuild: auditRebuild ?? AuditConfig().rebuild,
                autoApproveInCI: auditAutoApproveCI ?? AuditConfig().autoApproveInCI,
                block: auditBlockSeverities ?? AuditConfig().block,
                prompt: auditPromptSeverities ?? AuditConfig().prompt,
                fixOnInstall: auditFixOnInstall ?? AuditConfig().fixOnInstall,
                includePrerelease: auditIncludePrerelease ?? AuditConfig().includePrerelease
            ),
            network: NetworkConfig(
                mode: networkMode ?? NetworkConfig().mode
            )
        )
        return ConfigParseResult(config: config, diagnostics: diagnostics)
    }

    private static func parseBool(
        _ value: String,
        key: String,
        line: Int,
        diagnostics: inout [ConfigDiagnostic]
    ) -> Bool? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "true": return true
        case "false": return false
        default:
            diagnostics.append(ConfigDiagnostic(line: line, message: "invalid \(key) boolean '\(value)' ignored"))
            return nil
        }
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

    private static func emitDiagnostics(_ diagnostics: [ConfigDiagnostic], path: String) {
        guard !diagnostics.isEmpty else { return }
        for diagnostic in diagnostics {
            let line = "fend: config warning: \(path):\(diagnostic.line): \(diagnostic.message)\n"
            if let data = line.data(using: .utf8) {
                FileHandle.standardError.write(data)
            }
        }
    }
}

public struct ConfigParseResult {
    public let config: FendConfig
    public let diagnostics: [ConfigDiagnostic]
}

public struct ConfigDiagnostic: Equatable {
    public let line: Int
    public let message: String
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

public enum NetworkMode: String, Codable {
    case on
    case off

    public static func parse(_ value: String?) -> NetworkMode? {
        guard let value else { return nil }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "on", "allow", "allowed", "enabled", "true": return .on
        case "off", "deny", "denied", "disabled", "false", "none": return .off
        default: return nil
        }
    }
}

public struct NetworkConfig {
    public let mode: NetworkMode

    public init(mode: NetworkMode = .on) {
        self.mode = mode
    }
}
