import Foundation
import Darwin
import ManiCore

// fork() is marked unavailable in Apple's SDK headers but is still
// exported by libsystem. Bypass the Swift availability check via
// silgen_name so we can do the daemon-style detach.
@_silgen_name("fork") private func _fork() -> pid_t

// mani-agent: one detached helper process per Mani task.
//
// Lifecycle:
//   1. Mani spawns this binary (via Process). Args carry: socket
//      path, cwd, env, optional initial-input + delay, then `--`
//      and the command + args to run.
//   2. We double-fork to detach from Mani's process group, so when
//      Mani dies we don't go with it.
//   3. We forkpty() + execve the inner command. The forkpty parent
//      is THIS agent process; the child is the user's shell / claude
//      / etc.
//   4. Bind a UNIX socket. Accept one Mani client at a time.
//   5. Main loop with poll(): pump PTY master ↔ client socket, with
//      our frame protocol (see ManiCore/AgentProtocol.swift).
//   6. When the inner child exits, send EXIT frame, close socket,
//      remove the socket file, exit.
//
// We intentionally do ZERO terminal emulation in here. The bytes
// from the PTY master flow straight to Mani; Mani's libghostty does
// all rendering. No DA/XTVERSION shenanigans, no width mismatches.

struct AgentArgs {
    var socketPath: String
    var cwd: String?
    var env: [(String, String)]
    var initialInput: String?
    var initialInputDelay: Double
    var command: String
    var commandArgs: [String]
}

func parseArgs(_ argv: [String]) -> AgentArgs? {
    var socketPath: String?
    var cwd: String?
    var env: [(String, String)] = []
    var initialInput: String?
    var initialInputDelay: Double = 0.8
    var rest: [String] = []

    var i = 1
    while i < argv.count {
        let a = argv[i]
        if a == "--" {
            rest = Array(argv[(i + 1)...])
            break
        }
        switch a {
        case "--socket":
            i += 1; socketPath = i < argv.count ? argv[i] : nil
        case "--cwd":
            i += 1; cwd = i < argv.count ? argv[i] : nil
        case "--env":
            i += 1
            if i < argv.count, let eq = argv[i].firstIndex(of: "=") {
                let k = String(argv[i][..<eq])
                let v = String(argv[i][argv[i].index(after: eq)...])
                env.append((k, v))
            }
        case "--initial-input":
            i += 1; initialInput = i < argv.count ? argv[i] : nil
        case "--initial-input-delay":
            i += 1
            if i < argv.count, let d = Double(argv[i]) { initialInputDelay = d }
        default:
            FileHandle.standardError.write(Data("mani-agent: unknown arg \(a)\n".utf8))
            return nil
        }
        i += 1
    }
    guard let socketPath, !rest.isEmpty else { return nil }
    return AgentArgs(
        socketPath: socketPath,
        cwd: cwd,
        env: env,
        initialInput: initialInput,
        initialInputDelay: initialInputDelay,
        command: rest[0],
        commandArgs: Array(rest.dropFirst())
    )
}

// MARK: - Detach from parent

func detachFromParentProcessGroup() {
    // Double-fork pattern. First fork: original agent exits, so the
    // Mani-side Process.run returns immediately. First child setsid()
    // — becomes a new session leader, no controlling TTY. Second
    // fork: first child exits, grand-child is reparented to launchd
    // and inherits no session/group ties to Mani.
    let first = _fork()
    if first < 0 { exit(1) }
    if first > 0 { exit(0) }
    _ = setsid()
    let second = _fork()
    if second < 0 { exit(1) }
    if second > 0 { exit(0) }
    // We are now the detached grand-child. Mani's launching Process
    // is reaping the original (already exited).
}

// MARK: - Spawn the inner process via forkpty

