import Foundation
import ManiCore
import ManiServer

// S2/S3 spike — drives ManiServer + EventBus with a canned timeline of
// Events so a connected client sees both the helloAck (with the
// current snapshot) and a live stream of EventEnvelopes. Validates the
// transport + EventBus broadcast path end-to-end before the mac app
// integration (next commit).
//
// Run:    swift run WebSocketSpike
// Test from another shell:
//
//   cat > /tmp/c.swift << 'SWIFT'
//   import Foundation
//   let t = URLSession.shared.webSocketTask(
//     with: URL(string: "ws://127.0.0.1:8765")!)
//   t.resume()
//   t.send(.string(#"{"op":"hello"}"#)) { _ in }
//   func receive() {
//     t.receive { result in
//       if case let .success(.string(s)) = result { print(s) }
//       receive()
//     }
//   }
//   receive()
//   RunLoop.main.run(until: .init(timeIntervalSinceNow: 8))
//   SWIFT
//   swift /tmp/c.swift
//
// Expected output: one helloAck frame followed by three event frames.

let host = "127.0.0.1"
let port = 8765

let bus = EventBus()

// Snapshot provider: at hello time, return the AppState we'd be in
// "right now." For the spike that's just .empty plus whatever events
// have been folded in. Real wiring (next commit) returns Store.state.
let snapshot: @Sendable () async -> AppState = { .empty }

let server = Server(
    bus: bus,
    serverVersion: "0.2.0-spike",
    snapshotProvider: snapshot
)

let channel: Channel
do {
    channel = try server.start(host: host, port: port)
} catch {
    FileHandle.standardError.write(Data("[spike] bind failed: \(error)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("[spike] listening on ws://\(host):\(port)\n".utf8))

// Fire a small timeline of fake events to exercise the broadcast.
// 2 s, 4 s, 6 s after start, drop an event onto the bus and let
// subscribed clients see them streamed.
_Concurrency.Task {
    try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
    await bus.publish(.repoCreated(Repo(
        id: UUID(),
        name: "spike-repo",
        color: "#ff0066",
        enabled: true,
        rootDir: URL(fileURLWithPath: "/tmp/spike"),
        projects: [],
        externalConvos: [],
        availableWorktrees: [],
        createdAt: Date(),
        claudeInvocation: nil,
        worktreeMode: .manual,
        managedWorktreesNamespace: nil
    )))

    try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
    await bus.publish(.repoRenamed(id: UUID(), name: "spike-repo-renamed"))

    try? await _Concurrency.Task.sleep(nanoseconds: 2_000_000_000)
    await bus.publish(.settingsUpdated(Settings(
        scrollbackCapBytes: 32 * 1024 * 1024,
        snapshotIntervalSeconds: 30,
        terminalTheme: "Solarized",
        terminalFontFamily: "",
        terminalFontSize: 14,
        claudeInvocation: "claude"
    )))
    FileHandle.standardError.write(Data("[spike] timeline complete\n".utf8))
}

// Re-export NIO's Channel here would be cleaner; spike just blocks on
// closeFuture via the same handle Server.start returned.
import NIOCore
try channel.closeFuture.wait()
