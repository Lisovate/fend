import ArgumentParser
import Foundation

/// Opt-in subcommand that injects the user's Claude Code OAuth token into the
/// sandbox via `CLAUDE_CODE_OAUTH_TOKEN`. The default `fend <cmd>` path never
/// injects Anthropic credentials — users must invoke `fend claude …` explicitly
/// so it's a conscious action, not a silent leak to every sandboxed process.
struct Claude: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "claude",
        abstract: "Run Claude Code (or any command) with Anthropic credentials injected into the sandbox.",
        discussion: """
            Usage:
              fend claude                 # runs `claude` with OAuth token injected
              fend claude <cmd> [args]    # runs any command with the OAuth token injected

            The token is read from the macOS Keychain entry "Claude Code-credentials".
            Nothing else is staged to the sandbox filesystem — only the env var.
            """
    )

    @Argument(parsing: .captureForPassthrough, help: "Command to run with Claude credentials. Defaults to `claude`.")
    var command: [String] = []

    func run() async throws {
        let cmd = command.isEmpty ? ["claude"] : command
        try await Run.execute(command: cmd, extraEnv: [:], claudeMode: true)
    }
}
