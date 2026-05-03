import Foundation

/// Resolve the Node.js version to use and ensure it's downloaded.
/// Priority: .fend.toml runtime.node > .node-version/.nvmrc > package.json engines.node > host's node version
public func resolveNodeRuntime(config: FendConfig, projectDir: URL, paths: FendPaths) throws -> URL {
    let version = try resolveNodeVersion(config: config, projectDir: projectDir)
    let nodeDir = paths.nodeDir(version: version)
    let nodeBin = nodeDir.appendingPathComponent("bin/node")

    if FileManager.default.fileExists(atPath: nodeBin.path) {
        return nodeDir
    }

    fputs("fend: downloading Node.js v\(version) for linux-arm64...\n", stderr)
    try downloadNode(version: version, dest: nodeDir)
    fputs("fend: Node.js v\(version) ready\n", stderr)
    return nodeDir
}

func resolveNodeVersion(config: FendConfig, projectDir: URL) throws -> String {
    // 1. From .fend.toml
    if let v = config.runtime.node {
        return try resolveConcreteNodeVersion(v)
    }

    // 2. From .node-version or .nvmrc
    for file in [".node-version", ".nvmrc"] {
        let path = projectDir.appendingPathComponent(file)
        if let content = try? String(contentsOf: path, encoding: .utf8) {
            let v = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty {
                return try resolveConcreteNodeVersion(v)
            }
        }
    }

    // 3. From package.json engines.node
    if let requirement = nodeEngineRequirement(in: projectDir) {
        if let host = hostNodeVersion(),
           let hostSemver = SemVer(host),
           versionSatisfies(hostSemver, requirement: requirement) {
            return host
        }
        return try resolveLatestNodeVersion(matching: requirement, preferLTS: true)
    }

    // 4. From host's node
    if let host = hostNodeVersion() {
        return host
    }

    throw FendError.missingRuntime("No Node.js found. Install Node.js or set runtime.node in .fend.toml")
}

func hostNodeVersion() -> String? {
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["node", "--version"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
    } catch {
        return nil
    }
    task.waitUntilExit()
    guard task.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return nil }
    let v = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
    return v.isEmpty ? nil : normalizeNodeVersion(v)
}

/// Normalize a user-facing version token by trimming whitespace and a leading
/// "v". Partial versions are resolved later against nodejs.org's dist index.
func normalizeNodeVersion(_ v: String) -> String {
    var value = v.trimmingCharacters(in: .whitespacesAndNewlines)
    if value.hasPrefix("v") || value.hasPrefix("V") {
        value.removeFirst()
    }
    return value
}

func resolveConcreteNodeVersion(_ requested: String) throws -> String {
    let normalized = normalizeNodeVersion(requested)
    if isFullSemver(normalized) {
        return normalized
    }
    return try resolveLatestNodeVersion(matching: normalized)
}

func nodeEngineRequirement(in projectDir: URL) -> String? {
    let packageJSON = projectDir.appendingPathComponent("package.json")
    guard let data = try? Data(contentsOf: packageJSON),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let engines = json["engines"] as? [String: Any],
          let node = engines["node"] as? String else {
        return nil
    }
    let trimmed = node.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
}

func resolveLatestNodeVersion(matching requirement: String, preferLTS: Bool = false) throws -> String {
    let index = try fetchNodeIndex()
    if let version = selectLatestNodeVersion(matching: requirement, in: index, preferLTS: preferLTS) {
        return version
    }
    throw FendError.missingRuntime("No Node.js release matches requirement '\(requirement)'")
}

struct NodeDistVersion: Decodable {
    let version: String
    let lts: NodeLTS

    init(version: String, lts: NodeLTS = .none) {
        self.version = version
        self.lts = lts
    }
}

enum NodeLTS: Decodable, Equatable {
    case none
    case codename(String)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Bool.self), value == false {
            self = .none
        } else if let value = try? container.decode(String.self) {
            self = .codename(value)
        } else {
            self = .none
        }
    }

    var isLTS: Bool {
        if case .codename = self { return true }
        return false
    }
}

