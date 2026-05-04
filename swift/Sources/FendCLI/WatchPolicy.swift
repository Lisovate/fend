import ArgumentParser
import Foundation
import FendCommon

enum WatchHostOS {
    case linux
    case macOS
    case other

    static var current: WatchHostOS {
        #if os(Linux)
        return .linux
        #elseif os(macOS)
        return .macOS
        #else
        return .other
        #endif
    }
}

struct WatchPlan: Equatable {
    let requestedMode: WatchMode
    let effectiveMode: WatchMode
    let pollIntervalMs: Int

    var usesPolling: Bool {
        effectiveMode == .polling
    }

    var auditValue: String {
        effectiveMode.rawValue
    }
}

enum WatchPolicy {
    static func resolve(
        requestedMode: WatchMode,
        command: [String],
        pollIntervalMs: Int,
        hostOS: WatchHostOS = .current
    ) throws -> WatchPlan {
        if requestedMode == .mirror {
            throw ValidationError("watch mode 'mirror' is planned but not implemented yet; use 'auto', 'native', or 'polling'")
        }

        let effectiveMode: WatchMode
        switch requestedMode {
        case .auto:
            effectiveMode = hostOS == .linux && isLikelyDevCommand(command) ? .polling : .native
        case .native:
            effectiveMode = .native
        case .polling:
            effectiveMode = .polling
        case .mirror:
            effectiveMode = .mirror
        }

        return WatchPlan(
            requestedMode: requestedMode,
            effectiveMode: effectiveMode,
            pollIntervalMs: pollIntervalMs
        )
    }

    static func apply(_ plan: WatchPlan, to env: inout [String: String]) {
        env["FEND_WATCH_MODE"] = plan.auditValue
        if plan.usesPolling {
            env["FEND_WATCH_POLL_INTERVAL_MS"] = "\(plan.pollIntervalMs)"
            env["CHOKIDAR_USEPOLLING"] = "true"
            env["CHOKIDAR_INTERVAL"] = "\(plan.pollIntervalMs)"
            env["WATCHPACK_POLLING"] = "true"
        }
    }

    static func isLikelyDevCommand(_ command: [String]) -> Bool {
        guard let firstRaw = command.first else { return false }
        let first = basename(firstRaw)
        let args = Array(command.dropFirst())

        switch first {
        case "vite", "astro", "nuxt", "nodemon", "webpack-dev-server":
            return true
        case "next":
            return args.first == "dev"
        case "webpack":
            return args.contains("serve") || args.contains("--watch")
        case "npm":
            return scriptAfterRun(in: args).map(isDevScriptName) ?? false
        case "pnpm", "yarn", "bun":
            if let script = scriptAfterRun(in: args), isDevScriptName(script) {
                return true
            }
            return directScript(in: args).map(isDevScriptName) ?? false
        case "bunx", "npx":
            return args.first(where: { $0 != "--" && !$0.hasPrefix("-") })
                .map { isKnownDevTool(basename($0)) } ?? false
        default:
            return isKnownDevTool(first)
        }
    }

    private static func isKnownDevTool(_ name: String) -> Bool {
        ["vite", "astro", "nuxt", "nodemon", "webpack-dev-server"].contains(name)
    }

    private static func isDevScriptName(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return normalized == "dev"
            || normalized == "watch"
            || normalized == "serve"
            || normalized.hasPrefix("dev:")
            || normalized.hasSuffix(":dev")
    }

    private static func scriptAfterRun(in args: [String]) -> String? {
        guard let runIndex = args.firstIndex(where: { $0 == "run" || $0 == "run-script" }) else {
            return nil
        }
        return args.dropFirst(runIndex + 1).first(where: { arg in
            arg != "--" && !arg.hasPrefix("-")
        })
    }

    private static func directScript(in args: [String]) -> String? {
        let blockedSubcommands: Set<String> = [
            "add", "audit", "ci", "dlx", "exec", "install", "remove", "rebuild",
            "unlink", "update", "upgrade"
        ]
        let tokens = args.filter { $0 != "--" && !$0.hasPrefix("-") }
        guard let first = tokens.first else { return nil }
        if blockedSubcommands.contains(first) {
            return nil
        }
        if let script = tokens.first(where: isDevScriptName) {
            return script
        }
        return first
    }

    private static func basename(_ value: String) -> String {
        URL(fileURLWithPath: value).lastPathComponent
    }
}
