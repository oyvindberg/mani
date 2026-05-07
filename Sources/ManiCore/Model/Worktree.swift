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

    public init(
        id: UUID,
        name: String,
        path: URL,
        kind: WorktreeKind,
        enabled: Bool,
        missing: Bool,
        jobs: [Job],
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.kind = kind
        self.enabled = enabled
        self.missing = missing
        self.jobs = jobs
        self.createdAt = createdAt
    }
}

public enum WorktreeKind: Codable, Equatable {
    case git(branch: String, baseRef: String?)
    case folder
}
