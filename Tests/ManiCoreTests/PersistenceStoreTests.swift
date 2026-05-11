import XCTest
@testable import ManiCore

// Spike 5 flagged the .bak fallback path as not exercised by the 1000-cycle
// crash harness because compact() is sub-millisecond. These tests pre-stage
// the on-disk files directly to drive each branch of the recovery decision.

final class PersistenceStoreTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mani-persistence-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        root = dir
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func writeJSON(_ value: AppState, to url: URL) throws {
        let data = try JSONEncoder().encode(value)
        try data.write(to: url)
    }

    private func sampleState(name: String) -> AppState {
        var s = AppState.empty
        s.projects.append(Project(
            id: UUID(),
            name: name,
            color: "#abcdef",
            enabled: true,
            worktrees: [],
            createdAt: Date(),
            claudeInvocation: nil
        ))
        return s
    }

    func test_recover_readsStateJsonWhenPresent() throws {
        let store = try PersistenceStore(rootDir: root)
        try writeJSON(sampleState(name: "primary"), to: store.stateURL)
        let (recovered, report) = try store.recover()
        XCTAssertEqual(report.snapshotSource, "state.json")
        XCTAssertEqual(recovered.projects.first?.name, "primary")
    }

    func test_recover_fallsBackToBakWhenStateJsonMissing() throws {
        let store = try PersistenceStore(rootDir: root)
        try writeJSON(sampleState(name: "from-bak"), to: store.stateBakURL)
        let (recovered, report) = try store.recover()
        XCTAssertTrue(report.snapshotSource.contains("bak"))
        XCTAssertEqual(recovered.projects.first?.name, "from-bak")
    }

    func test_recover_promotesNewWhenStateJsonMissingAndNewExists() throws {
        let store = try PersistenceStore(rootDir: root)
        try writeJSON(sampleState(name: "from-bak"), to: store.stateBakURL)
        try writeJSON(sampleState(name: "from-new"), to: store.stateNewURL)
        let (recovered, report) = try store.recover()
        XCTAssertTrue(report.snapshotSource.contains("new"))
        XCTAssertEqual(recovered.projects.first?.name, "from-new")
    }

    func test_recover_returnsEmptyWhenNothingExists() throws {
        let store = try PersistenceStore(rootDir: root)
        let (recovered, report) = try store.recover()
        XCTAssertEqual(report.snapshotSource, "empty")
        XCTAssertTrue(recovered.projects.isEmpty)
    }

    func test_compact_thenRecover_roundtripsStateAndTruncatesEvents() throws {
        let store = try PersistenceStore(rootDir: root)
        let state = sampleState(name: "persisted")
        try store.appendEvent(.projectCreated(state.projects[0]))
        try store.compact(state)
        // events.jsonl should be truncated.
        let evSize = (try? FileManager.default.attributesOfItem(atPath: store.eventsURL.path))?[.size] as? Int
        XCTAssertEqual(evSize ?? -1, 0)
        // state.json should round-trip.
        let (recovered, report) = try store.recover()
        XCTAssertEqual(report.snapshotSource, "state.json")
        XCTAssertEqual(recovered.projects.first?.name, "persisted")
        // Persist + apply should be idempotent across recovery — no duplicate.
        XCTAssertEqual(recovered.projects.count, 1)
    }
}