func fetchNodeIndex() throws -> [NodeDistVersion] {
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    task.arguments = ["-fsSL", "https://nodejs.org/dist/index.json"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()

    guard task.terminationStatus == 0 else {
        throw FendError.missingRuntime("Failed to fetch Node.js release index from nodejs.org")
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return try JSONDecoder().decode([NodeDistVersion].self, from: data)
}

func selectLatestNodeVersion(
    matching requirement: String,
    in index: [NodeDistVersion],
    preferLTS: Bool = false
) -> String? {
    let normalized = normalizeNodeVersion(requirement)
    let matches = index
        .compactMap { entry -> (raw: String, version: SemVer, isLTS: Bool)? in
            guard !entry.version.contains("-"),
                  let version = SemVer(entry.version) else {
                return nil
            }
            return (normalizeNodeVersion(entry.version), version, entry.lts.isLTS)
        }
        .filter { versionSatisfies($0.version, requirement: normalized) }

    let preferred = preferLTS ? matches.filter(\.isLTS) : []
    let candidates = preferred.isEmpty ? matches : preferred
    return candidates
        .max { $0.version < $1.version }?
        .raw
}

private func isFullSemver(_ value: String) -> Bool {
    let parts = value.split(separator: ".")
    return parts.count == 3 && parts.allSatisfy { Int($0) != nil }
}

private struct SemVer: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    init(_ major: Int, _ minor: Int, _ patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(_ raw: String) {
        let normalized = normalizeNodeVersion(raw)
        guard !normalized.contains("-") else { return nil }
        let core = normalized.split(separator: "+", maxSplits: 1).first ?? Substring(normalized)
        let parts = core.split(separator: ".")
        guard (1...3).contains(parts.count),
              let major = Int(parts[0]) else {
            return nil
        }
        let minor = parts.count > 1 ? Int(parts[1]) : 0
        let patch = parts.count > 2 ? Int(parts[2]) : 0
        guard let minor, let patch else { return nil }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    static func < (lhs: SemVer, rhs: SemVer) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }
}

private struct PartialSemVer {
    let major: Int
    let minor: Int?
    let patch: Int?

    var lowerBound: SemVer {
        SemVer(major, minor ?? 0, patch ?? 0)
    }
}

private func versionSatisfies(_ version: SemVer, requirement: String) -> Bool {
    let clauses = requirement.components(separatedBy: "||")
    return clauses.contains { clause in
        let tokens = comparatorTokens(in: clause)
        guard !tokens.isEmpty else { return false }
        return tokens.allSatisfy { comparator($0, accepts: version) }
    }
}

private func comparatorTokens(in clause: String) -> [String] {
    let raw = clause
        .split(whereSeparator: { $0.isWhitespace })
        .map(String.init)
    var tokens: [String] = []
    var i = 0
    while i < raw.count {
        if [">=", "<=", ">", "<", "="].contains(raw[i]), i + 1 < raw.count {
            tokens.append(raw[i] + raw[i + 1])
            i += 2
        } else {
            tokens.append(raw[i])
            i += 1
        }
    }
    return tokens
}

private func comparator(_ rawToken: String, accepts version: SemVer) -> Bool {
    var token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, token != "*" else { return true }
    if token.hasPrefix("v") || token.hasPrefix("V") {
        token.removeFirst()
    }

    if token.hasPrefix("^") {
        guard let base = parsePartialSemVer(String(token.dropFirst())) else { return false }
        let lower = base.lowerBound
        let upper: SemVer
        if base.major > 0 {
            upper = SemVer(base.major + 1, 0, 0)
        } else if let minor = base.minor, minor > 0 {
            upper = SemVer(0, minor + 1, 0)
        } else {
            upper = SemVer(0, 0, (base.patch ?? 0) + 1)
        }
        return version >= lower && version < upper
    }

    if token.hasPrefix("~") {
        guard let base = parsePartialSemVer(String(token.dropFirst())) else { return false }
        let lower = base.lowerBound
        let upper = base.minor == nil
            ? SemVer(base.major + 1, 0, 0)
            : SemVer(base.major, (base.minor ?? 0) + 1, 0)
        return version >= lower && version < upper
    }

    for op in [">=", "<=", ">", "<", "="] {
        if token.hasPrefix(op) {
            guard let bound = parsePartialSemVer(String(token.dropFirst(op.count)))?.lowerBound else {
                return false
            }
            switch op {
            case ">=": return version >= bound
            case "<=": return version <= bound
            case ">": return version > bound
            case "<": return version < bound
            default: return version == bound
            }
        }
    }

    guard let expected = parsePartialSemVer(token) else { return false }
    if version.major != expected.major { return false }
    if let minor = expected.minor, version.minor != minor { return false }
    if let patch = expected.patch, version.patch != patch { return false }
    return true
}

private func parsePartialSemVer(_ raw: String) -> PartialSemVer? {
    let normalized = normalizeNodeVersion(raw)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !normalized.isEmpty else { return nil }

    let core = normalized.split(separator: "+", maxSplits: 1).first ?? Substring(normalized)
    let parts = core.split(separator: ".", omittingEmptySubsequences: false)
    guard (1...3).contains(parts.count) else { return nil }

    func parsePart(_ part: Substring) -> Int?? {
        let lower = part.lowercased()
        if lower == "x" || lower == "*" { return .some(nil) }
        return Int(part).map { .some($0) } ?? nil
    }

    guard let majorValue = parsePart(parts[0]),
          let major = majorValue else {
        return nil
    }

    var minor: Int?
    var patch: Int?
    if parts.count > 1 {
        guard let minorValue = parsePart(parts[1]) else { return nil }
        minor = minorValue
    }
    if parts.count > 2 {
        guard let patchValue = parsePart(parts[2]) else { return nil }
        patch = patchValue
    }
    return PartialSemVer(major: major, minor: minor, patch: patch)
}

/// Resolve the Bun runtime if the project uses bun (bun.lockb or bunfig.toml present).
/// Returns the bun directory URL if bun is needed, nil otherwise.
public func resolveBunRuntime(config: FendConfig, projectDir: URL, paths: FendPaths) throws -> URL? {
    let hasBunLock = FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("bun.lockb").path)
        || FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("bun.lock").path)
    let hasBunfig = FileManager.default.fileExists(atPath: projectDir.appendingPathComponent("bunfig.toml").path)
    let configuredBun = config.runtime.bun != nil

    guard hasBunLock || hasBunfig || configuredBun else { return nil }

    let version = try resolveBunVersion(config: config)
    let bunDir = paths.bunDir(version: version)
    let bunBin = bunDir.appendingPathComponent("bun")

    if FileManager.default.fileExists(atPath: bunBin.path) {
        return bunDir
    }

    fputs("fend: downloading Bun v\(version) for linux-aarch64...\n", stderr)
    try downloadBun(version: version, dest: bunDir)
    fputs("fend: Bun v\(version) ready\n", stderr)
    return bunDir
}

