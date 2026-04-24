import Foundation
@preconcurrency import Virtualization
import FendCommon

/// The fend daemon manages VM lifecycles, one VM per project directory.
/// It listens on a Unix domain socket for CLI requests and relays
/// commands to fendd inside the VM.
public final class Daemon {
    private let paths: FendPaths
    private let vmManager: VMManager
    private var listenFd: Int32 = -1
    private var timers: [DispatchSourceTimer] = []

    /// How long a VM stays warm before we pause it (seconds).
    private let pauseAfter: TimeInterval = 300 // 5 minutes
    /// How long a paused VM sits idle before we stop it entirely.
    private let stopAfter: TimeInterval = 1800 // 30 minutes

    public init(paths: FendPaths = FendPaths()) {
        self.paths = paths
        self.vmManager = VMManager(paths: paths)
    }

    /// Start the daemon, listening on the Unix socket.
    public func start() throws {
        try paths.ensureDirectories()

        // Remove stale socket
        unlink(paths.socketPath.path)

        // Create Unix domain socket
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw FendError.connectionError("socket: \(String(cString: strerror(errno)))")
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = paths.socketPath.path.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw FendError.connectionError("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            pathBytes.withUnsafeBufferPointer { src in
                let dst = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
                dst.update(from: src.baseAddress!, count: src.count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw FendError.connectionError("bind: \(String(cString: strerror(errno)))")
        }

        guard listen(listenFd, 8) == 0 else {
            throw FendError.connectionError("listen: \(String(cString: strerror(errno)))")
        }

        // Write PID file
        try "\(ProcessInfo.processInfo.processIdentifier)".write(
            to: paths.pidPath, atomically: true, encoding: .utf8
        )

        // Handle SIGINT/SIGTERM for clean shutdown. Use .global() — the accept
        // loop blocks the main thread, so handlers on .main would never fire.
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        sigintSource.setEventHandler { [weak self] in
            self?.shutdown()
        }
        sigtermSource.setEventHandler { [weak self] in
            self?.shutdown()
        }
        sigintSource.resume()
        sigtermSource.resume()

        // Start idle VM reaper — pauses warm VMs after pauseAfter and
        // stops paused VMs after stopAfter.
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.vmManager.reapIdle(pauseAfter: self.pauseAfter, stopAfter: self.stopAfter)
        }
        timer.resume()

        // GC stale per-project rootfs clones on startup and hourly thereafter.
        vmManager.gcProjectState()
        let gcTimer = DispatchSource.makeTimerSource(queue: .global())
        gcTimer.schedule(deadline: .now() + 3600, repeating: 3600)
        gcTimer.setEventHandler { [weak self] in
            self?.vmManager.gcProjectState()
        }
        gcTimer.resume()
        self.timers = [timer, gcTimer]

        fputs("fend: daemon started (pid \(ProcessInfo.processInfo.processIdentifier))\n", stderr)
        fputs("fend: listening on \(paths.socketPath.path)\n", stderr)

        // Accept loop (runs forever on main thread)
        while true {
            let clientFd = Darwin.accept(listenFd, nil, nil)
            if clientFd < 0 {
                if errno == EINTR { continue }
                break
            }
            DispatchQueue.global().async {
                self.handleClient(fd: clientFd)
            }
        }
    }

    // MARK: - Client handling (dispatch on message type)

    private func handleClient(fd clientFd: Int32) {
        defer { Darwin.close(clientFd) }

        let frame: FramedMessage
        do {
            frame = try FramedMessage.read(from: clientFd)
        } catch {
            fputs("fend: daemon: read error: \(error)\n", stderr)
            return
        }

        switch frame.type {
        case .daemonRun:
            handleRun(fd: clientFd, frame: frame)
        case .daemonStatus:
            handleStatus(fd: clientFd)
        case .daemonStopVM:
            handleStopVM(fd: clientFd, frame: frame)
        default:
            sendDaemonError(fd: clientFd, message: "Unknown request type \(frame.type.rawValue)")
        }
    }

    // MARK: - Run handler

