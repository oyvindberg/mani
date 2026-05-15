import Foundation

public struct AppState: Codable, Equatable {
    public var schemaVersion: Int
    public var repos: [Repo]
    public var settings: Settings
    // Currently selected task in the UI. Reducer-owned so creating
    // a new task can auto-focus it, deleting the selected task can
    // auto-deselect, and the choice survives Mani restarts.
    public var selectedTaskPath: TaskPath?

    public init(
        schemaVersion: Int,
        repos: [Repo],
        settings: Settings,
        selectedTaskPath: TaskPath?
    ) {
        self.schemaVersion = schemaVersion
        self.repos = repos
        self.settings = settings
        self.selectedTaskPath = selectedTaskPath
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, repos, settings, selectedTaskPath
    }

    // Legacy key from before the Project → Repo rename.
    private enum LegacyKeys: String, CodingKey {
        case projects
    }

    // Decoder accepts both the new `repos` key and the legacy
    // `projects` key so snapshots written by older Mani builds load
    // cleanly. selectedTaskPath also tolerates absent (defaults nil).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        if let repos = try c.decodeIfPresent([Repo].self, forKey: .repos) {
            self.repos = repos
        } else {
            let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            self.repos = try legacy.decode([Repo].self, forKey: .projects)
        }
        self.settings = try c.decode(Settings.self, forKey: .settings)
        self.selectedTaskPath = try c.decodeIfPresent(
            TaskPath.self, forKey: .selectedTaskPath
        )
    }

    public static let empty = AppState(
        schemaVersion: 2,
        repos: [],
        settings: Settings(
            scrollbackCapBytes: 32 * 1024 * 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13,
            claudeInvocation: "claude"
        ),
        selectedTaskPath: nil
    )

    // The TaskPath of the (single) Task that already tracks this claude
    // session id, or nil if no task does. Invariant: at most one task
    // per sid across the whole state — the reducer's linkClaudeSession
    // and discoverClaudeSession both enforce this.
    public func taskOwningClaudeSession(_ sessionId: String) -> TaskPath? {
        for repo in repos {
            for worktree in repo.worktrees {
                for task in worktree.tasks {
                    if case let .claude(sid) = task.kind, sid == sessionId {
                        return TaskPath(
                            repo: repo.id,
                            worktree: worktree.id,
                            task: task.id
                        )
                    }
                }
            }
        }
        return nil
    }

    // For each non-nil claude session id appearing on multiple Tasks,
    // returns the TaskPaths of the duplicates that should be deleted —
    // the group minus the "best" surviving Task. Selection rule per
    // group: a user-renamed Task ALWAYS wins (losing a rename to a
    // dedupe sweep happened once and the fix was permanent). Within
    // renamed-vs-renamed, fall back to "live runtime" (currently
    // believed running) → unread → createdAt.
    public func duplicateClaudeTasksToRemove() -> [TaskPath] {
        struct Entry {
            let path: TaskPath
            let task: Task
        }
        var bySid: [String: [Entry]] = [:]
        for repo in repos {
            for worktree in repo.worktrees {
                for task in worktree.tasks {
                    if case let .claude(sid?) = task.kind {
                        let path = TaskPath(
                            repo: repo.id,
                            worktree: worktree.id,
                            task: task.id
                        )
                        bySid[sid, default: []].append(Entry(path: path, task: task))
                    }
                }
            }
        }
        var result: [TaskPath] = []
        for (_, group) in bySid where group.count > 1 {
            let sorted = group.sorted { a, b in
                if a.task.renamed != b.task.renamed { return a.task.renamed && !b.task.renamed }
                let liveA = isRunning(a.task.runtime)
                let liveB = isRunning(b.task.runtime)
                if liveA != liveB { return liveA && !liveB }
                if a.task.unread != b.task.unread { return a.task.unread > b.task.unread }
                return a.task.createdAt > b.task.createdAt
            }
            for entry in sorted.dropFirst() {
                result.append(entry.path)
            }
        }
        return result
    }

    // All `.claude` Tasks across the state, paired with their TaskPath.
    public func claudeTasks() -> [(TaskPath, Task)] {
        var out: [(TaskPath, Task)] = []
        for repo in repos {
            for worktree in repo.worktrees {
                for task in worktree.tasks {
                    guard case .claude = task.kind else { continue }
                    let path = TaskPath(
                        repo: repo.id, worktree: worktree.id, task: task.id
                    )
                    out.append((path, task))
                }
            }
        }
        return out
    }
}

// True iff runtime represents "we believe an agent is currently alive"
// — only `.running` qualifies. Boot reconciliation flips stale .running
// entries to .exited if the agent's socket is no longer connectable.
private func isRunning(_ runtime: TaskRuntime) -> Bool {
    switch runtime {
    case .running:                 return true
    case .neverStarted,
         .exited,
         .completed:               return false
    }
}

public struct Settings: Codable, Equatable {
    public var scrollbackCapBytes: Int
    public var snapshotIntervalSeconds: Int
    // Name of a Ghostty theme from the GhosttyTheme catalog. Looked up at
    // terminal-pane mount time; changing requires re-mounting the pane.
    public var terminalTheme: String
    // Monospace font family. Empty means "use libghostty default".
    public var terminalFontFamily: String
    public var terminalFontSize: Int
    // Default invocation of the claude binary; Repo.claudeInvocation
    // overrides per-repo. `--resume <sid>` is appended at spawn time
    // by ClaudeTaskSpec.make.
    public var claudeInvocation: String

    public init(
        scrollbackCapBytes: Int,
        snapshotIntervalSeconds: Int,
        terminalTheme: String,
        terminalFontFamily: String,
        terminalFontSize: Int,
        claudeInvocation: String
    ) {
        self.scrollbackCapBytes = scrollbackCapBytes
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
        self.terminalTheme = terminalTheme
        self.terminalFontFamily = terminalFontFamily
        self.terminalFontSize = terminalFontSize
        self.claudeInvocation = claudeInvocation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scrollbackCapBytes = try c.decode(Int.self, forKey: .scrollbackCapBytes)
        self.snapshotIntervalSeconds = try c.decode(Int.self, forKey: .snapshotIntervalSeconds)
        self.terminalTheme = (try? c.decodeIfPresent(String.self, forKey: .terminalTheme)) ?? "Dracula"
        self.terminalFontFamily = (try? c.decodeIfPresent(String.self, forKey: .terminalFontFamily)) ?? ""
        self.terminalFontSize = (try? c.decodeIfPresent(Int.self, forKey: .terminalFontSize)) ?? 13
        self.claudeInvocation = (try? c.decodeIfPresent(String.self, forKey: .claudeInvocation)) ?? "claude"
    }
}
