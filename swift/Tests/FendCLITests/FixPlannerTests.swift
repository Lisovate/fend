import XCTest
@testable import FendCLI

/// Helpers for building test fixtures. Keeps the test bodies focused on the
/// behavior under test, not on advisory boilerplate.
private func adv(
    _ id: String,
    severity: String = "high",
    fixed: [String] = []
) -> Advisory {
    Advisory(
        id: id,
        summary: "summary for \(id)",
        severity: severity,
        source: "osv",
        url: nil,
        fixedVersions: fixed
    )
}

private func report(
    findings: [(LockedPackage, [Advisory])],
    total: Int? = nil
) -> AuditReport {
    AuditReport(
        totalPackages: total ?? findings.count,
        findings: findings,
        decision: .approved
    )
}

/// Write a throwaway package.json into a unique temp dir and return its URL.
/// Caller is responsible for cleanup if they care; the OS prunes the temp dir.
private func tempProject(deps: [String: String] = [:],
                         devDeps: [String: String] = [:],
                         overrides: [String: String]? = nil) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("fend-test-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    var json: [String: Any] = [
        "name": "fixture",
        "dependencies": deps,
        "devDependencies": devDeps,
    ]
    if let overrides { json["overrides"] = overrides }
    let data = try! JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
    try! data.write(to: dir.appendingPathComponent("package.json"))
    return dir
}

final class FixPlannerTests: XCTestCase {

    // MARK: - compute()