    private func handleRun(fd clientFd: Int32, frame: FramedMessage) {
        let request: DaemonRunRequest
        do {
            request = try JSONDecoder().decode(DaemonRunRequest.self, from: frame.payload)
        } catch {
            sendDaemonError(fd: clientFd, message: "Bad request: \(error)")
            return
        }

        let projectDir = URL(fileURLWithPath: request.projectDir)
        let config = FendConfig.load(from: projectDir)

        // Get or create VM (async bridge, with timeout)
        let semaphore = DispatchSemaphore(value: 0)
        var vmResult: Result<VMInstance, Error>!

        Task {
            do {
                let vm = try await self.vmManager.vmForProject(projectDir, config: config)
                try await vm.waitForReady()
                vmResult = .success(vm)
            } catch {
                vmResult = .failure(error)
            }
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + .seconds(60)) == .timedOut {
            sendDaemonError(fd: clientFd, message: "VM boot timed out after 60s")
            return
        }

        let vmInstance: VMInstance
        do {
            vmInstance = try vmResult.get()
        } catch {
            sendDaemonError(fd: clientFd, message: "VM boot failed: \(error)")
            return
        }

        // Connect to fendd over vsock (async bridge, with timeout)
        var connResult: Result<VZVirtioSocketConnection, Error>!
        let sem2 = DispatchSemaphore(value: 0)
        Task {
            do {
                connResult = .success(try await vmInstance.connectToGuest(port: vsockPort))
            } catch {
                connResult = .failure(error)
            }
            sem2.signal()
        }
        if sem2.wait(timeout: .now() + .seconds(15)) == .timedOut {
            sendDaemonError(fd: clientFd, message: "vsock connect timed out after 15s")
            return
        }

        let vsockConn: VZVirtioSocketConnection
        do {
            vsockConn = try connResult.get()
        } catch {
            sendDaemonError(fd: clientFd, message: "vsock connect failed: \(error)")
            return
        }

        let fenddFd = vsockConn.fileDescriptor

        // Read Ready from fendd
        do {
            let readyFrame = try FramedMessage.read(from: fenddFd)
            guard readyFrame.type == .ready else {
                sendDaemonError(fd: clientFd, message: "fendd: expected Ready")
                return
            }
        } catch {
            sendDaemonError(fd: clientFd, message: "fendd ready failed: \(error)")
            return
        }

        // Send Ready to CLI
        do {
            try FramedMessage(type: .ready, payload: Data()).write(to: clientFd)
        } catch {
            return
        }

        // Send ExecuteCommand to fendd
        do {
            let execCmd = ExecuteCommand(
                id: 1,
                cmd: request.cmd,
                args: request.args,
                env: request.env,
                cwd: request.projectDir,
                tty: request.tty
            )
            let payload = try JSONEncoder().encode(execCmd)
            try FramedMessage(type: .executeCommand, payload: payload).write(to: fenddFd)
        } catch {
            sendDaemonError(fd: clientFd, message: "send command failed: \(error)")
            return
        }

        // Spawn forwarding thread: client → fendd
        let forwardDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { forwardDone.signal() }
            while true {
                let frame: FramedMessage
                do {
                    frame = try FramedMessage.read(from: clientFd)
                } catch {
                    break
                }
                switch frame.type {
                case .inputData, .forwardSignal, .windowSize:
                    do {
                        try frame.write(to: fenddFd)
                    } catch {
                        break
                    }
                default:
                    break
                }
            }
        }

        // Relay frames from fendd → client until ExitStatus
        do {
            while true {
                let response = try FramedMessage.read(from: fenddFd)
                try response.write(to: clientFd)
                if response.type == .exitStatus {
                    break
                }
            }
        } catch {
            // Connection closed
        }

        Darwin.shutdown(clientFd, SHUT_RD)
        forwardDone.wait()

        vmInstance.lastUsed = Date()

