import Foundation

public struct WorktreePath: Codable, Equatable, Hashable {
    public let project: UUID
    public let worktree: UUID

    public init(project: UUID, worktree: UUID) {
        self.project = project
        self.worktree = worktree
    }
}

public struct TaskPath: Codable, Equatable, Hashable {
    public let project: UUID
    public let worktree: UUID
    public let task: UUID

    public init(project: UUID, worktree: UUID, task: UUID) {
        self.project = project
        self.worktree = worktree
        self.task = task
    }

    public var worktreePath: WorktreePath {
        WorktreePath(project: project, worktree: worktree)
    }
}
