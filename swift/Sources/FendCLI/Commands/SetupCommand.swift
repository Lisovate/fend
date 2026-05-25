import ArgumentParser
import Foundation
import FendCommon

/// Idempotent prepare/refresh of the guest runtime artifacts at
/// `~/.fend/runtime/`. Default path fetches a signed prebuilt bundle from
/// this version's GitHub Release. `--build-from-source` switches to the
/// contributor path that runs `swift/scripts/prepare-runtime.sh` locally —
/// slower, requires Docker + a checked-out repo, but produces a runtime
/// without trusting any hosted artifact.
struct Setup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Prepare the guest runtime (~/.fend/runtime/)"
    )

    @Flag(name: .long, help: "Re-download and reinstall even if the runtime is already present at the expected version.")
    var force: Bool = false

    @Flag(name: .long, help: "Build the runtime locally instead of downloading the prebuilt bundle. Slower, requires Docker + a fend repo checkout.")
    var buildFromSource: Bool = false

    func run() throws {
        let paths = FendPaths()
        try paths.ensureDirectories()

        let source: RuntimeSource = buildFromSource ? .fromSource : .prebuilt

        if buildFromSource {
            TerminalUI.warning(
                "building runtime from source",
                detail: "slow (~5–10 min) and requires Docker + a checked-out fend repo"
            )
        }

        do {
            let installed = try RuntimeBootstrap.ensureRuntime(
                paths: paths,
                source: source,
                force: force,
                progress: render
            )
            if !installed {
                TerminalUI.success(
                    "runtime already up to date",
                    detail: "version \(RuntimeManifest.runtimeVersion)"
                )
            } else {
                TerminalUI.blank()
                TerminalUI.success(
                    "runtime ready",
                    detail: paths.runtimeDir.path
                )
            }
        } catch let bootErr as BootstrapError {
            TerminalUI.error("setup failed", detail: bootErr.localizedDescription)
            if case .devBuildNeedsSource = bootErr {
                TerminalUI.hint("run `fend setup --build-from-source` from a fend repo checkout")
            }
            throw ExitCode(1)
        }
    }

    private func render(_ event: BootstrapEvent) {
        switch event {
        case .alreadyPresent(let version):
            TerminalUI.info("runtime already present", detail: "version \(version)")
        case .downloading(let url, let expectedSHA):
            TerminalUI.step("downloading runtime bundle")
            TerminalUI.info("url", detail: url)
            TerminalUI.info("sha256", detail: String(expectedSHA.prefix(16)) + "…")
        case .verifying:
            TerminalUI.step("verifying integrity")
        case .extracting:
            TerminalUI.step("extracting bundle")
        case .installing(let dir):
            TerminalUI.step("installing", detail: dir.path)
        case .warning(let msg):
            TerminalUI.warning(msg)
        case .done:
            break
        }
    }
}
