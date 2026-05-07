import Foundation

public struct Project: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var color: String
    public var rootDir: URL
    public var enabled: Bool
    public var worktrees: [Worktree]
    public var createdAt: Date

    public init(
        id: UUID,
        name: String,
        color: String,
        rootDir: URL,
        enabled: Bool,
        worktrees: [Worktree],
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.rootDir = rootDir
        self.enabled = enabled
        self.worktrees = worktrees
        self.createdAt = createdAt
    }
}
