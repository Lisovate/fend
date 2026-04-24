import XCTest
@testable import FendCommon

final class ConfigTests: XCTestCase {

    // MARK: - Default values

    func testDefaultConfig() {
        let config = FendConfig()
        XCTAssertNil(config.runtime.node)
        XCTAssertNil(config.runtime.bun)
        XCTAssertEqual(config.vm.cpus, 2)
        XCTAssertEqual(config.vm.memoryMB, 2048)
    }

    func testDefaultRuntimeConfig() {
        let runtime = RuntimeConfig()
        XCTAssertNil(runtime.node)
        XCTAssertNil(runtime.bun)
    }

    func testDefaultVMConfig() {
        let vm = VMConfig()
        XCTAssertEqual(vm.cpus, 2)
        XCTAssertEqual(vm.memoryMB, 2048)
    }

    // MARK: - Load from non-existent file

    func testLoadFromNonExistentReturnsDefaults() {
        let config = FendConfig.load(from: URL(fileURLWithPath: "/nonexistent/path"))
        XCTAssertNil(config.runtime.node)
        XCTAssertNil(config.runtime.bun)
        XCTAssertEqual(config.vm.cpus, 2)
        XCTAssertEqual(config.vm.memoryMB, 2048)
    }

    // MARK: - TOML parsing

    func testParseTOMLRuntime() {
        let toml = """
        [runtime]
        node = "22.11.0"
        bun = "1.1.0"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.runtime.node, "22.11.0")
        XCTAssertEqual(config.runtime.bun, "1.1.0")
    }

    func testParseTOMLVM() {
        let toml = """
        [vm]
        cpus = 4
        memory = "4GB"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.vm.cpus, 4)
        XCTAssertEqual(config.vm.memoryMB, 4096) // 4GB = 4096MB
    }

    func testParseTOMLMemoryMB() {
        let toml = """
        [vm]
        memory = "512MB"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.vm.memoryMB, 512)
    }

    func testParseTOMLMemoryPlainNumber() {
        let toml = """
        [vm]
        memory = 1024
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.vm.memoryMB, 1024)
    }

    func testParseTOMLWithComments() {
        let toml = """
        # This is a comment
        [runtime]
        node = "22" # inline comment

        [vm]
        cpus = 8  # more cores
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.runtime.node, "22")
        XCTAssertEqual(config.vm.cpus, 8)
    }

    func testParseTOMLEmpty() {
        let config = FendConfig.parse(toml: "")
        XCTAssertNil(config.runtime.node)
        XCTAssertEqual(config.vm.cpus, 2)
    }

    func testParseTOMLUnknownSections() {
        let toml = """
        [unknown]
        key = "value"

        [runtime]
        node = "20"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.runtime.node, "20")
    }

    func testParseTOMLFull() {
        let toml = """
        [runtime]
        node = "22.11.0"
        bun = "1.1.0"

        [vm]
        cpus = 4
        memory = "4GB"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.runtime.node, "22.11.0")
        XCTAssertEqual(config.runtime.bun, "1.1.0")
        XCTAssertEqual(config.vm.cpus, 4)
        XCTAssertEqual(config.vm.memoryMB, 4096)
    }
}
