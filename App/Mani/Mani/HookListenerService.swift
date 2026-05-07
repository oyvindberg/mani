import Foundation
import Darwin

// In-process Unix domain socket server for Claude Code hook envelopes.
// Bundled with the app, listens on ~/Library/Application Support/Mani/hook.sock.
// The shim binary (Spikes/HookSpike/HookShim, eventually moved into the .app
// bundle as a Resource) connects here when Claude fires a hook.
//
// Validated by Spike 3 — sub-10 ms latency from shim invocation to listener
// receipt on macOS. Walking-skeleton scope: receive envelopes, expose them
// for the UI. Auto-registration of hooks in ~/.claude/settings.json (with
// merge-don't-overwrite, per docs/claude-integration.md) is deferred.

final class HookListenerService: ObservableObject {

    struct ReceivedEnvelope: Identifiable {
        let id = UUID()
        let receivedAt: Date
        let payload: String
    }

    @Published private(set) var receivedCount: Int = 0
    @Published private(set) var lastEnvelope: ReceivedEnvelope?

    let socketPath: String
    private var sock: Int32 = -1
    private var running = false

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func start() {
        guard !running else { return }
        running = true

        unlink(socketPath)

        sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else {
            NSLog("HookListenerService: socket() failed errno=\(errno)")
            running = false
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 104) { cptr in
                for i in 0..<min(pathBytes.count, 103) {
                    cptr[i] = CChar(pathBytes[i])
                }
                cptr[min(pathBytes.count, 103)] = 0
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)

        let bound = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(sock, sockaddrPtr, len)
            }
        }
        guard bound == 0 else {
            NSLog("HookListenerService: bind() failed errno=\(errno)")
            close(sock)
            sock = -1
            running = false
            return
        }
        guard listen(sock, 16) == 0 else {
            NSLog("HookListenerService: listen() failed errno=\(errno)")
            close(sock)
            sock = -1
            running = false
            return
        }

        NSLog("HookListenerService: listening on \(socketPath)")
        let listenSock = sock
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.acceptLoop(serverSock: listenSock)
        }
    }

    func stop() {
        running = false
        if sock >= 0 {
            close(sock)
            sock = -1
        }
        unlink(socketPath)
    }

    private func acceptLoop(serverSock: Int32) {
        while running {
            let client = accept(serverSock, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                if !running { break }
                NSLog("HookListenerService: accept() failed errno=\(errno)")
                continue
            }
            handleConnection(client: client)
        }
    }

    private func handleConnection(client: Int32) {
        defer { close(client) }
        var data = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(client, &buf, 4096)
            if n <= 0 { break }
            data.append(buf, count: n)
        }
        let payload = String(data: data, encoding: .utf8) ?? "(\(data.count) non-utf8 bytes)"
        let envelope = ReceivedEnvelope(receivedAt: Date(), payload: payload)
        let summary = HookListenerService.summarise(payload: payload)
        DispatchQueue.main.async { [weak self] in
            self?.receivedCount += 1
            self?.lastEnvelope = envelope
            NotificationService.shared.post(
                title: "Claude hook",
                body: summary
            )
        }
    }

    private static func summarise(payload: String) -> String {
        // Best-effort: extract `hook_event_name` from the inner payload JSON.
        // Falls back to a generic preview.
        if let data = payload.data(using: .utf8),
           let outer = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let inner = outer["payload"] as? String,
           let innerData = inner.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: innerData) as? [String: Any],
           let event = json["hook_event_name"] as? String {
            return event
        }
        return String(payload.prefix(80))
    }
}
