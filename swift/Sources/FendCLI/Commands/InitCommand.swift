import ArgumentParser
import Foundation

struct Init: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init",
        abstract: "Generate a default .fend.toml for the current project."
    )

    @Flag(name: .long, help: "Overwrite an existing .fend.toml without prompting.")
    var force: Bool = false

    func run() throws {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let target = cwd.appendingPathComponent(".fend.toml")

        if FileManager.default.fileExists(atPath: target.path) && !force {
            TerminalUI.warning(".fend.toml already exists", detail: "pass --force to overwrite")
            throw ExitCode(1)
        }

        let kind = ProjectKind.detect(in: cwd)
        let content = template(for: kind)

        try content.write(to: target, atomically: true, encoding: .utf8)
        TerminalUI.success("wrote .fend.toml", detail: kind.label)
    }

    private func template(for kind: ProjectKind) -> String {
        var lines = [
            "# fend configuration. See https://fend.sh/docs/config for full options.",
            "#",
            "# Detected project type: \(kind.label)",
            "",
            "[runtime]",
        ]

        if let node = kind.nodeVersion {
            lines.append("node = \"\(node)\"")
        }
        if let bun = kind.bunVersion {
            lines.append("bun = \"\(bun)\"")
        }

        lines.append(contentsOf: [
            "",
            "[vm]",
            "# cpus = 2           # uncomment to override (default: 2)",
            "# memory = \"2GB\"     # uncomment to override (default: 2GB)",
            "",
            "[network]",
            "mode = \"on\"                    # on | off",
            "",
            "[watch]",
            "mode = \"auto\"                  # auto | native | polling | mirror",
            "# poll_interval_ms = 500         # used when polling is active",
            "",
            "[audit]",
            "# Audit every install against OSV.dev before running lifecycle scripts.",
            "level = \"strict\"               # strict | warn | off",
            "rebuild = true                  # run `npm rebuild` after a clean/approved audit",
            "auto_approve_in_ci = false      # skip prompts when $CI is set",
            "block = [\"malware\", \"critical\"]  # severities that halt the install",
            "prompt = [\"high\"]               # severities that require y/N confirmation",
            "fix_on_install = true           # offer to apply safe fixes before install",
            "include_prerelease = false      # consider pre-release versions when fixing",
            "",
        ])

        return lines.joined(separator: "\n")
    }
}

private enum ProjectKind {
    case node(String?)
    case bun(String?)
    case pnpm
    case yarn
    case python
    case generic

    static func detect(in dir: URL) -> ProjectKind {
        let fm = FileManager.default
        func has(_ name: String) -> Bool {
            fm.fileExists(atPath: dir.appendingPathComponent(name).path)
        }

        if has("bun.lock") || has("bun.lockb") || has("bunfig.toml") {
            return .bun(nil)
        }
        if has("pnpm-lock.yaml") {
            return .pnpm
        }
        if has("yarn.lock") {
            return .yarn
        }
        if has("package.json") || has("package-lock.json") {
            // Parse package.json's engines.node if present to pin it.
            if let data = try? Data(contentsOf: dir.appendingPathComponent("package.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let engines = json["engines"] as? [String: Any],
               let node = engines["node"] as? String {
                return .node(node)
            }
            return .node(nil)
        }
        if has("requirements.txt") || has("pyproject.toml") || has(".python-version") {
            return .python
        }
        return .generic
    }

    var label: String {
        switch self {
        case .node: return "Node.js"
        case .bun: return "Bun"
        case .pnpm: return "pnpm"
        case .yarn: return "Yarn"
        case .python: return "Python"
        case .generic: return "generic"
        }
    }

    var nodeVersion: String? {
        switch self {
        case .node(let v): return v
        case .pnpm, .yarn: return "20"
        default: return nil
        }
    }

    var bunVersion: String? {
        if case .bun(let v) = self {
            return v ?? nil
        }
        return nil
    }
}
