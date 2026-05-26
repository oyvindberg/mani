import Foundation
import ManiCore

// Wire envelopes for the v0.2 protocol. Each server→client message is
// JSON-encoded with a top-level `op` discriminator. The inner Action /
// Event values use their own {kind, payload} envelope (see ManiCore's
// ActionWire / EventWire).
//
// Client → Server messages aren't yet typed — the spike accepts
// anything as a "say hello" trigger. When action dispatch lands (S4),
// the inbound parser switches on `op`.

public struct HelloAck: Encodable, Sendable {
    public let op: String
    public let sessionId: String
    public let serverVersion: String
    public let protocolVersion: Int
    public let snapshot: AppState
    public let lastEventSeq: UInt64

    public init(
        sessionId: String,
        serverVersion: String,
        protocolVersion: Int,
        snapshot: AppState,
        lastEventSeq: UInt64
    ) {
        self.op = "helloAck"
        self.sessionId = sessionId
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.snapshot = snapshot
        self.lastEventSeq = lastEventSeq
    }
}

public struct EventEnvelope: Encodable, Sendable {
    public let op: String
    public let seq: UInt64
    public let event: Event

    public init(seq: UInt64, event: Event) {
        self.op = "event"
        self.seq = seq
        self.event = event
    }
}

public struct ErrorEnvelope: Encodable, Sendable {
    public let op: String
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.op = "error"
        self.code = code
        self.message = message
    }
}

// Server → client: a chunk of raw PTY bytes for a task. `data` is
// base64-encoded so the JSON envelope stays text. The terminal byte
// stream is opaque to the protocol — it's whatever the PTY emitted
// (xterm escape sequences, UTF-8 text, sixel images). Clients feed
// the decoded bytes directly into a terminal emulator (libghostty on
// mac, Termux's view on Android).
public struct TaskOutputEnvelope: Encodable, Sendable {
    public let op: String
    public let taskId: UUID
    public let data: String  // base64

    public init(taskId: UUID, bytes: Data) {
        self.op = "taskOutput"
        self.taskId = taskId
        self.data = bytes.base64EncodedString()
    }
}
