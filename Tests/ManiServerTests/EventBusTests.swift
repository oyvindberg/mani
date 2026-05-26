import XCTest
@testable import ManiServer
import ManiCore

final class EventBusTests: XCTestCase {

    private func uuid(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
    }

    func test_publish_assignsMonotonicSeq() async {
        let bus = EventBus()
        let a = await bus.publish(.repoDeleted(id: uuid(1)))
        let b = await bus.publish(.repoDeleted(id: uuid(2)))
        let c = await bus.publish(.repoDeleted(id: uuid(3)))
        XCTAssertEqual(a.seq, 1)
        XCTAssertEqual(b.seq, 2)
        XCTAssertEqual(c.seq, 3)
        let current = await bus.currentSeq
        XCTAssertEqual(current, 3)
    }

    func test_subscriber_seesOnlyFuturePublishes() async {
        let bus = EventBus()
        await bus.publish(.repoDeleted(id: uuid(1)))  // pre-subscribe; missed
        let stream = await bus.subscribe()
        await bus.publish(.repoDeleted(id: uuid(2)))
        await bus.publish(.repoDeleted(id: uuid(3)))
        var iter = stream.makeAsyncIterator()
        let first = await iter.next()
        let second = await iter.next()
        XCTAssertEqual(first?.seq, 2)
        XCTAssertEqual(second?.seq, 3)
    }

    func test_multipleSubscribers_seeSameSequence() async {
        let bus = EventBus()
        let s1 = await bus.subscribe()
        let s2 = await bus.subscribe()
        await bus.publish(.repoDeleted(id: uuid(1)))
        await bus.publish(.repoDeleted(id: uuid(2)))
        var i1 = s1.makeAsyncIterator()
        var i2 = s2.makeAsyncIterator()
        let a1 = await i1.next()
        let a2 = await i2.next()
        let b1 = await i1.next()
        let b2 = await i2.next()
        XCTAssertEqual(a1?.seq, 1)
        XCTAssertEqual(a2?.seq, 1)
        XCTAssertEqual(b1?.seq, 2)
        XCTAssertEqual(b2?.seq, 2)
    }

    func test_droppedSubscriber_removesFromBus() async throws {
        let bus = EventBus()
        do {
            let stream = await bus.subscribe()
            _ = stream  // keep alive only inside this scope
            let count = await bus.subscriberCount
            XCTAssertEqual(count, 1)
        }
        // Give the stream's onTermination a chance to fire on the
        // bus's actor. AsyncStream cleanup is async, so we yield a
        // few times to let the Task scheduling settle.
        for _ in 0..<10 {
            await _Concurrency.Task.yield()
            try await _Concurrency.Task.sleep(nanoseconds: 5_000_000)
            let count = await bus.subscriberCount
            if count == 0 { return }
        }
        let final = await bus.subscriberCount
        XCTAssertEqual(final, 0, "subscriber leaked after stream went out of scope")
    }
}
