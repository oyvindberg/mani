import Foundation
import Darwin

enum PTYError: Error {
    case forkpty(errno: Int32)
}

final class ManagedPTY {
    let masterFD: Int32
    let pid: pid_t

    private let exitGroup = DispatchGroup()
    private(set) var exitStatus: Int32 = -1
    private(set) var capturedOutput = Data()
    private let outputLock = NSLock()
    private let readSource: DispatchSourceRead
    private let exitSource: DispatchSourceProcess

    init(executable: String, args: [String], env: [String: String], rawMode: Bool) throws {
        // Allocate argv/envp in the parent so we don't malloc post-fork (not async-signal-safe).
        let argvCStrs: [UnsafeMutablePointer<CChar>?] =
            ([executable] + args).map { strdup($0) } + [nil]
        let envCStrs: [UnsafeMutablePointer<CChar>?] =
            env.map { strdup("\($0.key)=\($0.value)") } + [nil]

        var master: Int32 = 0
        let pid = forkpty(&master, nil, nil, nil)
        if pid < 0 {
            argvCStrs.forEach { free($0) }
            envCStrs.forEach { free($0) }
            throw PTYError.forkpty(errno: errno)
        }
        if pid == 0 {
            // Child. login_tty already done by forkpty: setsid + slave as ctty + dup2 to 0/1/2.
            // Stick to async-signal-safe operations only.
            if rawMode {
                var tio = termios()
                tcgetattr(0, &tio)
                cfmakeraw(&tio)
                tcsetattr(0, TCSANOW, &tio)
            }
            execve(executable, argvCStrs, envCStrs)
            _exit(127)
        }

        // Parent.
        argvCStrs.forEach { free($0) }
        envCStrs.forEach { free($0) }

        _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
        self.masterFD = master
        self.pid = pid

        let queue = DispatchQueue(label: "ManagedPTY.\(pid)")
        self.readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
        self.exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)

        exitGroup.enter()

        let outputLock = self.outputLock
        readSource.setEventHandler { [weak self] in
            guard let self else { return }
            var buf = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(self.masterFD, &buf, buf.count)
                if n > 0 {
                    outputLock.lock()
                    self.capturedOutput.append(buf, count: Int(n))
                    outputLock.unlock()
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
                    // Yield briefly so the read source on another thread can drain.
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

    func snapshotOutput() -> Data {
        outputLock.lock()
        defer { outputLock.unlock() }
        return capturedOutput
    }

    deinit {
        readSource.cancel()
        if masterFD >= 0 { close(masterFD) }
    }
}