        // Keep vsockConn alive until we're done
        _ = vsockConn
    }

    // MARK: - Status handler

    private func handleStatus(fd clientFd: Int32) {
        let vmInfos = vmManager.status()
        do {
            let response = DaemonStatusResponse(vms: vmInfos)
            let payload = try JSONEncoder().encode(response)
            try FramedMessage(type: .daemonStatusResponse, payload: payload).write(to: clientFd)
        } catch {
            sendDaemonError(fd: clientFd, message: "Status failed: \(error)")
        }
    }

    // MARK: - Stop VM handler

    private func handleStopVM(fd clientFd: Int32, frame: FramedMessage) {
        do {
            let request = try JSONDecoder().decode(DaemonStopRequest.self, from: frame.payload)
            let stopped = vmManager.stopVM(forProjectDir: request.projectDir)
            if stopped {
                try FramedMessage(type: .ready, payload: Data()).write(to: clientFd)
            } else {
                sendDaemonError(fd: clientFd, message: "No VM running for \(URL(fileURLWithPath: request.projectDir).lastPathComponent)")
            }
        } catch {
            sendDaemonError(fd: clientFd, message: "Bad stop request: \(error)")
        }
    }

    private func sendDaemonError(fd: Int32, message: String) {
        fputs("fend: daemon: \(message)\n", stderr)
        let msg = DaemonErrorMsg(message: message)
        if let payload = try? JSONEncoder().encode(msg) {
            let frame = FramedMessage(type: .daemonError, payload: payload)
            try? frame.write(to: fd)
        }
    }

    // MARK: - Shutdown

    private func shutdown() {
        fputs("\nfend: daemon stopping...\n", stderr)
        vmManager.stopAll()
        if listenFd >= 0 {
            Darwin.close(listenFd)
        }
        unlink(paths.socketPath.path)
        unlink(paths.pidPath.path)
        Foundation.exit(0)
    }
}

// MARK: - Daemon utilities

/// Try to connect to the daemon Unix socket. Returns fd on success, -1 on failure.
public func connectToDaemon(socketPath: URL) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return -1 }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.path.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
        Darwin.close(fd)
        return -1
    }
    withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
        pathBytes.withUnsafeBufferPointer { src in
            let dst = UnsafeMutableRawPointer(sunPath).assumingMemoryBound(to: CChar.self)
            dst.update(from: src.baseAddress!, count: src.count)
        }
    }

    let result = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }

    if result < 0 {
        Darwin.close(fd)
        return -1
    }

    return fd
}

/// Auto-start the daemon in the background. Returns true if started.
public func autoStartDaemon(fendPath: String) -> Bool {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: fendPath)
    task.arguments = ["daemon", "start"]
    task.standardOutput = FileHandle.nullDevice
    task.standardError = FileHandle.nullDevice
    task.environment = ProcessInfo.processInfo.environment

    do {
        try task.run()
    } catch {
        return false
    }

    let paths = FendPaths()
    for _ in 0..<50 {
        Thread.sleep(forTimeInterval: 0.1)
        if FileManager.default.fileExists(atPath: paths.socketPath.path) {
            return true
        }
    }
    return false
}

// Foundation marks fork() unavailable on Darwin — call it through a raw
// @_silgen_name binding. We only call fork() here, very early in daemon startup,
// before any Dispatch/Task work starts, so the usual fork-after-threads hazards
// don't apply.
@_silgen_name("fork") private func c_fork() -> Int32

/// Detach the current process from the controlling terminal and redirect
/// stdio to the daemon log file. Must be called before any Dispatch work
/// or other threads are spawned in this process.
public func daemonize(logPath: URL) {
    // Pre-open the log fd (happens in both parent and child; parent closes).
    let logFd = open(logPath.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)

    let pid = c_fork()
    if pid < 0 {
        fputs("fend: fork failed: \(String(cString: strerror(errno)))\n", stderr)
        if logFd >= 0 { close(logFd) }
        Foundation.exit(1)
    }
    if pid > 0 {
        // Parent — exit so the caller's wait returns quickly. The child lives on.
        if logFd >= 0 { close(logFd) }
        Foundation.exit(0)
    }

    // Child: become session leader, detach from controlling terminal.
    _ = setsid()

    // Redirect stdin ← /dev/null
    let devNull = open("/dev/null", O_RDONLY)
    if devNull >= 0 {
        dup2(devNull, STDIN_FILENO)
        close(devNull)
    }

    // Redirect stdout + stderr → log file
    if logFd >= 0 {
        dup2(logFd, STDOUT_FILENO)
        dup2(logFd, STDERR_FILENO)
        close(logFd)
    }

    // Don't let a closed pipe kill the daemon.
    signal(SIGPIPE, SIG_IGN)
}
