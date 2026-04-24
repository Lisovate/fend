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
}
