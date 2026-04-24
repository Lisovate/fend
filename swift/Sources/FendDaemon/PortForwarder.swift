import Foundation
@preconcurrency import Virtualization
import FendCommon

/// Manages TCP port forwarding from the host to a VM.
/// Connects to fendd's port-event stream (vsock 1025) and creates
/// TCP proxies on localhost for each detected listening port.
public final class PortForwarder: @unchecked Sendable {
    private let vm: VMInstance
    private var proxies: [UInt16: PortProxy] = [:]
    private let lock = NSLock()
    private var monitoring = false

    public init(vm: VMInstance) {
        self.vm = vm
    }

    /// Start monitoring for port events from the VM.
    public func startMonitoring() {
        guard !monitoring else { return }
        monitoring = true

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.monitorLoop()
        }
    }

    /// Stop all proxies and monitoring.
    public func stopAll() {
        monitoring = false
        lock.lock()
        let allProxies = proxies.values
        proxies.removeAll()
        lock.unlock()
        for proxy in allProxies {
            proxy.stop()
        }
    }

    /// List currently forwarded ports.
    public var forwardedPorts: [UInt16] {
        lock.lock()
        let ports = Array(proxies.keys.sorted())
        lock.unlock()
        return ports
    }

    // MARK: - Private

    private func monitorLoop() {
        // Exponential backoff with jitter for reconnect attempts.
        // Reset to base on a successful connect, climb up to cap on failure.
        let baseDelay: TimeInterval = 1.0
        let maxDelay: TimeInterval = 30.0
        var currentDelay = baseDelay

        while monitoring {
            guard vm.state == .running else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            let semaphore = DispatchSemaphore(value: 0)
            var connResult: Result<VZVirtioSocketConnection, Error>?

            Task {
                do {
                    connResult = .success(try await self.vm.connectToGuest(port: vsockPortEvents))
                } catch {
                    connResult = .failure(error)
                }
                semaphore.signal()
            }
            semaphore.wait()

            guard let result = connResult, case .success(let conn) = result else {
                let jitter = Double.random(in: 0.8...1.2)
                Thread.sleep(forTimeInterval: currentDelay * jitter)
                currentDelay = min(currentDelay * 2, maxDelay)
                continue
            }

            // Connected — reset backoff for the next failure.
            currentDelay = baseDelay

            let fd = conn.fileDescriptor
            fputs("fend: port monitor connected\n", stderr)

            while monitoring {
                do {
                    let frame = try FramedMessage.read(from: fd)
                    guard frame.type == .portEvent else { continue }

                    let event = try JSONDecoder().decode(PortEvent.self, from: frame.payload)
                    handlePortEvent(event)
                } catch {
                    break
                }
            }

            _ = conn

            if monitoring {
                let jitter = Double.random(in: 0.8...1.2)
                Thread.sleep(forTimeInterval: currentDelay * jitter)
                currentDelay = min(currentDelay * 2, maxDelay)
            }
        }
    }

    private func handlePortEvent(_ event: PortEvent) {
        switch event.event {
        case .opened:
            startProxy(port: event.port)
        case .closed:
            stopProxy(port: event.port)
        }
    }

    private func startProxy(port: UInt16) {
        lock.lock()
        guard proxies[port] == nil else {
            lock.unlock()
            return
        }

        let proxy = PortProxy(hostPort: port, vm: vm)
        proxies[port] = proxy
        lock.unlock()

        fputs("fend: forwarding localhost:\(port) → vm:\(port)\n", stderr)
        proxy.start()
    }

    private func stopProxy(port: UInt16) {
        lock.lock()
        let proxy = proxies.removeValue(forKey: port)
        lock.unlock()

        if let proxy {
            fputs("fend: stopped forwarding localhost:\(port)\n", stderr)
            proxy.stop()
        }
    }
}

// MARK: - PortProxy

/// TCP proxy for a single port. Listens on localhost:<port> and relays
/// each connection through vsock port 1026 to the VM.
/// Phase 2H: connection limit via DispatchSemaphore.
private final class PortProxy: @unchecked Sendable {
    let hostPort: UInt16
    let vm: VMInstance
    private var listenFd: Int32 = -1
    private var running = false
    private let connectionSemaphore = DispatchSemaphore(value: 256)

    init(hostPort: UInt16, vm: VMInstance) {
        self.hostPort = hostPort
        self.vm = vm
    }

    func start() {
        running = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop()
        }
    }

    func stop() {
        running = false
        if listenFd >= 0 {
            Darwin.close(listenFd)
            listenFd = -1
        }
    }

    private func acceptLoop() {
        listenFd = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFd >= 0 else { return }

        var opt: Int32 = 1
        setsockopt(listenFd, SOL_SOCKET, SO_REUSEADDR, &opt, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(hostPort).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(listenFd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            fputs("fend: bind localhost:\(hostPort) failed: \(String(cString: strerror(errno)))\n", stderr)
            Darwin.close(listenFd)
            listenFd = -1
            return
        }

        guard listen(listenFd, 16) == 0 else {
            Darwin.close(listenFd)
            listenFd = -1
            return
        }

        while running {
            let clientFd = Darwin.accept(listenFd, nil, nil)
            if clientFd < 0 {
                if errno == EINTR { continue }
                break
            }

            connectionSemaphore.wait()
            DispatchQueue.global().async { [weak self] in
                defer { self?.connectionSemaphore.signal() }
                self?.handleTcpClient(fd: clientFd)
            }
        }
    }

    private func handleTcpClient(fd clientFd: Int32) {
        defer { Darwin.close(clientFd) }

        let semaphore = DispatchSemaphore(value: 0)
        var connResult: Result<VZVirtioSocketConnection, Error>?

        Task {
            do {
                connResult = .success(try await self.vm.connectToGuest(port: vsockPortForward))
            } catch {
                connResult = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()

        guard let result = connResult, case .success(let vsockConn) = result else { return }
        let vsockFd = vsockConn.fileDescriptor

        var portBE = hostPort.bigEndian
        let written = withUnsafeBytes(of: &portBE) { buf in
            Darwin.write(vsockFd, buf.baseAddress!, 2)
        }
        guard written == 2 else { return }

        relay(fd1: clientFd, fd2: vsockFd)

        _ = vsockConn
    }
}

// MARK: - Bidirectional relay

/// Relay data between two file descriptors until either side closes.
/// Phase 2G: uses DispatchGroup instead of bare counter for join synchronization.
private func relay(fd1: Int32, fd2: Int32) {
    let group = DispatchGroup()

    func copyData(from src: Int32, to dst: Int32) {
        let buf = UnsafeMutableRawPointer.allocate(byteCount: 16384, alignment: 1)
        defer { buf.deallocate() }
        while true {
            let n = Darwin.read(src, buf, 16384)
            if n <= 0 { break }
            var offset = 0
            while offset < n {
                let w = Darwin.write(dst, buf + offset, n - offset)
                if w <= 0 { return }
                offset += w
            }
        }
    }

    group.enter()
    DispatchQueue.global().async {
        copyData(from: fd1, to: fd2)
        Darwin.shutdown(fd2, SHUT_WR)
        group.leave()
    }

    group.enter()
    DispatchQueue.global().async {
        copyData(from: fd2, to: fd1)
        Darwin.shutdown(fd1, SHUT_WR)
        group.leave()
    }

    group.wait()
}
