import Foundation
@preconcurrency import Virtualization
import FendCommon

/// Per-run collector for outbound TCP connection events observed inside the VM.
/// The guest publishes events on a separate vsock stream so command stdout and
/// stderr stay untouched.
public final class NetworkEventCollector: @unchecked Sendable {
    private let vm: VMInstance
    private let lock = NSLock()
    private var running = false
    private var fd: Int32 = -1
    private var events: [NetworkEvent] = []
    private var seen: Set<NetworkEvent> = []

    public init(vm: VMInstance) {
        self.vm = vm
    }

    public func start() {
        let shouldStart = lock.withLock { () -> Bool in
            guard !running else { return false }
            running = true
            return true
        }
        guard shouldStart else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.monitorOnce()
        }
    }

    public func stop() {
        let activeFd = lock.withLock { () -> Int32 in
            running = false
            let activeFd = fd
            fd = -1
            return activeFd
        }
        if activeFd >= 0 {
            Darwin.shutdown(activeFd, SHUT_RDWR)
        }
    }

    public var snapshot: [NetworkEvent] {
        lock.withLock { events }
    }

    private var isRunning: Bool {
        lock.withLock { running }
    }

    private func monitorOnce() {
        let semaphore = DispatchSemaphore(value: 0)
        let connResult = ResultBox<VZVirtioSocketConnection>()

        Task {
            do {
                let conn = try await vm.connectToGuest(port: vsockPortNetworkEvents)
                connResult.set(.success(conn))
            } catch {
                connResult.set(.failure(error))
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + .seconds(2)) == .success,
              let result = connResult.get(),
              case .success(let conn) = result else {
            lock.withLock { running = false }
            return
        }

        lock.withLock { fd = conn.fileDescriptor }

        while isRunning {
            do {
                let frame = try FramedMessage.read(from: conn.fileDescriptor)
                guard frame.type == .networkEvent else { continue }
                let event = try JSONDecoder().decode(NetworkEvent.self, from: frame.payload)
                append(event)
            } catch {
                break
            }
        }

        lock.withLock {
            if fd == conn.fileDescriptor {
                fd = -1
            }
            running = false
        }
        _ = conn
    }

    private func append(_ event: NetworkEvent) {
        lock.withLock {
            guard !seen.contains(event), events.count < 100 else { return }
            seen.insert(event)
            events.append(event)
        }
    }
}
