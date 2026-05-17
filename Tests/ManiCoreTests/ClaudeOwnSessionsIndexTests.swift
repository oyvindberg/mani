import XCTest
@testable import ManiCore

// Parses the real claude sessions-index.json shape that lives at
// ~/.claude/projects/<slug>/sessions-index.json. The fixture is a
// verbatim copy of a real index — if claude changes the schema,
// this test breaks fast and loudly instead of silently producing
// empty external-convo metadata in the UI.
final class ClaudeOwnSessionsIndexTests: XCTestCase {

    func test_parse_realClaudeFixture_returnsAllEntries() throws {
        let data = try fixtureData()
        guard let parsed = ClaudeOwnSessionsIndex.parse(data: data) else {
            return XCTFail("parser returned nil on real claude index")
        }
        XCTAssertFalse(
            parsed.entries.isEmpty,
            "expected at least one entry — empty means a required key (sessionId/fullPath/projectPath) didn't decode"
        )
    }

    func test_parse_realClaudeFixture_populatesRequiredFields() throws {
        let data = try fixtureData()
        let parsed = try XCTUnwrap(ClaudeOwnSessionsIndex.parse(data: data))
        let first = try XCTUnwrap(parsed.entries.first)
        XCTAssertFalse(first.sessionId.isEmpty)
        XCTAssertFalse(first.fullPath.isEmpty)
        XCTAssertFalse(
            first.cwd.isEmpty,
            "cwd is the claude `projectPath` field; the sweeper uses it to match against repo workspace paths and silently drops entries with an empty cwd"
        )
    }

    func test_parse_realClaudeFixture_decodesAtLeastSomeOptionals() throws {
        let data = try fixtureData()
        let parsed = try XCTUnwrap(ClaudeOwnSessionsIndex.parse(data: data))
        // Not every entry has firstPrompt / messageCount, but the
        // bulk should — if it's zero, our optional-key strings are
        // wrong.
        let withFirstPrompt = parsed.entries.filter { $0.firstPrompt != nil }
        let withMessageCount = parsed.entries.filter { $0.messageCount != nil }
        XCTAssertGreaterThan(
            withFirstPrompt.count, 0,
            "expected at least one entry to carry firstPrompt; if zero, the key name probably regressed"
        )
        XCTAssertGreaterThan(
            withMessageCount.count, 0,
            "expected at least one entry to carry messageCount"
        )
    }

    // MARK: - Synthetic edge cases

    func test_parse_emptyEntries_returnsEmptyParsed() throws {
        let data = Data("""
        {"version": 1, "entries": []}
        """.utf8)
        let parsed = try XCTUnwrap(ClaudeOwnSessionsIndex.parse(data: data))
        XCTAssertTrue(parsed.entries.isEmpty)
    }

    func test_parse_missingEntriesKey_returnsNil() {
        let data = Data(#"{"version": 1}"#.utf8)
        XCTAssertNil(ClaudeOwnSessionsIndex.parse(data: data))
    }

    func test_parse_entryMissingProjectPath_isSkipped() throws {
        // The sweeper uses cwd to route entries to a repo. An entry
        // without projectPath has nothing to match against, so we
        // skip it rather than producing a bogus default.
        let data = Data("""
        {"version": 1, "entries": [
          {"sessionId": "good", "fullPath": "/foo.jsonl", "projectPath": "/Users/me/repo"},
          {"sessionId": "bad",  "fullPath": "/bar.jsonl"}
        ]}
        """.utf8)
        let parsed = try XCTUnwrap(ClaudeOwnSessionsIndex.parse(data: data))
        XCTAssertEqual(parsed.entries.map(\.sessionId), ["good"])
    }

    func test_parse_minimalRecord_mapsProjectPathToCwd() throws {
        // Explicit assertion that the `projectPath` JSON key lands
        // on our `cwd` field — regressing this key produced empty
        // sidebar metadata for every external convo in the wild.
        let data = Data("""
        {"version": 1, "entries": [
          {"sessionId": "s", "fullPath": "/f", "projectPath": "/Users/me/x"}
        ]}
        """.utf8)
        let parsed = try XCTUnwrap(ClaudeOwnSessionsIndex.parse(data: data))
        XCTAssertEqual(parsed.entries.first?.cwd, "/Users/me/x")
    }

    // MARK: - Helpers

    private func fixtureData() throws -> Data {
        guard let url = Bundle.module.url(
            forResource: "claude-sessions-index",
            withExtension: "json",
            subdirectory: "Fixtures"
        ) else {
            // Fallback path layout — Swift PM has flipped between
            // including `subdirectory:` resources at the bundle root
            // and under their folder in different toolchains.
            if let flat = Bundle.module.url(
                forResource: "claude-sessions-index",
                withExtension: "json"
            ) {
                return try Data(contentsOf: flat)
            }
            throw XCTSkip("fixture missing — Tests/ManiCoreTests/Fixtures/claude-sessions-index.json")
        }
        return try Data(contentsOf: url)
    }
}
