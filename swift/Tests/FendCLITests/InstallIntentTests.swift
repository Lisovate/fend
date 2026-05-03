import XCTest
@testable import FendCLI

final class InstallIntentTests: XCTestCase {

    func testDetectKeepsFlagValuesOutOfPackages() {
        let intent = InstallIntent.detect([
            "npm", "install", "--workspace", "packages/app", "--save-dev", "left-pad",
        ])

        XCTAssertEqual(intent?.extraFlags, ["--workspace", "packages/app", "--save-dev"])
        XCTAssertEqual(intent?.packagesGiven, ["left-pad"])
    }

    func testTwoPhaseCommandQuotesDynamicArguments() {
        let intent = InstallIntent(
            packageManager: "npm",
            subcommand: "install",
            packagesGiven: ["@scope/pkg;touch /tmp/pwn"],
            extraFlags: ["--registry", "https://registry.npmjs.org/?q=a b"]
        )

        XCTAssertEqual(
            intent.twoPhaseCommand(rebuild: true),
            [
                "sh",
                "-c",
                "npm install --registry 'https://registry.npmjs.org/?q=a b' '@scope/pkg;touch /tmp/pwn' --ignore-scripts && npm rebuild '@scope/pkg;touch /tmp/pwn'",
            ]
        )
    }

    func testShellQuoteEscapesSingleQuotes() {
        XCTAssertEqual(shellQuote("a'b"), "'a'\\''b'")
    }

    func testTwoPhaseCommandCanOmitRebuild() {
        let intent = InstallIntent(
            packageManager: "npm",
            subcommand: "ci",
            packagesGiven: [],
            extraFlags: []
        )

        XCTAssertEqual(intent.twoPhaseCommand(rebuild: false), ["sh", "-c", "npm ci --ignore-scripts"])
    }
}
