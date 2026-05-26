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
    // Workspace directories that belong to the repo but aren't
    // bound to an active project right now (typically: orphaned by
    // archiving a manual-worktree project). Surface them at the
    // repo level so the user can spawn a new project against the
    // same directory without re-discovering it from the
    // filesystem.
    public var availableWorktrees: [AvailableWorktree]
    public var createdAt: Date
    // Optional override for the claude binary invocation. nil =
    // inherit Settings.claudeInvocation.
    public var claudeInvocation: String?
    // Worktree lifecycle mode. `.manual` (default) keeps the legacy
    // behavior — Mani never touches `git worktree`. `.managed` opts
    // in to the new flow where every project's workspace is a Mani-
    // created worktree under `<repo>/<namespace>/<slug>/`.
    public var worktreeMode: WorktreeMode
    // Name of the namespace dir under the repo root that holds
    // managed worktrees. nil resolves to the default `"worktrees"`
    // (see `effectiveManagedWorktreesNamespace`). Users can override
    // for convention (e.g. "wt" or ".worktrees"); changes don't move
    // existing worktrees, they just affect new project creation and
    // boot-time discovery from that point forward.
    public var managedWorktreesNamespace: String?

    public init(
        id: UUID,
        name: String,
        color: String,
        enabled: Bool,
        rootDir: URL,
        projects: [Project],
        externalConvos: [ExternalConvo],
        availableWorktrees: [AvailableWorktree],
        createdAt: Date,
        claudeInvocation: String?,
        worktreeMode: WorktreeMode,
        managedWorktreesNamespace: String?
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.enabled = enabled
        self.rootDir = rootDir
        self.projects = projects
        self.externalConvos = externalConvos
        self.availableWorktrees = availableWorktrees
        self.createdAt = createdAt
        self.claudeInvocation = claudeInvocation
        self.worktreeMode = worktreeMode
        self.managedWorktreesNamespace = managedWorktreesNamespace
    }

    // Resolved namespace dir name for managed worktrees. Always
    // returns a value (default "worktrees" when the override is nil)
    // so callers don't have to re-check.
    public var effectiveManagedWorktreesNamespace: String {
        if let n = managedWorktreesNamespace,
           !n.trimmingCharacters(in: .whitespaces).isEmpty {
            return n
        }
        return "worktrees"
    }

    // Resolved on-disk dir where managed worktrees live.
    public var managedWorktreesDir: URL {
        rootDir.appendingPathComponent(effectiveManagedWorktreesNamespace)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, color, enabled, rootDir
        case projects, externalConvos, availableWorktrees
        case createdAt, claudeInvocation
        case worktreeMode, managedWorktreesNamespace
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

        self.availableWorktrees = (try? c.decodeIfPresent(
            [AvailableWorktree].self, forKey: .availableWorktrees
        )) ?? []
        // Default existing repos to .manual so legacy state.json
        // files keep the pre-change behavior. Namespace is left
        // nil (resolves to "worktrees" lazily) when unset.
        self.worktreeMode = (try? c.decodeIfPresent(
            WorktreeMode.self, forKey: .worktreeMode
        )) ?? .manual
        self.managedWorktreesNamespace = try? c.decodeIfPresent(
            String.self, forKey: .managedWorktreesNamespace
        )

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
                    // Legacy gitWorktree entries were always
                    // user-created (Mani never managed them), so
                    // migrate as `managed: false`.
                    kind = .gitWorktree(branch: branch, baseRef: baseRef, managed: false)
                }
                projects.append(Project(
                    id: wt.id,
                    // Default to "wip" so migrated entries get a
                    // placeholder name. The directory basename was a
                    // poor default — the new model treats a project
                    // as a unit of user intent, not a folder mirror,
                    // and the user should rename to reflect that.
                    name: "wip",
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
