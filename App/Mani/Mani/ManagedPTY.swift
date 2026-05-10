import Foundation
import Darwin

// Process-spawning + tty-controlling wrapper around a forkpty/execve pair.
// Validated by Spikes/PTYSpike (500-cycle spawn/reap, SIGTERM→SIGKILL,
// SIGWINCH on resize, byte-exact raw-mode round-trip). See docs/terminal.md.
//
// Lives in the app target (not ManiCore) — Foundation file I/O alone is
// fine in ManiCore but process I/O explicitly is not.

enum PTYError: Error {
    case forkpty(errno: Int32)
}

final class ManagedPTY: @unchecked Sendable {
    let masterFD: Int32
    let pid: pid_t

    private let exitGroup = DispatchGroup()
    private(set) var exitStatus: Int32 = -1
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess

    var onExit: ((Int32) -> Void)?

    // Output is multi-subscriber so both the renderer and the scrollback writer
    // can tap the same byte stream without stepping on each other. Subscribers
    // hold the returned token; on token deinit the handler is removed.
    final class OutputSubscription {
        private let cancel: () -> Void
        init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
        deinit { cancel() }
    }
    private let outputHandlersLock = NSLock()
    private var outputHandlers: [UUID: (Data) -> Void] = [:]
    // Bytes the PTY emitted before any handler subscribed get replayed when a
    // late subscriber attaches — otherwise the renderer misses claude's
    // startup output (TUI banners, prompts) since the polling loop in
    // Coordinator.attach takes 25–50 ms after the spawn.
    private var capturedOutput = Data()
    private let captureCap = 1_048_576

    func addOutputHandler(_ handler: @escaping (Data) -> Void) -> OutputSubscription {
        let id = UUID()
        outputHandlersLock.lock()
        let snapshot = capturedOutput
        outputHandlers[id] = handler
        outputHandlersLock.unlock()
        if !snapshot.isEmpty { handler(snapshot) }
        return OutputSubscription { [weak self] in
            guard let self else { return }
            self.outputHandlersLock.lock()
            self.outputHandlers.removeValue(forKey: id)
            self.outputHandlersLock.unlock()
        }
    }

    init(
        executable: String,
        args: [String],
        env: [String: String],
        cwd: String?,
        rawMode: Bool
    ) throws {
        let argvCStrs: [UnsafeMutablePointer<CChar>?] =
            ([executable] + args).map { strdup($0) } + [nil]
        let envCStrs: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        // Allocate the cwd C string in the parent too — chdir is async-signal-safe
        // but strdup post-fork isn't.
        let cwdCStr: UnsafeMutablePointer<CChar>? = cwd.flatMap { strdup($0) }

        var master: Int32 = 0
        // Seed the slave with a sane initial window size. The default
        // (0×0) confuses TUIs that read the size once at startup before
        // the first SIGWINCH arrives — claude's Ink frame appears to be
        // one such case.
        var initialSize = winsize(ws_row: 40, ws_col: 120, ws_xpixel: 0, ws_ypixel: 0)
        let pid = forkpty(&master, nil, nil, &initialSize)
        if pid < 0 {
            argvCStrs.forEach { free($0) }
            envCStrs.forEach { free($0) }
            if let cwdCStr { free(cwdCStr) }
            throw PTYError.forkpty(errno: errno)
        }
        if pid == 0 {
            if let cwdCStr {
                _ = chdir(cwdCStr)
            }
            if rawMode {
                var tio = termios()
                tcgetattr(0, &tio)
                cfmakeraw(&tio)
                tcsetattr(0, TCSANOW, &tio)
            }
            execve(executable, argvCStrs, envCStrs)
            _exit(127)
        }

        argvCStrs.forEach { free($0) }
        envCStrs.forEach { free($0) }
        if let cwdCStr { free(cwdCStr) }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.masterFD = master
        self.pid = pid

        let queue = DispatchQueue(label: "ManagedPTY.\(pid)")
        self.readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        self.exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)

        exitGroup.enter()

        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(self.masterFD, &buf, buf.count)
                if n > 0 {
                    let chunk = Data(bytes: buf, count: Int(n))
                    self.outputHandlersLock.lock()
                    self.capturedOutput.append(chunk)
                    if self.capturedOutput.count > self.captureCap {
                        let drop = self.capturedOutput.count - (self.captureCap / 2)
                        self.capturedOutput.removeSubrange(0..<drop)
                    }
                    let handlers = Array(self.outputHandlers.values)
                    self.outputHandlersLock.unlock()
                    for h in handlers { h(chunk) }
                } else {
                    return
                }
            }
        }
        readSource.resume()

        exitSource.setEventHandler { [weak self] in
            guard let self else { return }
            var status: Int32 = 0
            _ = waitpid(self.pid, &status, 0)
            self.exitStatus = status
            self.exitSource.cancel()
            self.onExit?(status)
            self.exitGroup.leave()
        }
        exitSource.resume()
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = data.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(masterFD, ptr, remaining)
                if n > 0 {
                    remaining -= Int(n)
                    ptr = ptr.advanced(by: Int(n))
                } else if n == -1 && (errno == EAGAIN || errno == EINTR) {
                    usleep(1_000)
                } else {
                    return
                }
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
    }

    func terminate(escalateAfter: TimeInterval) {
        kill(pid, SIGTERM)
        if exitGroup.wait(timeout: .now() + escalateAfter) == .timedOut {
            kill(pid, SIGKILL)
            exitGroup.wait()
        }
    }

    func waitForExit() {
        exitGroup.wait()
    }

    deinit {
        readSource.cancel()
        if masterFD >= 0 { close(masterFD) }
    }
}
