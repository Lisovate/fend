import Foundation
import FendCommon

/// Extract Claude Code OAuth access token from macOS Keychain.
/// Returns the access token string, or nil if not found.
func extractClaudeOAuthToken() -> String? {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return nil }
    } catch {
        return nil
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !json.isEmpty else { return nil }

    guard let parsed = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
          let oauth = parsed["claudeAiOauth"] as? [String: Any],
          let accessToken = oauth["accessToken"] as? String else { return nil }

    return accessToken
}

/// Stage full Claude Code credentials JSON to the cache directory for the VM.
func stageClaudeCredentials(paths: FendPaths) {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
    task.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = FileHandle.nullDevice

    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return }
    } catch {
        return
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let json = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
          !json.isEmpty else { return }

    let authDir = paths.cacheDir.appendingPathComponent("claude-auth")
    try? FileManager.default.createDirectory(at: authDir, withIntermediateDirectories: true)
    let credPath = authDir.appendingPathComponent(".credentials.json")
    try? json.write(to: credPath, atomically: true, encoding: .utf8)
}