func spawnInner(_ args: AgentArgs) -> (master: Int32, pid: pid_t)? {
    var masterFD: Int32 = -1
    let pid = forkpty(&masterFD, nil, nil, nil)
    if pid < 0 { return nil }
    if pid == 0 {
        // Child. Build env, chdir, exec.
        if let cwd = args.cwd {
            let rc = chdir(cwd)
            if rc != 0 {
                let err = String(cString: strerror(errno))
                FileHandle.standardError.write(Data("agent child: chdir(\(cwd)) failed: \(err)\n".utf8))
            }
        }
        // Merge inherited env with overrides. Mani's env is already
        // inherited; just append/override the ones explicitly passed.
        var envDict: [String: String] = ProcessInfo.processInfo.environment
        for (k, v) in args.env { envDict[k] = v }
        let envStrings = envDict.map { "\($0.key)=\($0.value)" }
        let argvStrings = [args.command] + args.commandArgs
        let argvCStrs: [UnsafeMutablePointer<CChar>?] = argvStrings.map { $0.withCString { strdup($0) } }
        let envvCStrs: [UnsafeMutablePointer<CChar>?] = envStrings.map { $0.withCString { strdup($0) } }
        var argvPtrs: [UnsafeMutablePointer<CChar>?] = argvCStrs + [nil]
        var envvPtrs: [UnsafeMutablePointer<CChar>?] = envvCStrs + [nil]
        args.command.withCString { cmd in
            _ = execve(cmd, &argvPtrs, &envvPtrs)
        }
        // execve only returns on failure.
        let err = String(cString: strerror(errno))
        FileHandle.standardError.write(Data("agent child: execve(\(args.command)) failed: \(err)\n".utf8))
        _exit(127)
    }
    return (masterFD, pid)
}

// MARK: - Socket setup

func bindListenSocket(_ path: String) -> Int32 {
    // Defensive: clear any stale socket file from a previous run
    // whose agent crashed without cleanup.
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    if fd < 0 { return -1 }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(path.utf8)
    let maxPath = MemoryLayout.size(ofValue: addr.sun_path) - 1
    precondition(pathBytes.count <= maxPath, "socket path too long: \(path)")
    withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
        ptr.withMemoryRebound(to: CChar.self, capacity: maxPath + 1) { c in
            for (idx, byte) in pathBytes.enumerated() {
                c[idx] = CChar(bitPattern: byte)
            }
            c[pathBytes.count] = 0
        }
    }
    let rc = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    if rc < 0 { close(fd); return -1 }
    if listen(fd, 1) < 0 { close(fd); return -1 }
    return fd
}

// MARK: - PTY winsize ioctl

func ptyResize(_ masterFD: Int32, rows: UInt16, cols: UInt16) {
    var ws = winsize(ws_row: rows, ws_col: cols, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(masterFD, TIOCSWINSZ, &ws)
}

// MARK: - Frame writes (best-effort blocking)

func writeFully(_ fd: Int32, _ data: Data) -> Bool {
    var offset = 0
    return data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Bool in
        guard let base = raw.baseAddress else { return true }
        while offset < data.count {
            let n = write(fd, base.advanced(by: offset), data.count - offset)
            if n > 0 {
                offset += n
            } else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                continue
            } else {
                return false
            }
        }
        return true
    }
}

// MARK: - Main

guard let args = parseArgs(CommandLine.arguments) else {
    FileHandle.standardError.write(Data(
        "Usage: mani-agent --socket <path> [--cwd <p>] [--env K=V]... [--initial-input <s>] [--initial-input-delay <secs>] -- <cmd> [args]\n".utf8
    ))
    exit(2)
}

detachFromParentProcessGroup()

// After detach, Mani's stdout/stderr pipes go away. Any later
// write — even from Swift runtime / NSLog under load — would
// otherwise SIGPIPE us. Ignore the signal entirely. The agent
// keeps running; failed writes just return EPIPE.
signal(SIGPIPE, SIG_IGN)

// Redirect stdout/stderr to a per-agent log file so we keep
// the runtime safe from pipe-close issues AND have a place to
// inspect what's happening when a session won't render.
let logPath: String = {
    let dir = NSHomeDirectory() + "/Library/Application Support/Mani/agent-logs"
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true
    )
    let stem = (args.socketPath as NSString).lastPathComponent
        .replacingOccurrences(of: ".sock", with: "")
    return "\(dir)/\(stem).log"
}()
if let logFile = fopen(logPath, "a") {
    let logFD = fileno(logFile)
    dup2(logFD, fileno(stdout))
    dup2(logFD, fileno(stderr))
    fclose(logFile)
}
FileHandle.standardError.write(Data("--- agent boot pid=\(getpid()) cwd=\(args.cwd ?? "<none>") cmd=\(args.command) args=\(args.commandArgs)\n".utf8))

