import XCTest
@testable import FendCommon

final class RuntimeResolverTests: XCTestCase {

    func testNormalizeNodeVersionFullSemver() {
        XCTAssertEqual(normalizeNodeVersion("22.11.0"), "22.11.0")
    }

    func testNormalizeNodeVersionMajorOnly() {
        XCTAssertEqual(normalizeNodeVersion("22"), "22")
    }

    func testNormalizeNodeVersionMajorMinor() {
        XCTAssertEqual(normalizeNodeVersion("22.11"), "22.11")
    }

    func testNormalizeNodeVersionWithPatch() {
        XCTAssertEqual(normalizeNodeVersion("18.19.1"), "18.19.1")
    }

    func testNormalizeNodeVersionStripsLeadingV() {
        XCTAssertEqual(normalizeNodeVersion("v20.11.1"), "20.11.1")
    }

    func testResolveNodeVersionUsesExactConfigWithoutIndexLookup() throws {
        let version = try resolveNodeVersion(
            config: FendConfig(runtime: RuntimeConfig(node: "v20.11.1")),
            projectDir: FileManager.default.temporaryDirectory
        )
        XCTAssertEqual(version, "20.11.1")
    }

    func testNodeEngineRequirementReadsPackageJSON() throws {
        let dir = try tempProject(packageJSON: #"{"engines":{"node":">=20 <23"}}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(nodeEngineRequirement(in: dir), ">=20 <23")
    }

    func testSelectLatestNodeVersionForMajorOnly() {
        let index = nodeIndex(["v22.0.0", "v22.11.1", "v23.0.0"])
        XCTAssertEqual(selectLatestNodeVersion(matching: "22", in: index), "22.11.1")
    }

    func testSelectLatestNodeVersionForMajorMinor() {
        let index = nodeIndex(["v22.10.4", "v22.11.0", "v22.11.2", "v22.12.0"])
        XCTAssertEqual(selectLatestNodeVersion(matching: "22.11", in: index), "22.11.2")
    }

    func testSelectLatestNodeVersionForEngineRange() {
        let index = nodeIndex(["v18.20.5", "v20.11.1", "v22.14.0", "v23.0.0"])
        XCTAssertEqual(selectLatestNodeVersion(matching: ">=20 <23", in: index), "22.14.0")
    }

    func testSelectLatestNodeVersionForCaretRange() {
        let index = nodeIndex(["v20.9.0", "v20.10.0", "v20.11.1", "v21.0.0"])
        XCTAssertEqual(selectLatestNodeVersion(matching: "^20.10.0", in: index), "20.11.1")
    }

    func testSelectLatestNodeVersionForWildcardRange() {
        let index = nodeIndex(["v20.10.0", "v22.1.0", "v22.4.2", "v23.0.0"])
        XCTAssertEqual(selectLatestNodeVersion(matching: "22.x", in: index), "22.4.2")
    }

    func testSelectLatestNodeVersionCanPreferLTSForBroadEngineRange() {
        let index = [
            NodeDistVersion(version: "v22.14.0", lts: .codename("Jod")),
            NodeDistVersion(version: "v24.2.0", lts: .none),
            NodeDistVersion(version: "v25.0.0", lts: .none),
        ]

        XCTAssertEqual(
            selectLatestNodeVersion(matching: ">=20", in: index, preferLTS: true),
            "22.14.0"
        )
    }

    private func nodeIndex(_ versions: [String]) -> [NodeDistVersion] {
        versions.map { NodeDistVersion(version: $0) }
    }

    private func tempProject(packageJSON: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fend-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try packageJSON.write(to: dir.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        return dir
    }
}
