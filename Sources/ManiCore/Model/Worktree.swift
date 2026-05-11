import Foundation

public struct Worktree: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var path: URL
    public var kind: WorktreeKind
    public var enabled: Bool
    public var missing: Bool
    public var jobs: [Job]
    public var createdAt: Date
    // The "canonical" worktree of the project. Effect.createGitWorktree
    // uses the primary worktree's path as `repoRoot` for `git worktree
    // add`. At most one primary per project; setting a new primary
    // clears the old one. Optional only because legacy data may have
    // no primary set yet — the UI offers a "Make primary" action.
    public var primary: Bool

    public init(
        id: UUID,
        name: String,
        path: URL,
        kind: WorktreeKind,
        enabled: Bool,
        missing: Bool,
        jobs: [Job],
        createdAt: Date,
        primary: Bool
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.enabled = enabled
        self.missing = missing
        self.jobs = jobs
        self.createdAt = createdAt
        self.primary = primary
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, path, kind, enabled, missing, jobs, createdAt, primary
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.path = try c.decode(URL.self, forKey: .path)
        self.kind = try c.decode(WorktreeKind.self, forKey: .kind)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.missing = try c.decode(Bool.self, forKey: .missing)
        self.jobs = try c.decode([Job].self, forKey: .jobs)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.primary = (try? c.decodeIfPresent(Bool.self, forKey: .primary)) ?? false
    }
}

public enum WorktreeKind: Codable, Equatable {
    case git(branch: String, baseRef: String?)
    case folder
}