    func testEmptyReportProducesEmptyPlan() {
        let plan = FixPlanner.compute(
            report: report(findings: [], total: 5),
            projectDir: tempProject(),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertTrue(plan.isEmpty)
        XCTAssertFalse(plan.hasSafe)
        XCTAssertEqual(plan.safeCount, 0)
    }

    func testDirectDepInRangeBumpGoesToSafeDirect() {
        let pkg = LockedPackage(name: "left-pad", version: "1.0.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-x", fixed: ["1.0.5"])])]),
            projectDir: tempProject(deps: ["left-pad": "^1.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.safeDirect.count, 1)
        XCTAssertEqual(plan.safeDirect.first?.targetVersion, "1.0.5")
        XCTAssertEqual(plan.safeDirect.first?.kind, .direct)
        XCTAssertTrue(plan.safeOverride.isEmpty)
    }

    func testTransitiveDepGoesToSafeOverride() {
        let pkg = LockedPackage(name: "minimist", version: "1.2.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-y", fixed: ["1.2.6"])])]),
            projectDir: tempProject(deps: ["express": "^4.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.safeOverride.count, 1)
        XCTAssertEqual(plan.safeOverride.first?.kind, .transitive)
        XCTAssertTrue(plan.safeDirect.isEmpty)
    }

    func testMajorBumpGoesToBreakingByDefault() {
        let pkg = LockedPackage(name: "lodash", version: "3.10.1")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-z", fixed: ["4.17.21"])])]),
            projectDir: tempProject(deps: ["lodash": "^3.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.breaking.count, 1)
        XCTAssertEqual(plan.breaking.first?.targetVersion, "4.17.21")
        XCTAssertTrue(plan.safeDirect.isEmpty)
    }

    func testMajorBumpGoesToSafeWhenAllowBreakingTrue() {
        let pkg = LockedPackage(name: "lodash", version: "3.10.1")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-z", fixed: ["4.17.21"])])]),
            projectDir: tempProject(deps: ["lodash": "^3.0.0"]),
            includePrerelease: false,
            allowBreaking: true
        )
        XCTAssertEqual(plan.safeDirect.count, 1)
        XCTAssertTrue(plan.breaking.isEmpty)
    }

    func testPrereleaseGoesToPrereleaseBucketByDefault() {
        let pkg = LockedPackage(name: "alpha", version: "1.0.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-pre", fixed: ["1.0.1-rc.1"])])]),
            projectDir: tempProject(deps: ["alpha": "^1.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.prerelease.count, 1)
        XCTAssertEqual(plan.prerelease.first?.targetVersion, "1.0.1-rc.1")
        XCTAssertTrue(plan.safeDirect.isEmpty)
    }

    func testPrereleaseGoesToSafeWhenIncludePrereleaseTrue() {
        let pkg = LockedPackage(name: "alpha", version: "1.0.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-pre", fixed: ["1.0.1-rc.1"])])]),
            projectDir: tempProject(deps: ["alpha": "^1.0.0"]),
            includePrerelease: true,
            allowBreaking: false
        )
        XCTAssertEqual(plan.safeDirect.count, 1)
        XCTAssertTrue(plan.prerelease.isEmpty)
    }

    func testNoForwardFixGoesToNoFix() {
        let pkg = LockedPackage(name: "doomed", version: "2.0.0")
        let plan = FixPlanner.compute(
            // Only "fix" is older than current — nothing to upgrade to.
            report: report(findings: [(pkg, [adv("GHSA-old", fixed: ["1.9.9"])])]),
            projectDir: tempProject(deps: ["doomed": "^2.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.noFix.count, 1)
        XCTAssertEqual(plan.noFix.first?.0.name, "doomed")
        XCTAssertTrue(plan.safeDirect.isEmpty)
    }

    func testNoFixedVersionsGoesToNoFix() {
        let pkg = LockedPackage(name: "stuck", version: "1.0.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [adv("GHSA-stuck", fixed: [])])]),
            projectDir: tempProject(deps: ["stuck": "^1.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.noFix.count, 1)
    }

    func testMultipleAdvisoriesPickSmallestBumpThatPatchesAll() {
        // pkg@1.0.0; adv-A patched in 1.0.5; adv-B patched in 1.2.0.
        // Target should be 1.2.0 — smallest bump that patches both.
        let pkg = LockedPackage(name: "many", version: "1.0.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [
                adv("GHSA-A", fixed: ["1.0.5", "1.1.0"]),
                adv("GHSA-B", fixed: ["1.2.0"]),
            ])]),
            projectDir: tempProject(deps: ["many": "^1.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.safeDirect.first?.targetVersion, "1.2.0")
        // Both advisory IDs are recorded so the user sees what got fixed.
        XCTAssertEqual(plan.safeDirect.first?.advisoryIds.sorted(), ["GHSA-A", "GHSA-B"])
    }

    func testBackportFixIsPreferredOverDowngrade() {
        // Current is 4.1.0; advisory lists fixes in 2.10.0 (old line) AND 4.5.0
        // (current line). We must pick 4.5.0 — never go down to 2.10.0.
        let pkg = LockedPackage(name: "backport", version: "4.1.0")
        let plan = FixPlanner.compute(
            report: report(findings: [(pkg, [
                adv("GHSA-back", fixed: ["2.10.0", "4.5.0"]),
            ])]),
            projectDir: tempProject(deps: ["backport": "^4.0.0"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.safeDirect.first?.targetVersion, "4.5.0")
    }

    func testBucketsAreSortedAlphabetically() {
        let plan = FixPlanner.compute(
            report: report(findings: [
                (LockedPackage(name: "zeta", version: "1.0.0"),
                 [adv("z", fixed: ["1.0.1"])]),
                (LockedPackage(name: "alpha", version: "1.0.0"),
                 [adv("a", fixed: ["1.0.1"])]),
                (LockedPackage(name: "mid", version: "1.0.0"),
                 [adv("m", fixed: ["1.0.1"])]),
            ]),
            projectDir: tempProject(deps: ["alpha": "^1", "mid": "^1", "zeta": "^1"]),
            includePrerelease: false,
            allowBreaking: false
        )
        XCTAssertEqual(plan.safeDirect.map(\.package.name), ["alpha", "mid", "zeta"])
    }

    // MARK: - compareVersions

    func testCompareVersionsBasic() {
        XCTAssertLessThan(compareVersions("1.0.0", "1.0.1"), 0)
        XCTAssertGreaterThan(compareVersions("2.0.0", "1.99.99"), 0)
        XCTAssertEqual(compareVersions("1.2.3", "1.2.3"), 0)
    }

    func testCompareVersionsHandlesDoubleDigits() {
        // Lexicographic would say "1.10" < "1.2"; numeric gets it right.
        XCTAssertGreaterThan(compareVersions("1.10.0", "1.2.0"), 0)
    }

    func testCompareVersionsPrereleaseSortsBelowRelease() {
        XCTAssertLessThan(compareVersions("1.2.3-rc.1", "1.2.3"), 0)
        XCTAssertGreaterThan(compareVersions("1.2.3", "1.2.3-rc.1"), 0)
    }

    func testCompareVersionsTreatsMissingComponentsAsZero() {
        XCTAssertEqual(compareVersions("1.0", "1.0.0"), 0)
        XCTAssertLessThan(compareVersions("1", "1.0.1"), 0)
    }

    // MARK: - majorsDiffer

    func testMajorsDifferTrueAcrossMajorBoundary() {
        XCTAssertTrue(FixPlanner.majorsDiffer(current: "1.2.3", target: "2.0.0"))
        XCTAssertTrue(FixPlanner.majorsDiffer(current: "0.9.0", target: "1.0.0"))
    }

    func testMajorsDifferFalseWithinSameMajor() {
        XCTAssertFalse(FixPlanner.majorsDiffer(current: "1.2.3", target: "1.99.99"))
        XCTAssertFalse(FixPlanner.majorsDiffer(current: "1.0.0", target: "1.0.0"))
    }

    func testMajorsDifferIgnoresPrereleaseSuffix() {
        XCTAssertFalse(FixPlanner.majorsDiffer(current: "1.0.0", target: "1.0.0-rc.1"))
    }

    // MARK: - worstSeverity

    func testWorstSeverityPicksHighestPriority() {
        XCTAssertEqual(
            FixPlanner.worstSeverity([adv("a", severity: "low"), adv("b", severity: "critical")]),
            "critical"
        )
        XCTAssertEqual(
            FixPlanner.worstSeverity([adv("a", severity: "critical"), adv("b", severity: "malware")]),
            "malware"
        )
    }

    func testWorstSeverityEmptyReturnsUnknown() {
        XCTAssertEqual(FixPlanner.worstSeverity([]), "unknown")
    }

    // MARK: - readDirectDeps

    func testReadDirectDepsCoversAllFourDepKeys() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fend-test-deps-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json: [String: Any] = [
            "dependencies": ["a": "1"],
            "devDependencies": ["b": "1"],
            "peerDependencies": ["c": "1"],
            "optionalDependencies": ["d": "1"],
        ]
        let data = try! JSONSerialization.data(withJSONObject: json)
        try! data.write(to: dir.appendingPathComponent("package.json"))

        let deps = FixPlanner.readDirectDeps(from: dir)
        XCTAssertEqual(deps, ["a", "b", "c", "d"])
    }

    func testReadDirectDepsMissingFileReturnsEmpty() {
        let deps = FixPlanner.readDirectDeps(from: URL(fileURLWithPath: "/nope/nada"))
        XCTAssertTrue(deps.isEmpty)
    }
}