guard let spawn = spawnInner(args) else {
    exit(1)
}
let masterFD = spawn.master
let childPid = spawn.pid

let listenFD = bindListenSocket(args.socketPath)
if listenFD < 0 { exit(1) }

// Set non-blocking on PTY master so reads don't wedge the loop.
// Client socket gets the same treatment on accept.
_ = fcntl(masterFD, F_SETFL, O_NONBLOCK)

// Schedule initial-input write. Using a worker thread, NOT
// DispatchQueue.global() — the latter may have lingering forked
// state on macOS. A pthread + sleep + write is plain and reliable.
if let input = args.initialInput, !input.isEmpty {
    let delay = args.initialInputDelay
    let bytes = Array(input.utf8)
    Thread.detachNewThread {
        Thread.sleep(forTimeInterval: delay)
        var off = 0
        bytes.withUnsafeBufferPointer { (ptr: UnsafeBufferPointer<UInt8>) in
            while off < bytes.count {
                let n = write(masterFD, ptr.baseAddress!.advanced(by: off), bytes.count - off)
                if n > 0 { off += n }
                else if errno == EINTR || errno == EAGAIN { usleep(1000) }
                else { return }
            }
        }
    }
}

// MARK: Main poll loop

var clientFD: Int32 = -1
let decoder = AgentFrameDecoder()
var childExitedFlag = false
var pendingExitCode: Int32 = 0
var listenFDClosed = false
// Bytes the PTY emitted before any client connected. Replayed on
// accept so the client sees the initial prompt / banner. Mirrors
// the in-Mani ManagedPTY captured-output replay behavior. Capped
// to avoid unbounded growth if the child writes a lot of output
// while no one is attached.
var preConnectBuffer = Data()
let preConnectCap = 1_048_576

// Tear-down for post-child phase: unlink the socket and close the
// listening FD so no new clients can connect. Called as soon as
// we observe the child has died — prevents a race where Mani's
// discover() sees the socket as alive but its attach hits an
// imminently-dying agent.
func tearDownListener() {
    if listenFDClosed { return }
    listenFDClosed = true
    unlink(args.socketPath)
    Darwin.close(listenFD)
}

