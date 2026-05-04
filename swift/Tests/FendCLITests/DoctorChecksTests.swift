import Foundation
import XCTest
@testable import FendCLI

final class DoctorChecksTests: XCTestCase {
    func testMacReportKeepsExistingRuntimeGuidance() {
        let runtime = URL(fileURLWithPath: "/tmp/fend/runtime")
        let probe = DoctorProbe(
            platform: .macOS,
            osDescription: "macOS 14.0",
            architecture: "arm64",
            runtimeDir: runtime,
            kernelPath: runtime.appendingPathComponent("vmlinuz"),
            initrdPath: runtime.appendingPathComponent("initrd"),
            rootfsPath: runtime.appendingPathComponent("rootfs.img"),
            kernelExists: false,
            initrdExists: true,
            rootfsExists: false,
            dockerAvailable: false,
            configSummary: "node=auto bun=auto cpus=2 mem=2048MB"
        )

        let report = DoctorChecks.evaluate(probe)

        XCTAssertTrue(report.issues.contains("Run scripts/prepare-runtime.sh to build runtime artifacts."))
        XCTAssertTrue(report.issues.contains("Docker is required to build rootfs.img. Install Docker Desktop for Mac."))
        XCTAssertEqual(field("kernel", in: report), "missing")
        XCTAssertEqual(field("initrd", in: report), "/tmp/fend/runtime/initrd")
    }

    func testMacReportPassesWhenArtifactsAndDockerAreAvailable() {
        let runtime = URL(fileURLWithPath: "/tmp/fend/runtime")
        let probe = DoctorProbe(
            platform: .macOS,
            osDescription: "macOS 14.0",
            architecture: "arm64",
            runtimeDir: runtime,
            kernelPath: runtime.appendingPathComponent("vmlinuz"),
            initrdPath: runtime.appendingPathComponent("initrd"),
            rootfsPath: runtime.appendingPathComponent("rootfs.img"),
            kernelExists: true,
            initrdExists: true,
            rootfsExists: true,
            dockerAvailable: true,
            configSummary: "node=auto bun=auto cpus=2 mem=2048MB"
        )

        let report = DoctorChecks.evaluate(probe)

        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(field("docker", in: report), "available")
        XCTAssertEqual(field("rootfs", in: report), "/tmp/fend/runtime/rootfs.img")
    }

    func testUnsupportedPlatformReportDoesNotContainLinuxSpecificChecks() {
        let runtime = URL(fileURLWithPath: "/tmp/fend/runtime")
        let probe = DoctorProbe(
            platform: .other("Linux 6.8"),
            osDescription: "Linux 6.8",
            architecture: "x86_64",
            runtimeDir: runtime,
            kernelPath: runtime.appendingPathComponent("vmlinuz"),
            initrdPath: runtime.appendingPathComponent("initrd"),
            rootfsPath: runtime.appendingPathComponent("rootfs.img"),
            kernelExists: true,
            initrdExists: true,
            rootfsExists: true,
            dockerAvailable: true,
            configSummary: "node=auto bun=auto cpus=2 mem=2048MB"
        )

        let report = DoctorChecks.evaluate(probe)

        XCTAssertEqual(field("platform", in: report), "Linux 6.8")
        XCTAssertTrue(report.issues.contains("This host platform is not supported by the Swift macOS CLI."))
        XCTAssertNil(field("qemu", in: report))
        XCTAssertNil(field("/dev/kvm", in: report))
    }

    private func field(_ name: String, in report: DoctorReport) -> String? {
        report.fields.first { $0.0 == name }?.1
    }
}
