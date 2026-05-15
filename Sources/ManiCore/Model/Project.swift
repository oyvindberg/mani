import Foundation

public struct Project: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var color: String
    public var enabled: Bool
    // The project's main path. `git worktree add` and any "where
    // does this project live" question resolve from here. The
    // primary workspace (rendered like any other worktree row in the
    // sidebar) is the worktree whose `path` equals this rootDir.
    public var rootDir: URL
    public var worktrees: [Worktree]
    public var createdAt: Date
    // Optional override for the claude binary invocation used by this
    // project's tasks. nil = inherit Settings.claudeInvocation.
    public var claudeInvocation: String?

    public init(
        id: UUID,
        name: String,
        color: String,
        enabled: Bool,
        rootDir: URL,
        worktrees: [Worktree],
        createdAt: Date,
        claudeInvocation: String?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.enabled = enabled
        self.rootDir = rootDir
        self.worktrees = worktrees
        self.createdAt = createdAt
        self.claudeInvocation = claudeInvocation
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, enabled, rootDir, worktrees, createdAt, claudeInvocation
    }

    // Backward-compat decode for two historical shapes:
    //   1. Pre-rootDir-removal: Project had `rootDir` (this is what
    //      we're now re-adding) — round-trips cleanly.
    //   2. Post-rootDir-removal: Project had no rootDir but each
    //      Worktree carried a `primary: Bool`. The migration here
    //      digs that bool out of the raw worktree JSON and uses the
    //      primary worktree's path as the project rootDir. If no
    //      worktree had primary=true, we fall back to the first
    //      worktree's path. Last resort (no worktrees at all):
    //      ~/Mani so the field is at least non-empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.color = try c.decode(String.self, forKey: .color)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.worktrees = try c.decode([Worktree].self, forKey: .worktrees)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.claudeInvocation = try? c.decodeIfPresent(String.self, forKey: .claudeInvocation)

        if let stored = try? c.decodeIfPresent(URL.self, forKey: .rootDir) {
            self.rootDir = stored
        } else {
            // Migration from the post-rootDir-removal model: pull
            // the primary worktree's path out of the raw decode.
            // We re-parse the worktrees as a permissive dict-of-
            // dicts so we can read the dropped `primary` field.
            let rawWorktrees = (try? c.decode([RawWorktree].self, forKey: .worktrees)) ?? []
            let primaryPath = rawWorktrees.first(where: { $0.primary == true })?.path
                ?? rawWorktrees.first?.path
            if let primaryPath {
                self.rootDir = primaryPath
            } else {
                self.rootDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Mani")
            }
        }
    }

    // Permissive shape used solely by the rootDir-migration path. We
    // only care about path + primary; everything else is decoded by
    // the real Worktree initializer.
    private struct RawWorktree: Decodable {
        let path: URL
        let primary: Bool?
    }
}
