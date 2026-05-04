import Foundation
import XCTest
@testable import FendCLI

final class DoctorChecksTests: XCTestCase {
    func testLinuxReportPassesWhenSpikePrerequisitesArePresent() {
        let probe = linuxProbe(
            kernelExists: true,
            initrdExists: true,
            rootfsExists: true,
            dockerAvailable: true,
            qemuAvailable: true,
            virtiofsdAvailable: true,
            passtAvailable: true,
            kvm: DoctorDeviceStatus(path: "/dev/kvm", exists: true, readable: true, writable: true),
            vhostVsock: DoctorDeviceStatus(path: "/dev/vhost-vsock", exists: true, readable: true, writable: true),
            cpuVirtualizationAvailable: true,
            rustMuslTargetInstalled: true
        )

        let report = DoctorChecks.evaluate(probe)

        XCTAssertTrue(report.issues.isEmpty)
        XCTAssertEqual(field("qemu", in: report), "available")
        XCTAssertEqual(field("/dev/kvm", in: report), "/dev/kvm")
        XCTAssertEqual(field("rust target", in: report), "installed")
    }

    func testLinuxReportExplainsMissingKVMAndRuntimeArtifacts() {
        let probe = linuxProbe(
            architecture: "arm64",
            kernelExists: false,
            initrdExists: false,
            rootfsExists: false,
            dockerAvailable: false,
            qemuAvailable: false,
            virtiofsdAvailable: false,
            passtAvailable: false,
            kvm: DoctorDeviceStatus(path: "/dev/kvm", exists: true, readable: false, writable: false),
            vhostVsock: DoctorDeviceStatus(path: "/dev/vhost-vsock", exists: false, readable: false, writable: false),
            cpuVirtualizationAvailable: false,
            rustMuslTargetInstalled: false
        )

        let report = DoctorChecks.evaluate(probe)

        XCTAssertTrue(report.issues.contains("Linux spike currently requires x86_64."))
        XCTAssertTrue(report.issues.contains("CPU virtualization flags are missing. Enable VT-x/AMD-V or nested virtualization."))
        XCTAssertTrue(report.issues.contains("Install qemu-system-x86_64, for example Arch package qemu-full."))
        XCTAssertTrue(report.issues.contains("Install virtiofsd."))
        XCTAssertTrue(report.issues.contains("Install passt, or launch the spike with FEND_QEMU_NETWORK=user/off."))
        XCTAssertTrue(report.issues.contains("Current user cannot access /dev/kvm. Add the user to the kvm group and log in again."))
        XCTAssertTrue(report.issues.contains("/dev/vhost-vsock is missing. Try: sudo modprobe vhost_vsock."))
        XCTAssertTrue(report.issues.contains("Run scripts/prepare-linux-x86_64-runtime.sh to build Linux runtime artifacts."))
        XCTAssertTrue(report.issues.contains("Docker is required by the current Linux runtime builder."))
        XCTAssertTrue(report.issues.contains("Install Rust target x86_64-unknown-linux-musl before building fendd."))
    }

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
            qemuAvailable: false,
            virtiofsdAvailable: false,
            passtAvailable: false,
            kvm: nil,
            vhostVsock: nil,
            cpuVirtualizationAvailable: nil,
            rustMuslTargetInstalled: nil,
            configSummary: "node=auto bun=auto cpus=2 mem=2048MB"
        )

        let report = DoctorChecks.evaluate(probe)

        XCTAssertTrue(report.issues.contains("Run scripts/prepare-runtime.sh to build runtime artifacts."))
        XCTAssertTrue(report.issues.contains("Docker is required to build rootfs.img. Install Docker Desktop for Mac."))
        XCTAssertEqual(field("kernel", in: report), "missing")
        XCTAssertEqual(field("initrd", in: report), "/tmp/fend/runtime/initrd")
    }

    private func linuxProbe(
        architecture: String = "x86_64",
        kernelExists: Bool,
        initrdExists: Bool,
        rootfsExists: Bool,
        dockerAvailable: Bool,
        qemuAvailable: Bool,
        virtiofsdAvailable: Bool,
        passtAvailable: Bool,
        kvm: DoctorDeviceStatus,
        vhostVsock: DoctorDeviceStatus,
        cpuVirtualizationAvailable: Bool?,
        rustMuslTargetInstalled: Bool?
    ) -> DoctorProbe {
        let runtime = URL(fileURLWithPath: "/home/user/.fend/runtime/linux-x86_64")
        return DoctorProbe(
            platform: .linux,
            osDescription: "Linux 6.8",
            architecture: architecture,
            runtimeDir: runtime,
            kernelPath: runtime.appendingPathComponent("vmlinuz"),
            initrdPath: runtime.appendingPathComponent("initrd"),
            rootfsPath: runtime.appendingPathComponent("rootfs.img"),
            kernelExists: kernelExists,
            initrdExists: initrdExists,
            rootfsExists: rootfsExists,
            dockerAvailable: dockerAvailable,
            qemuAvailable: qemuAvailable,
            virtiofsdAvailable: virtiofsdAvailable,
            passtAvailable: passtAvailable,
            kvm: kvm,
            vhostVsock: vhostVsock,
            cpuVirtualizationAvailable: cpuVirtualizationAvailable,
            rustMuslTargetInstalled: rustMuslTargetInstalled,
            configSummary: "node=auto bun=auto cpus=2 mem=2048MB"
        )
    }

    private func field(_ name: String, in report: DoctorReport) -> String? {
        report.fields.first { $0.0 == name }?.1
    }
}
