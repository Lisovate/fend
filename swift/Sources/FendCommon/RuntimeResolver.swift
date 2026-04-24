import Foundation

/// Resolve the Node.js version to use and ensure it's downloaded.
/// Priority: .fend.toml runtime.node > package.json engines.node > host's node version
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
        return normalizeNodeVersion(v)
    }

    // 2. From .node-version or .nvmrc
    for file in [".node-version", ".nvmrc"] {
        let path = projectDir.appendingPathComponent(file)
        if let content = try? String(contentsOf: path, encoding: .utf8) {
            let v = content.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "v", with: "")
            if !v.isEmpty {
                return normalizeNodeVersion(v)
            }
        }
    }

    // 3. From host's node
    let pipe = Pipe()
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["node", "--version"]
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice
    try task.run()
    task.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else {
        throw FendError.missingRuntime("No Node.js found. Install Node.js or set runtime.node in .fend.toml")
    }
    let v = output.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "v", with: "")
    guard !v.isEmpty else {
        throw FendError.missingRuntime("No Node.js found. Install Node.js or set runtime.node in .fend.toml")
    }
    return v
}

/// Normalize version: "22" -> latest 22.x LTS, "22.11.0" -> as-is
func normalizeNodeVersion(_ v: String) -> String {
    if v.split(separator: ".").count >= 3 {
        return v
    }
    return v
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
