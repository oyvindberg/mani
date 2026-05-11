import XCTest
@testable import ManiCore

final class SessionIndexTests: XCTestCase {

    func test_index_roundtrip_preservesAllFields() throws {
        let original = SessionIndex(
            schemaVersion: 1,
            entries: [
                SessionIndexEntry(
                    sessionId: "abc-123",
                    originatingCwd: "/Users/me/pr/typr-2",
                    originatingWorktreeName: "typr-2",
                    firstUserMessage: "hello world",
                    lastMessageAt: Date(timeIntervalSince1970: 1_700_000_000),
                    messageCount: 42,
                    transcriptBytes: 12345,
                    archivedAt: Date(timeIntervalSince1970: 1_700_000_100)
                ),
                SessionIndexEntry(
                    sessionId: "def-456",
                    originatingCwd: "/Users/me/pr/typr",
                    originatingWorktreeName: "typr",
                    firstUserMessage: nil,
                    lastMessageAt: nil,
                    messageCount: 0,
                    transcriptBytes: 0,
                    archivedAt: nil
                ),
            ]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(SessionIndex.self, from: data)

        XCTAssertEqual(decoded, original)
    }

    func test_empty_isWellDefined() {
        let empty = SessionIndex.empty
        XCTAssertEqual(empty.schemaVersion, 1)
        XCTAssertTrue(empty.entries.isEmpty)
    }
}
