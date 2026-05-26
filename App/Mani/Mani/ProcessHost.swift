import Foundation
import Darwin
import ManiCore
import ManiServer

// Abstraction over WHERE a long-lived task's process lives. Today
// only LocalAgentHost: each task gets its own detached `mani-agent`
// helper binary that owns the PTY. Tomorrow: SshTmuxHost or
// SshAgentHost follows the same protocol but proxies through ssh.
//
// Why a host at all: processes need to outlive Mani's process. Mani
// crashes / rebuilds / relaunches without disturbing the user's
// claude conversations and shells. The agent does the forkpty + the
// UNIX-socket forwarding so Mani is a transient client.
protocol ProcessHost {
    func ensureReady() async throws
    func spawn(taskId: UUID, spec: ProcessSpec) async throws
    func attach(taskId: UUID) async throws -> TaskIO
    func terminate(taskId: UUID) async throws
    // Set of agent IDs currently alive on disk (socket exists + connect
    // succeeds). Cheap to call — does NOT spawn anything. Used by boot
    // reconciliation and by any UI path that wants to refresh the
    // runtime view of state.
    func discover() async throws -> Set<UUID>
    // Same probe as discover() but for a single task. Cheaper than
    // listing the whole sockets directory when you only care about one.
    func isAlive(taskId: UUID) async -> Bool
}

enum ProcessHostError: Error {
    case agentBinaryNotFound
    case spawnFailed(String)
    case socketConnectFailed(String)
}

// MARK: - Local-agent backend

final class LocalAgentHost: ProcessHost {
    private let agentBinary: String
    private let socketsDir: URL

    // Detect at app launch. Bundled binary inside Mani.app's
    // Contents/Helpers/ is the production location; .build/debug
    // covers dev runs from xcodebuild without a copy phase.
    static func detect() -> LocalAgentHost? {
        let bundleAux = Bundle.main.url(forAuxiliaryExecutable: "mani-agent")?.path
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Mani/
            .deletingLastPathComponent() // Mani/Mani/
            .deletingLastPathComponent() // App/Mani/
            .deletingLastPathComponent() // App/
        let devBin = repoRoot.appendingPathComponent(".build/debug/mani-agent").path
        let candidates = [bundleAux, devBin].compactMap { $0 }
        guard let binary = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else { return nil }
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport
            .appendingPathComponent("Mani", isDirectory: true)
            .appendingPathComponent("agents", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return LocalAgentHost(agentBinary: binary, socketsDir: dir)
    }

    init(agentBinary: String, socketsDir: URL) {
        self.agentBinary = agentBinary
        self.socketsDir = socketsDir
    }

    func ensureReady() async throws {
        // The agent binary is per-task; nothing to warm up at the
        // host level beyond ensuring the sockets directory exists
        // (done in detect()).
    }

    private func socketPath(taskId: UUID) -> URL {
        socketsDir.appendingPathComponent("\(taskId.uuidString).sock", isDirectory: false)
    }

    func spawn(taskId: UUID, spec: ProcessSpec) async throws {
        let sockPath = socketPath(taskId: taskId).path
        try? FileManager.default.removeItem(atPath: sockPath)

        // Build env additions. Match what EffectRunner used to do
        // pre-tmux: enrich PATH with user binary dirs, normalize
        // TERM, strip stale Terminal.app variables. The agent
        // applies these on top of inherited env in the child.
        var env = ProcessInfo.processInfo.environment
        for (k, v) in spec.env { env[k] = v }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "ghostty"
        for k in ["TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
                  "ITERM_SESSION_ID", "ITERM_PROFILE",
                  "LC_TERMINAL", "LC_TERMINAL_VERSION", "TMUX"] {
            env.removeValue(forKey: k)
        }
        let homeBin = "\(NSHomeDirectory())/.local/bin"
        let extraPath = "\(homeBin):/opt/homebrew/bin:/usr/local/bin"
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = "\(extraPath):\(existing)"
        // We only forward the keys that diverge from the inherited
        // env (terminal-related + Mani-specific). Sending the entire
        // env across argv would be huge.
        var managedKeys: Set<String> = ["TERM", "COLORTERM", "TERM_PROGRAM", "PATH"]
        for k in spec.env.keys { managedKeys.insert(k) }

        var args: [String] = ["--socket", sockPath]
        args.append(contentsOf: ["--cwd", spec.cwd.path])
        for key in managedKeys.sorted() {
            if let v = env[key] {
                args.append(contentsOf: ["--env", "\(key)=\(v)"])
            }
        }
        if let initialInput = spec.initialInput, !initialInput.isEmpty {
            args.append(contentsOf: ["--initial-input", initialInput])
        }
        args.append("--")
        args.append(spec.command)
        args.append(contentsOf: spec.args)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: agentBinary)
        p.arguments = args
        // Inherit /dev/null-style fds: don't create Pipes for
        // stdout/stderr. The agent redirects them to /dev/null
        // post-detach anyway, but giving it nothing to write into
        // up-front avoids the SIGPIPE-on-reaped-pipe risk while
        // the grand-child is still using inherited FDs.
        let devnull = FileHandle(forWritingAtPath: "/dev/null")
        p.standardInput = nil
        p.standardOutput = devnull
        p.standardError = devnull
        do {
            try p.run()
        } catch {
            throw ProcessHostError.spawnFailed("\(error)")
        }
        // The agent double-forks and exits its first PID immediately.
        // Wait for that exit, then for the socket file to appear.
        p.waitUntilExit()

        // Poll for socket file. Up to 2s.
        let start = Date()
        while !FileManager.default.fileExists(atPath: sockPath) {
            if Date().timeIntervalSince(start) > 2.0 {
                throw ProcessHostError.spawnFailed(
                    "agent socket did not appear at \(sockPath) within 2s"
                )
            }
            try? await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func attach(taskId: UUID) async throws -> TaskIO {
        let path = socketPath(taskId: taskId).path
        let fd = try Self.connectUnixSocket(path: path)
        return AgentClient(socketFD: fd, pid: 0)
    }

    func terminate(taskId: UUID) async throws {
        // Connect briefly and send a TERMINATE frame. The agent
        // SIGTERMs the inner child + exits, which removes the
        // socket. If there's already an attached client, this
        // works alongside — agent multiplexes accept().
        let path = socketPath(taskId: taskId).path
        guard FileManager.default.fileExists(atPath: path) else { return }
        let fd = try Self.connectUnixSocket(path: path)
        defer { Darwin.close(fd) }
        let frame = AgentProtocol.encode(.terminate, payload: Data())
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            _ = Darwin.write(fd, raw.baseAddress, raw.count)
        }
    }

    func discover() async throws -> Set<UUID> {
        // Stat-only. We used to connect+close as a liveness probe, but
        // that consumed the agent's preConnectBuffer (it flushes on
        // every accept) — meaning by the time the REAL attach came
        // along, claude's last screen had already been written to our
        // closed probe FD. The cost: a stale socket file from a
        // crashed agent will look "alive" here, attach will fail
        // (ECONNREFUSED), and we'll dispatch .taskExited. That's the
        // right cleanup path anyway; better than burning state on a
        // false-positive probe.
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: socketsDir, includingPropertiesForKeys: nil
        ) else { return [] }
        var out: Set<UUID> = []
        for f in files where f.pathExtension == "sock" {
            let stem = f.deletingPathExtension().lastPathComponent
            if let id = UUID(uuidString: stem) { out.insert(id) }
        }
        return out
    }

