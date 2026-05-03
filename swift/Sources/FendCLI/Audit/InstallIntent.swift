import Foundation

/// Detected install-class invocation. Lets us route installs through the
/// two-phase audit flow (safe fetch → audit → scripted rebuild) while
/// passing everything else straight through.
struct InstallIntent {
    let packageManager: String     // "npm" | "bun" | "pnpm" | "yarn"
    let subcommand: String         // "install" | "ci" | "add" | "update" | …
    /// True when this invocation takes no explicit package-name arguments
    /// (pure `npm install` / `npm ci`). Used to decide whether rebuild-all
    /// or rebuild-<pkgs> applies after the safe fetch.
    let packagesGiven: [String]
    let extraFlags: [String]

    /// Detect an install intent from argv. Returns nil for non-install commands.
    /// Only npm is fully supported for audit today — other managers get the
    /// two-phase flow skipped with a warning.
    static func detect(_ argv: [String]) -> InstallIntent? {
        guard argv.count >= 2 else { return nil }
        let tool = URL(fileURLWithPath: argv[0]).lastPathComponent
        let knownManagers: Set<String> = ["npm", "bun", "pnpm", "yarn"]
        guard knownManagers.contains(tool) else { return nil }

        let installSubcmds: Set<String> = [
            "install", "i", "add", "ci", "update", "upgrade", "up"
        ]
        let sub = argv[1]
        guard installSubcmds.contains(sub) else { return nil }

        // Split the rest into packages (positional) vs flags. Some flags take
        // a following value; keep that value with the flags so we don't later
        // treat workspace/prefix/registry names as packages to rebuild.
        let rest = Array(argv.dropFirst(2))
        var packages: [String] = []
        var flags: [String] = []
        var i = 0
        while i < rest.count {
            let token = rest[i]
            if token == "--" {
                packages.append(contentsOf: rest.dropFirst(i + 1))
                break
            }
            if token.hasPrefix("-") {
                flags.append(token)
                if flagConsumesNextValue(token), i + 1 < rest.count {
                    flags.append(rest[i + 1])
                    i += 2
                    continue
                }
            } else {
                packages.append(token)
            }
            i += 1
        }

        return InstallIntent(
            packageManager: tool,
            subcommand: sub,
            packagesGiven: packages,
            extraFlags: flags
        )
    }

    /// Only npm has a mature two-phase flow today. Callers gate behavior on
    /// this so the sandbox still works for bun/pnpm/yarn users even without
    /// audit — we just pass their command through unchanged.
    var supportsAudit: Bool { packageManager == "npm" }

    /// Build the shell command that runs the two-phase install:
    ///   `sh -c "npm install <args> --ignore-scripts && npm rebuild [<pkgs>]"`.
    /// When `rebuild` is false (policy off or no postinstalls wanted), omit
    /// the rebuild half so scripts never run automatically.
    func twoPhaseCommand(rebuild: Bool) -> [String] {
        let installPart = shellCommand(
            [packageManager, subcommand] + extraFlags + packagesGiven + ["--ignore-scripts"]
        )
        if !rebuild {
            return ["sh", "-c", installPart]
        }
        let rebuildPart: String
        if packagesGiven.isEmpty {
            rebuildPart = shellCommand([packageManager, "rebuild"])
        } else {
            rebuildPart = shellCommand([packageManager, "rebuild"] + packagesGiven)
        }
        return ["sh", "-c", "\(installPart) && \(rebuildPart)"]
    }

    private static func flagConsumesNextValue(_ token: String) -> Bool {
        guard !token.contains("=") else { return false }
        return [
            "--cache",
            "--globalconfig",
            "--install-strategy",
            "--include",
            "--install-links",
            "--location",
            "--omit",
            "--prefix",
            "--registry",
            "--save-prefix",
            "--tag",
            "--userconfig",
            "--workspace",
            "-w",
        ].contains(token)
    }
}

func shellCommand(_ args: [String]) -> String {
    args.map(shellQuote).joined(separator: " ")
}

func shellQuote(_ arg: String) -> String {
    guard !arg.isEmpty else { return "''" }
    let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-=.,:/@%")
    if arg.unicodeScalars.allSatisfy({ safe.contains($0) }) {
        return arg
    }
    return "'" + arg.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
