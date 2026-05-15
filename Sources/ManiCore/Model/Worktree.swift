import Foundation

public struct Worktree: Codable, Equatable, Identifiable {
    public let id: UUID
    public var path: URL
    public var kind: WorktreeKind
    public var enabled: Bool
    public var missing: Bool
    public var tasks: [Task]
    public var createdAt: Date

    public init(
        id: UUID,
        path: URL,
        kind: WorktreeKind,
        enabled: Bool,
        missing: Bool,
        tasks: [Task],
        createdAt: Date
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.enabled = enabled
        self.missing = missing
        self.tasks = tasks
        self.createdAt = createdAt
    }

    // Identity for the sidebar: the directory basename. Worktrees don't
    // carry a user-given name — the directory and current git branch are
    // enough.
    public var displayName: String {
        URL(fileURLWithPath: path.path).lastPathComponent
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, kind, enabled, missing, tasks, createdAt
    }

    private enum LegacyKeys: String, CodingKey {
        case jobs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.path = try c.decode(URL.self, forKey: .path)
        self.kind = try c.decode(WorktreeKind.self, forKey: .kind)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.missing = try c.decode(Bool.self, forKey: .missing)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        // New shape uses `tasks`; old shape used `jobs`. Same element type
        // (Task decodes the old Job shape transparently — see Task.swift).
        // Legacy fields `name` and `primary` on the worktree are ignored.
        if let tasks = try c.decodeIfPresent([Task].self, forKey: .tasks) {
            self.tasks = tasks
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.tasks = (try? legacy.decodeIfPresent([Task].self, forKey: .jobs)) ?? []
        }
    }
}

public enum WorktreeKind: Codable, Equatable {
    case git(branch: String, baseRef: String?)
    case folder
}
