import XCTest
@testable import FendCLI

private func tempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fend-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writePackageJSON(_ json: [String: Any], in dir: URL) {
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    try! data.write(to: dir.appendingPathComponent("package.json"))
}

private func readPackageJSON(in dir: URL) -> [String: Any] {
    let url = dir.appendingPathComponent("package.json")
    let data = try! Data(contentsOf: url)
    return try! JSONSerialization.jsonObject(with: data) as! [String: Any]
}

private func makePlan(direct: [(String, String, String)] = [],
                     override: [(String, String, String)] = []) -> FixPlan {
    func item(_ name: String, _ from: String, _ to: String, _ kind: FixKind) -> FixItem {
        FixItem(
            package: LockedPackage(name: name, version: from),
            targetVersion: to,
            advisoryIds: ["GHSA-test"],
            worstSeverity: "high",
            kind: kind
        )
    }
    var plan = FixPlan()
    plan.safeDirect = direct.map { item($0.0, $0.1, $0.2, .direct) }
    plan.safeOverride = override.map { item($0.0, $0.1, $0.2, .transitive) }
    return plan
}

final class FixApplierTests: XCTestCase {

    // MARK: - writeOverrides

    func testWriteOverridesEmptyPlanIsNoop() throws {
        let dir = tempDir()
        writePackageJSON(["name": "x"], in: dir)
        let result = try FixApplier.writeOverrides(makePlan(), projectDir: dir)
        XCTAssertTrue(result.isEmpty)
    }

    func testWriteOverridesAddsOverridesKeyWhenMissing() throws {
        let dir = tempDir()
        writePackageJSON(["name": "x"], in: dir)

        let plan = makePlan(override: [("minimist", "1.2.0", "1.2.6")])
        let changed = try FixApplier.writeOverrides(plan, projectDir: dir)
        XCTAssertEqual(changed, ["minimist"])

        let json = readPackageJSON(in: dir)
        let overrides = json["overrides"] as? [String: String]
        XCTAssertEqual(overrides?["minimist"], "1.2.6")
    }

    func testWriteOverridesMergesWithExistingOverrides() throws {
        let dir = tempDir()
        writePackageJSON([
            "name": "x",
            "overrides": ["unrelated": "9.9.9"],
        ], in: dir)

        let plan = makePlan(override: [("minimist", "1.2.0", "1.2.6")])
        _ = try FixApplier.writeOverrides(plan, projectDir: dir)

        let json = readPackageJSON(in: dir)
        let overrides = json["overrides"] as? [String: String]
        XCTAssertEqual(overrides?["unrelated"], "9.9.9")
        XCTAssertEqual(overrides?["minimist"], "1.2.6")
    }

    func testWriteOverridesIsIdempotent() throws {
        let dir = tempDir()
        writePackageJSON(["name": "x"], in: dir)

        let plan = makePlan(override: [("a", "1.0.0", "1.0.1")])
        let first = try FixApplier.writeOverrides(plan, projectDir: dir)
        let second = try FixApplier.writeOverrides(plan, projectDir: dir)
        XCTAssertEqual(first, ["a"])
        // Re-running with the same plan should detect that nothing actually
        // changed and return [] — important because the install flow may
        // re-enter this path.
        XCTAssertTrue(second.isEmpty)
    }

    func testWriteOverridesUpdatesValueWhenChanged() throws {
        let dir = tempDir()
        writePackageJSON([
            "name": "x",
            "overrides": ["a": "1.0.0"],
        ], in: dir)

        let plan = makePlan(override: [("a", "1.0.0", "1.0.5")])
        let changed = try FixApplier.writeOverrides(plan, projectDir: dir)
        XCTAssertEqual(changed, ["a"])

        let json = readPackageJSON(in: dir)
        let overrides = json["overrides"] as? [String: String]
        XCTAssertEqual(overrides?["a"], "1.0.5")
    }

    func testWriteOverridesPreservesTrailingNewline() throws {
        let dir = tempDir()
        writePackageJSON(["name": "x"], in: dir)
        _ = try FixApplier.writeOverrides(
            makePlan(override: [("a", "1.0.0", "1.0.1")]),
            projectDir: dir
        )
        let bytes = try Data(contentsOf: dir.appendingPathComponent("package.json"))
        XCTAssertEqual(bytes.last, 0x0A)
    }

    func testWriteOverridesDirectOnlyPlanIsNoop() throws {
        // Direct fixes go through `npm install pkg@target`, not overrides.
        // Plan with only direct items should not write to package.json.
        let dir = tempDir()
        writePackageJSON(["name": "x"], in: dir)
        let plan = makePlan(direct: [("react", "17.0.0", "17.0.2")])
        let result = try FixApplier.writeOverrides(plan, projectDir: dir)
        XCTAssertTrue(result.isEmpty)

        let json = readPackageJSON(in: dir)
        XCTAssertNil(json["overrides"])
    }

    func testWriteOverridesThrowsWhenPackageJSONMissing() {
        let dir = tempDir()
        let plan = makePlan(override: [("a", "1.0.0", "1.0.1")])
        XCTAssertThrowsError(try FixApplier.writeOverrides(plan, projectDir: dir)) { error in
            guard case FixApplyError.missingPackageJSON = error else {
                XCTFail("expected .missingPackageJSON, got \(error)")
                return
            }
        }
    }

    func testWriteOverridesThrowsOnInvalidJSON() throws {
        let dir = tempDir()
        try "not json at all".write(
            to: dir.appendingPathComponent("package.json"),
            atomically: true,
            encoding: .utf8
        )
        let plan = makePlan(override: [("a", "1.0.0", "1.0.1")])
        XCTAssertThrowsError(try FixApplier.writeOverrides(plan, projectDir: dir)) { error in
            guard case FixApplyError.packageJSONUnreadable = error else {
                XCTFail("expected .packageJSONUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - installArgv

    func testInstallArgvEmptyPlanFallsBackToPlainInstall() {
        // Bare `npm install` re-resolves so a freshly-written `overrides`
        // section actually lands in package-lock.json.
        XCTAssertEqual(FixApplier.installArgv(for: makePlan()), ["npm", "install"])
    }

    func testInstallArgvIncludesDirectPins() {
        let plan = makePlan(direct: [
            ("react", "17.0.0", "18.2.0"),
            ("lodash", "3.10.1", "4.17.21"),
        ])
        XCTAssertEqual(
            FixApplier.installArgv(for: plan),
            ["npm", "install", "react@18.2.0", "lodash@4.17.21"]
        )
    }

    func testInstallArgvIgnoresOverrideOnlyPlan() {
        // Overrides land in package.json; argv stays bare so npm re-resolves.
        let plan = makePlan(override: [("minimist", "1.2.0", "1.2.6")])
        XCTAssertEqual(FixApplier.installArgv(for: plan), ["npm", "install"])
    }
}
