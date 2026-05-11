import Foundation

public struct Project: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var color: String
    public var enabled: Bool
    public var worktrees: [Worktree]
    public var createdAt: Date
    // Optional override for the claude binary invocation used by this
    // project's tasks. nil = inherit Settings.claudeInvocation. The
    // resolved invocation is the prefix; ClaudeTaskSpec.make appends
    // `--resume <sid>` for resume flows.
    public var claudeInvocation: String?

    public init(
        id: UUID,
        name: String,
        color: String,
        enabled: Bool,
        worktrees: [Worktree],
        createdAt: Date,
        claudeInvocation: String?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.enabled = enabled
        self.worktrees = worktrees
        self.createdAt = createdAt
        self.claudeInvocation = claudeInvocation
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, enabled, worktrees, createdAt, claudeInvocation
    }

    // Backward-compat: state.json files written before the rootDir
    // removal still carry that field. Ignore it on decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.color = try c.decode(String.self, forKey: .color)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.worktrees = try c.decode([Worktree].self, forKey: .worktrees)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.claudeInvocation = try? c.decodeIfPresent(String.self, forKey: .claudeInvocation)
    }
}
