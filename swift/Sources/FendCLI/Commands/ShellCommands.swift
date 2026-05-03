import ArgumentParser
import Foundation

// MARK: - fend hook

struct Hook: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hook",
        abstract: "Output shell integration code",
        discussion: "Add `eval \"$(fend hook zsh)\"` to your .zshrc (or bash equivalent) for shell integration."
    )

    @Argument(help: "Shell type (zsh or bash)")
    var shell: String

    func run() throws {
        switch shell {
        case "zsh":
            print(zshHook)
        case "bash":
            print(bashHook)
        default:
            throw ValidationError("Unsupported shell '\(shell)'. Use 'zsh' or 'bash'.")
        }
    }

    /// Commands we shim — any invocation runs through `fend run <cmd>` when
    /// `fend on` is active. Wider coverage = fewer escape hatches for scripts
    /// that fork to an unwrapped tool, but also more startup overhead, so we
    /// stop at package managers + runtime entry points.
    private static let shimmedCommands = [
        "npm", "npx",
        "bun", "bunx",
        "yarn",
        "pnpm", "pnpx",
        "node",
        "python", "python3",
        "uv", "uvx",
        "deno",
    ]

    private var zshHook: String {
        let cmds = Self.shimmedCommands.joined(separator: " ")
        return """
        # fend shell integration
        _fend_active=0
        _fend_saved_prompt="$PROMPT"

        fend() {
          case "$1" in
            on)
              _fend_active=1
              _fend_saved_prompt="${PROMPT#\\[fend\\] }"
              PROMPT="[fend] $_fend_saved_prompt"
              echo "fend: sandbox active — \(cmds) are sandboxed"
              ;;
            off)
              _fend_active=0
              PROMPT="$_fend_saved_prompt"
              echo "fend: sandbox deactivated"
              ;;
            *)
              command fend "$@"
              ;;
          esac
        }

        for _fend_cmd in \(cmds); do
          eval "${_fend_cmd}() {
            if (( _fend_active )); then
              command fend run ${_fend_cmd} \\"\\$@\\"
            else
              command ${_fend_cmd} \\"\\$@\\"
            fi
          }"
        done
        unset _fend_cmd
        """
    }

    private var bashHook: String {
        let cmds = Self.shimmedCommands.joined(separator: " ")
        return """
        # fend shell integration
        _fend_active=0
        _fend_saved_ps1="$PS1"

        fend() {
          case "$1" in
            on)
              _fend_active=1
              _fend_saved_ps1="${PS1#\\[fend\\] }"
              PS1="[fend] $_fend_saved_ps1"
              echo "fend: sandbox active — \(cmds) are sandboxed"
              ;;
            off)
              _fend_active=0
              PS1="$_fend_saved_ps1"
              echo "fend: sandbox deactivated"
              ;;
            *)
              command fend "$@"
              ;;
          esac
        }

        for _fend_cmd in \(cmds); do
          eval "${_fend_cmd}() {
            if (( _fend_active )); then
              command fend run ${_fend_cmd} \\"\\$@\\"
            else
              command ${_fend_cmd} \\"\\$@\\"
            fi
          }"
        done
        unset _fend_cmd
        """
    }
}

// MARK: - fend on / fend off

struct On: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Activate shell hook — sandbox commands automatically"
    )

    func run() throws {
        fputs("""
            fend: 'fend on' must be run as a shell function, not a binary subcommand.

            Add this to your shell config for shell integration:
              zsh:  eval "$(fend hook zsh)"   # add to ~/.zshrc
              bash: eval "$(fend hook bash)"   # add to ~/.bashrc

            Then use 'fend on' / 'fend off' to toggle sandboxing.

            """, stderr)
        throw ExitCode(1)
    }
}

struct Off: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Deactivate shell hook"
    )

    func run() throws {
        fputs("""
            fend: 'fend off' must be run as a shell function, not a binary subcommand.

            Add this to your shell config for shell integration:
              zsh:  eval "$(fend hook zsh)"   # add to ~/.zshrc
              bash: eval "$(fend hook bash)"   # add to ~/.bashrc

            Then use 'fend on' / 'fend off' to toggle sandboxing.

            """, stderr)
        throw ExitCode(1)
    }
}
