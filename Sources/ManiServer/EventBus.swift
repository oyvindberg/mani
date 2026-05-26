import Foundation
import ManiCore

// A SequencedEvent is an Event paired with a monotonic per-process seq
// the server assigns at publish time. Clients track lastEventSeq and
// can resume from there on reconnect (resume support is out of scope
// for this spike — added when persistence-based replay lands).
public struct SequencedEvent: Equatable, Sendable {
    public let seq: UInt64
    public let event: Event
    public init(seq: UInt64, event: Event) {
        self.seq = seq
        self.event = event
    }
}

// In-process pub/sub of Events with monotonic sequence numbers.
//
// publish(_:) increments `nextSeq`, tags the event, and yields it to
// every active subscriber's AsyncStream. The mac app's runtime
// (Store / EffectRunner / reducer dispatch path) calls publish whenever
// the reducer commits an Event; each WebSocket connection subscribes
// on hello and forwards everything it receives as a wire frame.
//
// Cleanup: the AsyncStream's onTermination removes the subscriber so
// dropped connections don't leak continuations.
public actor EventBus {
    private var nextSeq: UInt64 = 1
    private var subscribers: [UUID: AsyncStream<SequencedEvent>.Continuation] = [:]

    public init() {}

    public var currentSeq: UInt64 {
        nextSeq - 1
    }

    @discardableResult
    public func publish(_ event: Event) -> SequencedEvent {
        let s = SequencedEvent(seq: nextSeq, event: event)
        nextSeq += 1
        for cont in subscribers.values {
            cont.yield(s)
        }
        return s
    }

    public func subscribe() -> AsyncStream<SequencedEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SequencedEvent>.makeStream()
        subscribers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            _Concurrency.Task { await self.remove(id) }
        }
        return stream
    }

    private func remove(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // Test/diagnostic hook.
    public var subscriberCount: Int {
        subscribers.count
    }
}
