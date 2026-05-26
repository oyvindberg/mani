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

// For the spike, "dispatch" doesn't run through a real reducer.
// Re-publish the inbound Event as if the reducer had emitted it,
// just to demonstrate the round-trip from the client's perspective.
// Real ManiApp wires this to store.dispatch.
let dispatcher: @Sendable (Action) async -> Void = { action in
    FileHandle.standardError.write(Data("[spike] dispatch arrived: \(action)\n".utf8))
}

// No real TaskIO in the spike. Subscriber returns nil (no such task)
// so the client gets a noSuchTask error if it tries — sufficient to
// verify wiring without spawning a PTY.
let taskOutputSubscriber: @Sendable (UUID, @escaping @Sendable (Data) -> Void) async -> (@Sendable () -> Void)? = { _, _ in nil }

// No real TaskIO in the spike — input/resize are no-ops.
let taskInputHandler: @Sendable (UUID, Data) async -> Void = { _, _ in }
let taskResizeHandler: @Sendable (UUID, UInt16, UInt16) async -> Void = { _, _, _ in }

// Fixed token for the spike so the test-client snippet at the top of
// the file always knows it. Real ManiApp generates a per-install UUID.
let spikeToken = "spike-token"
FileHandle.standardError.write(Data("[spike] auth token: \(spikeToken)\n".utf8))

let server = Server(
    bus: bus,
    serverVersion: "0.2.0-spike",
    token: spikeToken,
    snapshotProvider: snapshot,
    actionDispatcher: dispatcher,
    taskOutputSubscriber: taskOutputSubscriber,
    taskInputHandler: taskInputHandler,
    taskResizeHandler: taskResizeHandler
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
