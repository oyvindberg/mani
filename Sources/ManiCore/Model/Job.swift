import Foundation

// "Job" is the internal type name for what we call a "task" in the UI and in
// conversation. Renamed to avoid endless ambiguity with Swift's _Concurrency.Task.
public struct Job: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var kind: JobKind
    public var enabled: Bool
    public var status: JobStatus
    public var primary: ProcessSpec
    public var auxiliary: [ProcessSpec]
    public var unread: Int
    public var createdAt: Date
    public var completedAt: Date?
    // True iff the user has explicitly renamed this Job via the UI.
    // Tracked separately from `name` because the auto-generated default
    // names ("claude", "claude (resumed 78f5c2)", "shell") can collide
    // with user-chosen names that happen to match the same string. The
    // dedupe sweep prefers user-renamed Jobs as the survivor so their
    // rename is never silently dropped.
    public var renamed: Bool

    public init(
        id: UUID,
        name: String,
        kind: JobKind,
        enabled: Bool,
        status: JobStatus,
        primary: ProcessSpec,
        auxiliary: [ProcessSpec],
        unread: Int,
        createdAt: Date,
        completedAt: Date?,
        renamed: Bool
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.enabled = enabled
        self.status = status
        self.primary = primary
        self.auxiliary = auxiliary
        self.unread = unread
        self.createdAt = createdAt
        self.completedAt = completedAt
        self.renamed = renamed
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, enabled, status, primary, auxiliary
        case unread, createdAt, completedAt, renamed
    }

    // Backward-compat decode: state.json files written before `renamed`
    // existed default it to false (the safe answer for legacy entries —
    // dedupe sweep will fall back to live-pid / unread / createdAt for
    // those, which is identical to its pre-`renamed` behavior).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id          = try c.decode(UUID.self,        forKey: .id)
        self.name        = try c.decode(String.self,      forKey: .name)
        self.kind        = try c.decode(JobKind.self,     forKey: .kind)
        self.enabled     = try c.decode(Bool.self,        forKey: .enabled)
        self.status      = try c.decode(JobStatus.self,   forKey: .status)
        self.primary     = try c.decode(ProcessSpec.self, forKey: .primary)
        self.auxiliary   = try c.decode([ProcessSpec].self, forKey: .auxiliary)
        self.unread      = try c.decode(Int.self,         forKey: .unread)
        self.createdAt   = try c.decode(Date.self,        forKey: .createdAt)
        self.completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        self.renamed     = (try? c.decodeIfPresent(Bool.self, forKey: .renamed)) ?? false
    }
}

public enum JobKind: Codable, Equatable {
    case claude(sessionId: String?)
    case shell
    case custom(label: String)
}

public enum JobStatus: String, Codable, Equatable {
    case running
    case idle
    case stopped
    case completed
    case failed
}
