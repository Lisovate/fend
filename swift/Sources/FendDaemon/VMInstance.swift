import Foundation
@preconcurrency import Virtualization
import FendCommon

/// Represents a single VM instance backed by Apple Virtualization.framework.
/// Thread-safe: state, isReady, lastUsed protected by stateLock (Phase 2A/2E/2F).
public final class VMInstance: NSObject, VZVirtualMachineDelegate, @unchecked Sendable {
    public enum State: String {
        case booting
        case running
        case paused
        case stopped
        case error
    }

    public let projectDir: URL
    public let startTime: Date

    // Thread-safe state (Phase 2A/2E/2F)
    private let stateLock = NSLock()
    private var _state: State = .stopped
    private var _isReady = false
    private var _lastUsed: Date

    public var state: State {
        get { stateLock.withLock { _state } }
        set { stateLock.withLock { _state = newValue } }
    }

    public var isReady: Bool {
        get { stateLock.withLock { _isReady } }
        set { stateLock.withLock { _isReady = newValue } }
    }

    public var lastUsed: Date {
        get { stateLock.withLock { _lastUsed } }
        set { stateLock.withLock { _lastUsed = newValue } }
    }

    public private(set) var portForwarder: PortForwarder?

    private let config: FendConfig
    private let paths: FendPaths
    private var vm: VZVirtualMachine?
    private let vmQueue = DispatchQueue(label: "sh.fend.vm")

    /// Pipes for serial console I/O. Must be retained for VM lifetime.
    private let consoleReadPipe = Pipe()
    private let consoleWritePipe = Pipe()

    /// Path to the per-project rootfs clone used by this VM.
    private var projectRootfsURL: URL?

    public init(projectDir: URL, config: FendConfig, paths: FendPaths) throws {
        self.projectDir = projectDir
        self.config = config
        self.paths = paths
        self.startTime = Date()
        self._lastUsed = Date()
        super.init()
    }

    /// Boot the VM using Apple Virtualization.framework.
    public func start() async throws {
        state = .booting

        let kernelURL = paths.runtimeDir.appendingPathComponent("vmlinuz")
        let initrdURL = paths.runtimeDir.appendingPathComponent("initrd")

        guard FileManager.default.fileExists(atPath: kernelURL.path) else {
            throw FendError.missingRuntime("Kernel not found at \(kernelURL.path). Run: scripts/prepare-runtime.sh")
        }
        guard FileManager.default.fileExists(atPath: initrdURL.path) else {
            throw FendError.missingRuntime("Initrd not found at \(initrdURL.path). Run: scripts/prepare-runtime.sh")
        }

        let rootfsURL = paths.rootfsImagePath
        guard FileManager.default.fileExists(atPath: rootfsURL.path) else {
            throw FendError.missingRuntime("rootfs.img not found at \(rootfsURL.path). Run: scripts/prepare-runtime.sh")
        }

        // Create per-project APFS clone of rootfs.img
        let projectHash = FendPaths.projectHash(for: projectDir)
        let clonedRootfs = paths.projectRootfsPath(hash: projectHash)
        let cloneDir = clonedRootfs.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: cloneDir, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: clonedRootfs.path) {
            let result = Darwin.clonefile(
                rootfsURL.path,
                clonedRootfs.path,
                0
            )
            if result != 0 {
                try FileManager.default.copyItem(at: rootfsURL, to: clonedRootfs)
            }
        }
        self.projectRootfsURL = clonedRootfs

        // Sidecar that lets the GC pass reverse the project hash back to a path.
        let projectPathFile = paths.projectPathFile(hash: projectHash)
        try? projectDir.standardizedFileURL.path.write(
            to: projectPathFile, atomically: true, encoding: .utf8
        )

        // Resolve runtimes
        let _ = try resolveNodeRuntime(config: config, projectDir: projectDir, paths: paths)
        let _ = try? resolveBunRuntime(config: config, projectDir: projectDir, paths: paths)

        // Boot loader
        let bootloader = VZLinuxBootLoader(kernelURL: kernelURL)
        bootloader.initialRamdiskURL = initrdURL
        let epoch = Int(Date().timeIntervalSince1970)
        let cwdB64 = Data(projectDir.path.utf8).base64EncodedString()
        bootloader.commandLine = "console=hvc0 quiet fend.epoch=\(epoch) fend.cwd=\(cwdB64)"

        // Serial console
        let serialPort = VZVirtioConsoleDeviceSerialPortConfiguration()
        serialPort.attachment = VZFileHandleSerialPortAttachment(
            fileHandleForReading: consoleWritePipe.fileHandleForReading,
            fileHandleForWriting: consoleReadPipe.fileHandleForWriting
        )

        // Network
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()

        // VirtioFS — project directory
        let projectShare = VZSharedDirectory(url: projectDir, readOnly: false)
        let projectFS = VZVirtioFileSystemDeviceConfiguration(tag: "workspace")
        projectFS.share = VZSingleDirectoryShare(directory: projectShare)

        // VirtioFS — npm cache
        let npmCacheDir = paths.cacheDir.appendingPathComponent("npm")
        try FileManager.default.createDirectory(at: npmCacheDir, withIntermediateDirectories: true)
        let cacheShare = VZSharedDirectory(url: npmCacheDir, readOnly: false)
        let cacheFS = VZVirtioFileSystemDeviceConfiguration(tag: "cache")
        cacheFS.share = VZSingleDirectoryShare(directory: cacheShare)