    func isAlive(taskId: UUID) async -> Bool {
        // Stat-only (see discover() for rationale). Connect probes
        // ate the agent's preConnectBuffer and produced blank
        // terminals on reattach.
        FileManager.default.fileExists(atPath: socketPath(taskId: taskId).path)
    }

    private static func connectUnixSocket(path: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 {
            throw ProcessHostError.socketConnectFailed("socket() failed: \(String(cString: strerror(errno)))")
        }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let maxPath = MemoryLayout.size(ofValue: addr.sun_path) - 1
        guard bytes.count <= maxPath else {
            Darwin.close(fd)
            throw ProcessHostError.socketConnectFailed("path too long: \(path)")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: maxPath + 1) { c in
                for (i, b) in bytes.enumerated() { c[i] = CChar(bitPattern: b) }
                c[bytes.count] = 0
            }
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc < 0 {
            let err = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ProcessHostError.socketConnectFailed("connect() failed: \(err)")
        }
        return fd
    }
}

// Fallback when the agent binary isn't installed yet.
final class UnavailableProcessHost: ProcessHost {
    func ensureReady() async throws {
        throw ProcessHostError.agentBinaryNotFound
    }
    func spawn(taskId: UUID, spec: ProcessSpec) async throws {
        throw ProcessHostError.agentBinaryNotFound
    }
    func attach(taskId: UUID) async throws -> TaskIO {
        throw ProcessHostError.agentBinaryNotFound
    }
    func terminate(taskId: UUID) async throws {}
    func discover() async throws -> Set<UUID> { [] }
    func isAlive(taskId: UUID) async -> Bool { false }
}
