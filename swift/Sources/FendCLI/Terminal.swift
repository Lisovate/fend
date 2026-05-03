import Foundation
import FendCommon

// MARK: - Signal state for forwarding

/// Holds the active connection fd so the SIGINT handler can forward signals.
/// Thread-safe: fd and ttyMode are protected by NSLock (Phase 2B fix).
final class SignalState: @unchecked Sendable {
    private let lock = NSLock()
    private var _fd: Int32 = -1
    private var _ttyMode: Bool = false

    var fd: Int32 {
        get { lock.withLock { _fd } }
        set { lock.withLock { _fd = newValue } }
    }

    var ttyMode: Bool {
        get { lock.withLock { _ttyMode } }
        set { lock.withLock { _ttyMode = newValue } }
    }

    static let shared = SignalState()
}

// MARK: - Terminal helpers

/// Save and restore terminal state for raw mode.
var savedTermios = termios()
private var rawModeEnabled = false
private var fatalSignalHandlersInstalled = false

private let atexitRestore: @convention(c) () -> Void = {
    if rawModeEnabled {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
        rawModeEnabled = false
    }
}

private let fatalSignalRestore: @convention(c) (Int32) -> Void = { sig in
    if rawModeEnabled {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
        rawModeEnabled = false
    }
    // Re-raise so the process dies with the original signal, not exit(0).
    signal(sig, SIG_DFL)
    raise(sig)
}

func enableRawMode() {
    tcgetattr(STDIN_FILENO, &savedTermios)
    var raw = savedTermios
    cfmakeraw(&raw)
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)
    rawModeEnabled = true

    if !fatalSignalHandlersInstalled {
        atexit(atexitRestore)
        for sig in [SIGTERM, SIGHUP, SIGQUIT, SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGPIPE] {
            signal(sig, fatalSignalRestore)
        }
        fatalSignalHandlersInstalled = true
    }
}

func restoreTerminal() {
    if rawModeEnabled {
        tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
        rawModeEnabled = false
    }
}

/// Write a host-side status line while respecting raw terminal mode.
/// In raw mode `\n` does not imply carriage return, which makes status output
/// staircase across the terminal. Guest stdout/stderr is relayed unchanged.
func writeStatusLine(_ line: String) {
    let newline = rawModeEnabled ? "\r\n" : "\n"
    fputs(line + newline, stderr)
}

/// Get the current terminal window size.
func getWindowSize() -> (rows: UInt16, cols: UInt16) {
    var ws = winsize()
    if ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &ws) == 0 {
        return (ws.ws_row, ws.ws_col)
    }
    return (24, 80)
}

/// Send a WindowSize frame to the given fd.
func sendWindowSize(to fd: Int32) {
    let (rows, cols) = getWindowSize()
    let msg = WindowSize(id: 1, rows: rows, cols: cols)
    if let payload = try? JSONEncoder().encode(msg) {
        try? FramedMessage(type: .windowSize, payload: payload).write(to: fd)
    }
}

// MARK: - Stdin/Signal helpers

/// Start a background thread that reads stdin and sends InputData frames to fd.
/// Returns a DispatchWorkItem that can be cancelled to stop forwarding.
func startStdinForwarding(fd: Int32) -> DispatchWorkItem {
    let workItem = DispatchWorkItem {
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 8192)
        defer { buf.deallocate() }

        while !Thread.current.isCancelled {
            let n = Darwin.read(STDIN_FILENO, buf, 8192)
            if n <= 0 {
                let eof = InputData(id: 1, data: Data())
                if let payload = try? JSONEncoder().encode(eof) {
                    try? FramedMessage(type: .inputData, payload: payload).write(to: fd)
                }
                break
            }
            let chunk = Data(bytes: buf, count: n)
            let msg = InputData(id: 1, data: chunk)
            if let payload = try? JSONEncoder().encode(msg) {
                do {
                    try FramedMessage(type: .inputData, payload: payload).write(to: fd)
                } catch {
                    break
                }
            }
        }
    }
    DispatchQueue.global().async(execute: workItem)
    return workItem
}

/// Send a ForwardSignal frame to the given fd.
func sendSignal(_ sig: Int32, to fd: Int32) {
    let msg = ForwardSignal(id: 1, signal: sig)
    if let payload = try? JSONEncoder().encode(msg) {
        try? FramedMessage(type: .forwardSignal, payload: payload).write(to: fd)
    }
}

/// Read output frames from fd and write to stdout/stderr. Returns exit code.
func relayOutput(
    from fd: Int32,
    onNetworkEvent: (NetworkEvent) -> Void = { _ in }
) throws -> Int32 {
    while true {
        let frame = try FramedMessage.read(from: fd)
        switch frame.type {
        case .outputData:
            let output = try JSONDecoder().decode(OutputData.self, from: frame.payload)
            switch output.stream {
            case .stdout: FileHandle.standardOutput.write(output.data)
            case .stderr: FileHandle.standardError.write(output.data)
            }
        case .exitStatus:
            let status = try JSONDecoder().decode(ExitStatus.self, from: frame.payload)
            return status.code
        case .networkEvent:
            let event = try JSONDecoder().decode(NetworkEvent.self, from: frame.payload)
            onNetworkEvent(event)
        case .daemonError:
            let err = try JSONDecoder().decode(DaemonErrorMsg.self, from: frame.payload)
            TerminalUI.error(err.message)
            return 1
        default:
            break
        }
    }
}
