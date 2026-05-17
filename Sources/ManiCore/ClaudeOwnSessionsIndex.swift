import Foundation

// Reader for claude's own sessions-index.json file (one per slug
// dir under ~/.claude/projects/<slug>/). Format example:
//
//   { "version": 1,
//     "originalPath": "/Users/me/foo",
//     "entries": [
//       { "sessionId": "abc-123",
//         "fullPath": "/Users/me/.claude/projects/-Users-me-foo/abc-123.jsonl",
//         "firstPrompt": "fix the bug…",
//         "summary": "Bug fix in widget renderer",
//         "messageCount": 58,
//         "modified": "2025-09-01T12:34:56.789Z",
//         "projectPath": "/Users/me/foo",
//         "gitBranch": "main",
//         "isSidechain": false,
//         "fileMtime": "..." }
//     ]}
//
// Lives in ManiCore so the parser can be unit-tested in isolation
// from the App target.
public enum ClaudeOwnSessionsIndex {

    public struct Record: Equatable {
        public let sessionId: String
        public let fullPath: String
        public let firstPrompt: String?
        public let summary: String?
        public let messageCount: Int?
        public let modified: Date?
        // The working directory of the claude session. Claude's JSON
        // calls this `projectPath`; Mani uses `cwd` everywhere to
        // avoid colliding with our own Project type.
        public let cwd: String

        public init(
            sessionId: String,
            fullPath: String,
            firstPrompt: String?,
            summary: String?,
            messageCount: Int?,
            modified: Date?,
            cwd: String
        ) {
            self.sessionId = sessionId
            self.fullPath = fullPath
            self.firstPrompt = firstPrompt
            self.summary = summary
            self.messageCount = messageCount
            self.modified = modified
            self.cwd = cwd
        }
    }

    public struct Parsed: Equatable {
        public let entries: [Record]
        public init(entries: [Record]) { self.entries = entries }
    }

    public static func parse(data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let entriesRaw = root["entries"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var out: [Record] = []
        for raw in entriesRaw {
            guard let sid = raw["sessionId"] as? String,
                  let fullPath = raw["fullPath"] as? String,
                  let cwd = raw["projectPath"] as? String
            else { continue }
            let modified: Date? = (raw["modified"] as? String).flatMap {
                iso.date(from: $0) ?? isoNoFrac.date(from: $0)
            }
            out.append(Record(
                sessionId: sid,
                fullPath: fullPath,
                firstPrompt: raw["firstPrompt"] as? String,
                summary: raw["summary"] as? String,
                messageCount: raw["messageCount"] as? Int,
                modified: modified,
                cwd: cwd
            ))
        }
        return Parsed(entries: out)
    }
}
