import Foundation

public struct Project: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var color: String
    public var rootDir: URL
    public var enabled: Bool
    public var worktrees: [Worktree]
    public var createdAt: Date
    // Optional per-project Ghostty theme name. When set, all terminal
    // panes rooted in this project's jobs use this theme instead of the
    // global Settings.terminalTheme. nil = inherit from settings.
    public var terminalTheme: String?

    public init(
        id: UUID,
        name: String,
        color: String,
        rootDir: URL,
        enabled: Bool,
        worktrees: [Worktree],
        createdAt: Date,
        terminalTheme: String?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.rootDir = rootDir
        self.enabled = enabled
        self.worktrees = worktrees
        self.createdAt = createdAt
        self.terminalTheme = terminalTheme
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, rootDir, enabled, worktrees, createdAt, terminalTheme
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.color = try c.decode(String.self, forKey: .color)
        self.rootDir = try c.decode(URL.self, forKey: .rootDir)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.worktrees = try c.decode([Worktree].self, forKey: .worktrees)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.terminalTheme = try? c.decodeIfPresent(String.self, forKey: .terminalTheme)
    }
}
