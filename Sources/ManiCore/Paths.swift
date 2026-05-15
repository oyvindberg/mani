import Foundation

public struct WorktreePath: Codable, Equatable, Hashable {
    public let repo: UUID
    public let worktree: UUID

    public init(repo: UUID, worktree: UUID) {
        self.repo = repo
        self.worktree = worktree
    }

    private enum CodingKeys: String, CodingKey { case repo, worktree }
    private enum LegacyKeys: String, CodingKey { case project }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let r = try c.decodeIfPresent(UUID.self, forKey: .repo) {
            self.repo = r
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.repo = try legacy.decode(UUID.self, forKey: .project)
        }
        self.worktree = try c.decode(UUID.self, forKey: .worktree)
    }
}

public struct TaskPath: Codable, Equatable, Hashable {
    public let repo: UUID
    public let worktree: UUID
    public let task: UUID

    public init(repo: UUID, worktree: UUID, task: UUID) {
        self.repo = repo
        self.worktree = worktree
        self.task = task
    }

    public var worktreePath: WorktreePath {
        WorktreePath(repo: repo, worktree: worktree)
    }

    private enum CodingKeys: String, CodingKey { case repo, worktree, task }
    private enum LegacyKeys: String, CodingKey { case project }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let r = try c.decodeIfPresent(UUID.self, forKey: .repo) {
            self.repo = r
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.repo = try legacy.decode(UUID.self, forKey: .project)
        }
        self.worktree = try c.decode(UUID.self, forKey: .worktree)
        self.task = try c.decode(UUID.self, forKey: .task)
    }
}