        // VirtioFS — tools
        let toolsShare = VZSharedDirectory(url: paths.toolsDir, readOnly: true)
        let toolsFS = VZVirtioFileSystemDeviceConfiguration(tag: "tools")
        toolsFS.share = VZSingleDirectoryShare(directory: toolsShare)

        // Claude Code credentials are NEVER staged into the sandbox automatically.
        // If the user wants Claude inside the sandbox, `fend claude …` injects
        // CLAUDE_CODE_OAUTH_TOKEN via env only — no config files touch the VM FS.
        let dirShares: [VZVirtioFileSystemDeviceConfiguration] = [projectFS, cacheFS, toolsFS]

        // Block device
        let diskAttachment = try VZDiskImageStorageDeviceAttachment(url: clonedRootfs, readOnly: false)
        let blockDevice = VZVirtioBlockDeviceConfiguration(attachment: diskAttachment)

        // Vsock
        let socketConfig = VZVirtioSocketDeviceConfiguration()

        // Assemble VM configuration
        let vmConfig = VZVirtualMachineConfiguration()
        vmConfig.bootLoader = bootloader
        vmConfig.cpuCount = max(config.vm.cpus, VZVirtualMachineConfiguration.minimumAllowedCPUCount)
        vmConfig.memorySize = max(config.vm.memoryMB * 1024 * 1024, VZVirtualMachineConfiguration.minimumAllowedMemorySize)
        vmConfig.serialPorts = [serialPort]
        vmConfig.networkDevices = [networkDevice]
        vmConfig.storageDevices = [blockDevice]
        vmConfig.directorySharingDevices = dirShares
        vmConfig.socketDevices = [socketConfig]
        vmConfig.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        vmConfig.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        try vmConfig.validate()

        // Tee VM console output into a per-project log file so fendd
        // diagnostics (network events, mount failures, etc.) are visible
        // without streaming them back to the user's terminal by default.
        let vmLogDir = paths.logsDir.appendingPathComponent(projectHash)
        try? FileManager.default.createDirectory(at: vmLogDir, withIntermediateDirectories: true)
        let vmLogPath = vmLogDir.appendingPathComponent("vm.log")
        let vmLogFd = open(vmLogPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        consoleReadPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            if vmLogFd >= 0 {
                data.withUnsafeBytes { buf in
                    _ = Darwin.write(vmLogFd, buf.baseAddress, data.count)
                }
            }
        }

        // Create and start the VM on the dedicated queue
        let virtualMachine: VZVirtualMachine = try await withCheckedThrowingContinuation { continuation in
            vmQueue.async {
                let machine = VZVirtualMachine(configuration: vmConfig, queue: self.vmQueue)
                machine.delegate = self
                continuation.resume(returning: machine)
            }
        }
        self.vm = virtualMachine

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                virtualMachine.start { result in
                    switch result {
                    case .success:
                        self.state = .running
                        continuation.resume()
                    case .failure(let error):
                        self.state = .error
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Wait for fendd to be reachable over vsock. Probes the command port
    /// until it accepts, then disconnects — the real connection happens in
    /// the next `connectToGuest` call from the daemon/direct run path.
    public func waitForReady(timeout: TimeInterval = 15) async throws {
        if isReady { return }

        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Error?

        while Date() < deadline {
            do {
                let probe = try await connectToGuest(port: vsockPort)
                // Force release — dropping the reference closes the underlying fd.
                _ = probe
                isReady = true
                break
            } catch {
                lastError = error
                try await Task.sleep(nanoseconds: 200_000_000) // 200ms
            }
        }

        if !isReady {
            let detail = lastError.map { String(describing: $0) } ?? "no successful connect"
            throw FendError.timeout("fendd vsock unreachable after \(Int(timeout))s: \(detail)")
        }

        // Start port forwarding monitor
        if portForwarder == nil {
            let pf = PortForwarder(vm: self)
            portForwarder = pf
            pf.startMonitoring()
        }
    }

    /// Connect to the guest agent (fendd) over vsock.
    public func connectToGuest(port: UInt32) async throws -> VZVirtioSocketConnection {
        guard state == .running, let vm else {
            throw FendError.vmNotRunning
        }

        guard let device = vm.socketDevices.first as? VZVirtioSocketDevice else {
            throw FendError.vmNotRunning
        }

        return try await withCheckedThrowingContinuation { continuation in
            vmQueue.async {
                device.connect(toPort: port) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    /// Pause the VM.
    public func pause() async throws {
        guard state == .running, let vm else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                vm.pause { result in
                    switch result {
                    case .success:
                        self.state = .paused
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Resume a paused VM.
    public func resume() async throws {
        guard state == .paused, let vm else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            vmQueue.async {
                vm.resume { result in
                    switch result {
                    case .success:
                        self.state = .running
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Force-stop the VM immediately.
    public func forceStop() {
        portForwarder?.stopAll()
        portForwarder = nil

        guard let vm else { return }
        vmQueue.async {
            do {
                try vm.requestStop()
            } catch {
                // VM may already be stopped
            }
        }
        state = .stopped
        consoleReadPipe.fileHandleForReading.readabilityHandler = nil
        self.vm = nil
    }

    // MARK: - VZVirtualMachineDelegate

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        state = .stopped
        consoleReadPipe.fileHandleForReading.readabilityHandler = nil
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        state = .error
        consoleReadPipe.fileHandleForReading.readabilityHandler = nil
        fputs("fend: vm error — \(error.localizedDescription)\n", stderr)
    }
}
