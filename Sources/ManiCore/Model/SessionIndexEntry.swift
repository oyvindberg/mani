import Foundation

// One row in a project's sessions-index.json. Captures the metadata we
// need to render PastSessionRow without reading the (potentially huge)
// JSONL transcript. The transcript itself is gzipped alongside under
// projects/<project-uuid>/sessions/<sessionId>.jsonl.gz.
//
// `originatingCwd` is the cwd recorded inside the JSONL — used at boot
// to decide whether the originating worktree still exists in the
// project (`worktreeStillPresent` is computed at boot, not persisted,
// so renames of project state don't leave a stale flag behind).
//
// `archivedAt == nil` means: we know the session exists and have its
// summary metadata, but the transcript hasn't been copied yet (the
// session was "hot" — file mtime within the last 5 min — at sweep
// time). The next settled sweep will fill it in.
public struct SessionIndexEntry: Codable, Equatable {
    public var sessionId: String
    public var originatingCwd: String
    public var originatingWorktreeName: String
    public var firstUserMessage: String?
    public var lastMessageAt: Date?
    public var messageCount: Int
    public var transcriptBytes: Int
    public var archivedAt: Date?

    public init(
        sessionId: String,
        originatingCwd: String,
        originatingWorktreeName: String,
        firstUserMessage: String?,
        lastMessageAt: Date?,
        messageCount: Int,
        transcriptBytes: Int,
        archivedAt: Date?
    ) {
        self.sessionId = sessionId
        self.originatingCwd = originatingCwd
        self.originatingWorktreeName = originatingWorktreeName
        self.firstUserMessage = firstUserMessage
        self.lastMessageAt = lastMessageAt
        self.messageCount = messageCount
        self.transcriptBytes = transcriptBytes
        self.archivedAt = archivedAt
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
