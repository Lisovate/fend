import ArgumentParser
import Foundation
import FendCommon
import FendDaemon

@main
struct Fend: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fend",
        abstract: "Fend off risky dependencies. Sandboxed runtime for package installs and dev scripts.",
        version: "0.0.1",
        subcommands: [Run.self, Claude.self, Audit.self, Init.self, Hook.self, On.self, Off.self, Status.self, Stop.self, Clean.self, Doctor.self, Log.self, DaemonCommand.self],
        defaultSubcommand: Run.self
    )
}
