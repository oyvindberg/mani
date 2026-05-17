import Foundation

// One row in a repo's sessions-index.json. Captures the metadata we
// need to render an external-convo row without reading the
// (potentially huge) JSONL transcript on every sweep.
//
// `originatingCwd` is the cwd recorded inside the JSONL.
//
// `archivedAt == nil` means: we know the session exists and have its
// summary metadata, but the transcript hasn't been copied yet (the
// session was "hot" or claude rotated it away). The next settled
// sweep will fill it in if/when the JSONL reappears.
//
// `sourceFileMtime` is the mtime of the .jsonl on disk when we last
// parsed it. Used by the sweeper to skip re-parsing unchanged files —
// the Phase-2 JSONL scan is the expensive part of a sweep, and most
// sessions are quiescent between scans.
public struct SessionIndexEntry: Codable, Equatable {
    public var sessionId: String
    public var originatingCwd: String
    public var originatingWorktreeName: String
    public var firstUserMessage: String?
    public var lastMessageAt: Date?
    public var messageCount: Int
    public var transcriptBytes: Int
    public var archivedAt: Date?
    public var sourceFileMtime: Date?

    public init(
        sessionId: String,
        originatingCwd: String,
        originatingWorktreeName: String,
        firstUserMessage: String?,
        lastMessageAt: Date?,
        messageCount: Int,
        transcriptBytes: Int,
        archivedAt: Date?,
        sourceFileMtime: Date?
    ) {
        self.sessionId = sessionId
        self.originatingCwd = originatingCwd
        self.originatingWorktreeName = originatingWorktreeName
        self.firstUserMessage = firstUserMessage
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.transcriptBytes = transcriptBytes
        self.archivedAt = archivedAt
        self.sourceFileMtime = sourceFileMtime
    }

    private enum CodingKeys: String, CodingKey {
        case sessionId, originatingCwd, originatingWorktreeName
        case firstUserMessage, lastMessageAt, messageCount
        case transcriptBytes, archivedAt, sourceFileMtime
    }

    // Custom decode tolerates entries written before sourceFileMtime
    // existed — they'll re-parse once (re-stamping the field) and
    // then take the fast path on subsequent sweeps.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.sessionId = try c.decode(String.self, forKey: .sessionId)
        self.originatingCwd = try c.decode(String.self, forKey: .originatingCwd)
        self.originatingWorktreeName = try c.decode(String.self, forKey: .originatingWorktreeName)
        self.firstUserMessage = try c.decodeIfPresent(String.self, forKey: .firstUserMessage)
        self.lastMessageAt = try c.decodeIfPresent(Date.self, forKey: .lastMessageAt)
        self.messageCount = try c.decode(Int.self, forKey: .messageCount)
        self.transcriptBytes = try c.decode(Int.self, forKey: .transcriptBytes)
        self.archivedAt = try c.decodeIfPresent(Date.self, forKey: .archivedAt)
        self.sourceFileMtime = try c.decodeIfPresent(Date.self, forKey: .sourceFileMtime)
    }
}

// Top-level on-disk shape of sessions-index.json. Carrying a
// schemaVersion lets us evolve fields without losing data — same
// pattern as state.json.
public struct SessionIndex: Codable, Equatable {
    public var schemaVersion: Int
    public var entries: [SessionIndexEntry]

    public init(schemaVersion: Int, entries: [SessionIndexEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    public static var empty: SessionIndex {
        SessionIndex(schemaVersion: 1, entries: [])
    }
}
