import Foundation

public struct WorktreePath: Codable, Equatable, Hashable {
    public let project: UUID
    public let worktree: UUID

    public init(project: UUID, worktree: UUID) {
        self.project = project
        self.worktree = worktree
    }
}

public struct JobPath: Codable, Equatable, Hashable {
    public let project: UUID
    public let worktree: UUID
    public let job: UUID

    public init(project: UUID, worktree: UUID, job: UUID) {
        self.project = project
        self.worktree = worktree
        self.job = job
    }

    public var worktreePath: WorktreePath {
        WorktreePath(project: project, worktree: worktree)
    }
}
