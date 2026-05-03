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
        XCTAssertEqual(config.network.mode, .on)
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

    func testDefaultNetworkConfig() {
        let network = NetworkConfig()
        XCTAssertEqual(network.mode, .on)
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

    func testParseTOMLNetwork() {
        let toml = """
        [network]
        mode = "off"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.network.mode, .off)
    }

    func testParseTOMLNetworkAliases() {
        XCTAssertEqual(FendConfig.parse(toml: "[network]\nmode = \"disabled\"").network.mode, .off)
        XCTAssertEqual(FendConfig.parse(toml: "[network]\nmode = \"enabled\"").network.mode, .on)
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

    func testParseDiagnosticsForInvalidValues() {
        let toml = """
        [vm]
        cpus = 0
        memory = "massive"

        [network]
        mode = "blocked"

        [audit]
        rebuild = "sometimes"
        level = "paranoid"
        """

        let result = FendConfig.parseWithDiagnostics(toml: toml)

        XCTAssertEqual(result.config.vm.cpus, 2)
        XCTAssertEqual(result.config.vm.memoryMB, 2048)
        XCTAssertEqual(result.config.network.mode, .on)
        XCTAssertEqual(result.config.audit.rebuild, true)
        XCTAssertEqual(result.config.audit.level, .strict)
        XCTAssertEqual(result.diagnostics.map(\.line), [2, 3, 6, 9, 10])
        XCTAssertTrue(result.diagnostics.map(\.message).contains("invalid network.mode value 'blocked' ignored"))
    }

    func testParseDiagnosticsForUnknownKeysAndSections() {
        let toml = """
        [runtime]
        node = "22"
        python = "3.12"

        [future]
        enabled = true
        """

        let result = FendConfig.parseWithDiagnostics(toml: toml)

        XCTAssertEqual(result.config.runtime.node, "22")
        XCTAssertEqual(result.diagnostics, [
            ConfigDiagnostic(line: 3, message: "unknown key runtime.python ignored"),
            ConfigDiagnostic(line: 5, message: "unknown section [future] ignored"),
        ])
    }

    func testParseTOMLFull() {
        let toml = """
        [runtime]
        node = "22.11.0"
        bun = "1.1.0"

        [vm]
        cpus = 4
        memory = "4GB"

        [network]
        mode = "off"
        """
        let config = FendConfig.parse(toml: toml)
        XCTAssertEqual(config.runtime.node, "22.11.0")
        XCTAssertEqual(config.runtime.bun, "1.1.0")
        XCTAssertEqual(config.vm.cpus, 4)
        XCTAssertEqual(config.vm.memoryMB, 4096)
        XCTAssertEqual(config.network.mode, .off)
    }
}
