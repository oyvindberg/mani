import Foundation
import ManiCore

// Abstraction over "where state and actions live." The UI is written
// against this protocol so the same SwiftUI views drive both modes:
//
//   - LocalServerClient — the canonical in-proc runtime (reducer +
//     EffectRunner + agent host). What today's Mani.app boots into.
//
//   - RemoteServerClient — a WebSocket client that speaks the v0.2
//     wire protocol to an embedded mani-server on another mac. What
//     gets wired in when MANI_SERVER_URL is set.
//
// The surface mirrors the WS wire (state snapshot + event stream +
// action dispatch + taskIO) so the two impls translate 1:1 and the
// local path doesn't accidentally grow features the wire can't carry.
//
// Not Sendable for now — the local impl is @MainActor for its
// reducer/state hand-off, and RemoteServerClient owns its own
// internal isolation. Each conformer documents its threading.
public protocol ServerClient: AnyObject {
    // Current snapshot at the moment of read. Local: store.state.
    // Remote: cached last-known snapshot from helloAck / events.
    var currentState: AppState { get }

    // Snapshots emitted whenever the state changes. The stream yields
    // the initial snapshot synchronously on subscribe (so a fresh
    // consumer doesn't have to fall back to currentState first).
    var stateStream: AsyncStream<AppState> { get }

    // Committed events with monotonic sequence numbers. Same shape
    // the WS protocol carries — clients that want fine-grained event
    // observation (e.g., notifications, activity tracking) consume
    // this directly instead of diffing state snapshots.
    var eventStream: AsyncStream<SequencedEvent> { get }

    // Submit an Action. Local: runs through the reducer + applies +
    // persists + fires effects. Remote: serializes + sends as a
    // dispatch frame. The resulting Event(s) flow back through
    // eventStream / stateStream so the caller doesn't poll.
    func dispatch(_ action: Action) async

    // Return a TaskIO handle for a live task, or nil. Local: the
    // in-proc AgentClient / ManagedPTY. Remote: a RemoteTaskIO that
    // wraps subscribe/unsubscribe/taskInput/taskResize frames behind
    // the same TaskIO surface, so the renderer code is unchanged.
    func taskIO(for taskId: UUID) async -> TaskIO?
}