private func resolveBunVersion(config: FendConfig) throws -> String {
    // 1. From .fend.toml
    if let v = config.runtime.bun {
        return v.replacingOccurrences(of: "v", with: "")
    }

    // 2. From host's bun
    let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
        "/usr/bin/env",
        "\(homeDir)/.bun/bin/bun",
        "/usr/local/bin/bun",
    ]

    for candidate in candidates {
        let pipe = Pipe()
        let task = Process()
        if candidate == "/usr/bin/env" {
            task.executableURL = URL(fileURLWithPath: candidate)
            task.arguments = ["bun", "--version"]
        } else {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            task.executableURL = URL(fileURLWithPath: candidate)
            task.arguments = ["--version"]
        }
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { continue }
        } catch {
            continue
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        if let output = String(data: data, encoding: .utf8) {
            let v = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
            if !v.isEmpty { return v }
        }
    }

    // 3. Default to latest stable
    let defaultVersion = "1.3.9"
    fputs("fend: no host bun found, using default v\(defaultVersion)\n", stderr)
    return defaultVersion
}

private func downloadBun(version: String, dest: URL) throws {
    let fm = FileManager.default
    let zipName = "bun-linux-aarch64"
    let url = URL(string: "https://github.com/oven-sh/bun/releases/download/bun-v\(version)/\(zipName).zip")!

    let tempDir = fm.temporaryDirectory.appendingPathComponent("fend-bun-\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let zipPath = tempDir.appendingPathComponent("\(zipName).zip")

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-fsSL", "-o", zipPath.path, url.absoluteString]
    curl.standardOutput = FileHandle.nullDevice
    curl.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice
    try curl.run()
    curl.waitUntilExit()
    guard curl.terminationStatus == 0 else {
        throw FendError.missingRuntime("Failed to download Bun v\(version) from \(url)")
    }

    let unzip = Process()
    unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    unzip.arguments = ["-q", zipPath.path, "-d", tempDir.path]
    unzip.standardOutput = FileHandle.nullDevice
    unzip.standardError = FileHandle.nullDevice
    try unzip.run()
    unzip.waitUntilExit()
    guard unzip.terminationStatus == 0 else {
        throw FendError.missingRuntime("Failed to extract Bun archive")
    }

    let extracted = tempDir.appendingPathComponent(zipName)
    if fm.fileExists(atPath: dest.path) {
        try fm.removeItem(at: dest)
    }
    try fm.moveItem(at: extracted, to: dest)
}

private func downloadNode(version: String, dest: URL) throws {
    let fm = FileManager.default
    let tarName = "node-v\(version)-linux-arm64"
    let url = URL(string: "https://nodejs.org/dist/v\(version)/\(tarName).tar.xz")!

    let tempDir = fm.temporaryDirectory.appendingPathComponent("fend-node-\(UUID().uuidString)")
    try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: tempDir) }

    let tarPath = tempDir.appendingPathComponent("\(tarName).tar.xz")

    let curl = Process()
    curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    curl.arguments = ["-fsSL", "-o", tarPath.path, url.absoluteString]
    curl.standardOutput = FileHandle.nullDevice
    curl.standardError = FileHandle(forWritingAtPath: "/dev/null") ?? FileHandle.nullDevice
    try curl.run()
    curl.waitUntilExit()
    guard curl.terminationStatus == 0 else {
        throw FendError.missingRuntime("Failed to download Node.js v\(version) from \(url)")
    }

    let tar = Process()
    tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    tar.arguments = ["xf", tarPath.path, "-C", tempDir.path]
    try tar.run()
    tar.waitUntilExit()
    guard tar.terminationStatus == 0 else {
        throw FendError.missingRuntime("Failed to extract Node.js archive")
    }

    let extracted = tempDir.appendingPathComponent(tarName)
    if fm.fileExists(atPath: dest.path) {
        try fm.removeItem(at: dest)
    }
    try fm.moveItem(at: extracted, to: dest)
}
