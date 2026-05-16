import Foundation

// Identifies a Project inside a Repo. Replaces the old WorktreePath.
public struct ProjectPath: Codable, Equatable, Hashable {
    public let repo: UUID
    public let project: UUID

    public init(repo: UUID, project: UUID) {
        self.repo = repo
        self.project = project
    }

    private enum CodingKeys: String, CodingKey { case repo, project }
    // Legacy: pre-refactor used `worktree` for the same slot.
    private enum LegacyKeys: String, CodingKey { case worktree }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.repo = try c.decode(UUID.self, forKey: .repo)
        if let p = try c.decodeIfPresent(UUID.self, forKey: .project) {
            self.project = p
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.project = try legacy.decode(UUID.self, forKey: .worktree)
        }
    }
}

// Identifies a Task inside a Project inside a Repo.
public struct TaskPath: Codable, Equatable, Hashable {
    public let repo: UUID
    public let project: UUID
    public let task: UUID

    public init(repo: UUID, project: UUID, task: UUID) {
        self.repo = repo
        self.project = project
        self.task = task
    }

    public var projectPath: ProjectPath {
        ProjectPath(repo: repo, project: project)
    }

    private enum CodingKeys: String, CodingKey { case repo, project, task }
    private enum LegacyKeys: String, CodingKey { case worktree }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.repo = try c.decode(UUID.self, forKey: .repo)
        self.task = try c.decode(UUID.self, forKey: .task)
        if let p = try c.decodeIfPresent(UUID.self, forKey: .project) {
            self.project = p
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.project = try legacy.decode(UUID.self, forKey: .worktree)
        }
    }
}

// Identifies an ExternalConvo inside a Repo.
public struct ExternalConvoPath: Codable, Equatable, Hashable {
    public let repo: UUID
    public let convo: UUID

    public init(repo: UUID, convo: UUID) {
        self.repo = repo
        self.convo = convo
    }
}