while !childExitedFlag || clientFD >= 0 {
    var fds: [pollfd] = []
    fds.append(pollfd(fd: masterFD, events: Int16(POLLIN), revents: 0))
    let listenIdx: Int
    if !listenFDClosed {
        fds.append(pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0))
        listenIdx = 1
    } else {
        listenIdx = -1
    }
    let clientIdx: Int
    if clientFD >= 0 {
        fds.append(pollfd(fd: clientFD, events: Int16(POLLIN), revents: 0))
        clientIdx = fds.count - 1
    } else {
        clientIdx = -1
    }
    let pollResult = fds.withUnsafeMutableBufferPointer {
        poll($0.baseAddress, nfds_t($0.count), 200)
    }
    _ = pollResult

    // Drain PTY master.
    if fds[0].revents & Int16(POLLIN) != 0 {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { read(masterFD, $0.baseAddress, $0.count) }
            if n > 0 {
                let payload = Data(bytes: buf, count: n)
                if clientFD >= 0 {
                    let frame = AgentProtocol.encode(.output, payload: payload)
                    if !writeFully(clientFD, frame) {
                        close(clientFD); clientFD = -1
                    }
                } else {
                    // No attached client yet: buffer for replay on
                    // accept. Trim FIFO if we exceed the cap so
                    // memory doesn't grow unbounded with an idle
                    // detached agent.
                    let totalAfter = preConnectBuffer.count + payload.count
                    if totalAfter > preConnectCap {
                        let drop = totalAfter - preConnectCap
                        preConnectBuffer.removeFirst(min(drop, preConnectBuffer.count))
                    }
                    preConnectBuffer.append(payload)
                }
            } else if n == 0 {
                // EOF: child closed its side.
                FileHandle.standardError.write(Data("agent: PTY read returned 0 (EOF)\n".utf8))
                childExitedFlag = true
                tearDownListener()
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                let err = String(cString: strerror(errno))
                FileHandle.standardError.write(Data("agent: PTY read errno \(errno) \(err)\n".utf8))
                if errno == EIO {
                    // Inner process died.
                    childExitedFlag = true
                    tearDownListener()
                }
                break
            }
        }
    }
    if fds[0].revents & Int16(POLLHUP) != 0 {
        childExitedFlag = true
        tearDownListener()
    }

    // Accept new client. Only one at a time; drop existing if any.
    if listenIdx >= 0 && fds[listenIdx].revents & Int16(POLLIN) != 0 {
        let newClient = accept(listenFD, nil, nil)
        if newClient >= 0 {
            FileHandle.standardError.write(Data("agent: accept ok fd=\(newClient)\n".utf8))
            if clientFD >= 0 { close(clientFD) }
            clientFD = newClient
            _ = fcntl(clientFD, F_SETFL, O_NONBLOCK)
            if !preConnectBuffer.isEmpty {
                let frame = AgentProtocol.encode(.output, payload: preConnectBuffer)
                _ = writeFully(clientFD, frame)
                preConnectBuffer.removeAll()
            }
        } else {
            let err = String(cString: strerror(errno))
            FileHandle.standardError.write(Data("agent: accept failed: \(err)\n".utf8))
        }
    }
    if clientIdx >= 0 && fds[clientIdx].revents & Int16(POLLHUP) != 0 {
        FileHandle.standardError.write(Data("agent: client POLLHUP, closing fd=\(clientFD)\n".utf8))
        close(clientFD); clientFD = -1
    }

    // Read from client + decode frames.
    if clientIdx >= 0 && fds[clientIdx].revents & Int16(POLLIN) != 0 {
        var buf = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buf.withUnsafeMutableBufferPointer { read(clientFD, $0.baseAddress, $0.count) }
            if n > 0 {
                decoder.append(Data(bytes: buf, count: n))
            } else if n == 0 {
                FileHandle.standardError.write(Data("agent: client read EOF fd=\(clientFD)\n".utf8))
                close(clientFD); clientFD = -1
                break
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { break }
                let err = String(cString: strerror(errno))
                FileHandle.standardError.write(Data("agent: client read err \(err) fd=\(clientFD)\n".utf8))
                close(clientFD); clientFD = -1
                break
            }
        }
        while let frame = decoder.next() {
            switch frame.type {
            case .input:
                _ = writeFully(masterFD, frame.payload)
            case .resize:
                if let r = AgentProtocol.decodeResize(frame.payload) {
                    ptyResize(masterFD, rows: r.rows, cols: r.cols)
                }
            case .terminate:
                kill(childPid, SIGTERM)
            case .output, .exit:
                // Server-side frames; client shouldn't send.
                break
            }
        }
    }

    // Reap child non-blocking. Once reaped, send EXIT frame and
    // wait for client to drain before closing the socket.
    if !childExitedFlag {
        var status: Int32 = 0
        let r = waitpid(childPid, &status, WNOHANG)
        if r == childPid {
            childExitedFlag = true
            tearDownListener()
            if (status & 0x7f) == 0 {
                pendingExitCode = Int32((status >> 8) & 0xff)
            } else {
                pendingExitCode = -1
            }
            FileHandle.standardError.write(Data("agent: child \(childPid) exited (status=\(status), code=\(pendingExitCode))\n".utf8))
        }
    }

    if childExitedFlag && clientFD >= 0 {
        let exitFrame = AgentProtocol.exitFrame(code: pendingExitCode)
        _ = writeFully(clientFD, exitFrame)
        // Hold the socket open briefly so the client sees the EXIT
        // frame, then close.
        usleep(50_000)
        close(clientFD)
        clientFD = -1
    }
}

close(masterFD)
tearDownListener()
exit(0)
