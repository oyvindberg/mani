import Foundation

public struct Repo: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var color: String
    public var enabled: Bool
    // The repo's main path. `git worktree add` and any "where does
    // this repo live" question resolve from here.
    public var rootDir: URL
    public var projects: [Project]
    // Claude conversations discovered outside Mani (via the FSEvents
    // watcher on ~/.claude/projects). They sit alongside projects
    // until the user adopts one into a project.
    public var externalConvos: [ExternalConvo]
    public var createdAt: Date
    // Optional override for the claude binary invocation. nil =
    // inherit Settings.claudeInvocation.
    public var claudeInvocation: String?

    public init(
        id: UUID,
        name: String,
        color: String,
        enabled: Bool,
        rootDir: URL,
        projects: [Project],
        externalConvos: [ExternalConvo],
        createdAt: Date,
        claudeInvocation: String?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.enabled = enabled
        self.rootDir = rootDir
        self.projects = projects
        self.externalConvos = externalConvos
        self.createdAt = createdAt
        self.claudeInvocation = claudeInvocation
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, enabled, rootDir
        case projects, externalConvos
        case createdAt, claudeInvocation
    }

    // Legacy shape: Repo had `worktrees: [Worktree]`. Each Worktree
    // had its own tasks list, mixing Mani-spawned and external claude
    // tasks. The migration here:
    //   - Each Worktree becomes a Project with the same UUID, name
    //     defaulted to the workspace dir basename.
    //   - Mani-spawned tasks stay in Project.tasks.
    //   - External-claude tasks (spec.command == "(external claude)")
    //     are pulled out and re-shaped as Repo.externalConvos.
    private enum LegacyKeys: String, CodingKey {
        case worktrees
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.color = try c.decode(String.self, forKey: .color)
        self.enabled = try c.decode(Bool.self, forKey: .enabled)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        self.claudeInvocation = try? c.decodeIfPresent(String.self, forKey: .claudeInvocation)
        self.rootDir = try c.decode(URL.self, forKey: .rootDir)

        if let projects = try c.decodeIfPresent([Project].self, forKey: .projects) {
            self.projects = projects
            self.externalConvos = (try? c.decodeIfPresent(
                [ExternalConvo].self, forKey: .externalConvos
            )) ?? []
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            let worktrees = try legacy.decode([LegacyWorktree].self, forKey: .worktrees)
            var projects: [Project] = []
            var convos: [ExternalConvo] = []
            for wt in worktrees {
                var keep: [Task] = []
                for t in wt.tasks {
                    if t.spec.command == "(external claude)",
                       case let .claude(sid?) = t.kind {
                        convos.append(ExternalConvo(
                            id: t.id,
                            sessionId: sid,
                            cwd: t.spec.cwd,
                            firstSeenAt: t.createdAt
                        ))
                    } else {
                        keep.append(t)
                    }
                }
                let kind: WorkspaceKind
                switch wt.kind {
                case .folder:
                    kind = .folder
                case let .git(branch, baseRef):
                    kind = .gitWorktree(branch: branch, baseRef: baseRef)
                }
                projects.append(Project(
                    id: wt.id,
                    name: URL(fileURLWithPath: wt.path.path).lastPathComponent,
                    workspace: Workspace(path: wt.path, kind: kind, missing: wt.missing),
                    tasks: keep,
                    archivedAt: nil,
                    createdAt: wt.createdAt
                ))
            }
            self.projects = projects
            self.externalConvos = convos
        }
    }
}

// Decode-only shadow of the pre-refactor Worktree. Used by the Repo
// migration path; the real Worktree type is gone.
private struct LegacyWorktree: Decodable {
    let id: UUID
    let path: URL
    let kind: LegacyKind
    let missing: Bool
    let tasks: [Task]
    let createdAt: Date

    enum LegacyKind: Codable, Equatable {
        case folder
        case git(branch: String, baseRef: String?)
    }

    private enum CodingKeys: String, CodingKey {
        case id, path, kind, missing, tasks, createdAt
    }
    private enum LegacyTasksKeys: String, CodingKey { case jobs }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.path = try c.decode(URL.self, forKey: .path)
        self.kind = try c.decode(LegacyKind.self, forKey: .kind)
        self.missing = try c.decode(Bool.self, forKey: .missing)
        self.createdAt = try c.decode(Date.self, forKey: .createdAt)
        if let t = try c.decodeIfPresent([Task].self, forKey: .tasks) {
            self.tasks = t
        } else {
            let legacy = try decoder.container(keyedBy: LegacyTasksKeys.self)
            self.tasks = (try? legacy.decodeIfPresent([Task].self, forKey: .jobs)) ?? []
        }
    }
}
