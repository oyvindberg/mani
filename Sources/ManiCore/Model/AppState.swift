import Foundation

public struct AppState: Codable, Equatable {
    public var schemaVersion: Int
    public var projects: [Project]
    public var settings: Settings

    public init(schemaVersion: Int, projects: [Project], settings: Settings) {
        self.schemaVersion = schemaVersion
        self.projects = projects
        self.settings = settings
    }

    public static let empty = AppState(
        schemaVersion: 1,
        projects: [],
        settings: Settings(
            scrollbackCapBytes: 32 * 1024 * 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13
        )
    )

    // Returns a copy with every `.claude` job removed across all projects
    // and worktrees. Project, worktree, and non-claude job state is
    // preserved. Used by Store.resetForNewClaudeTask before snapshotting
    // and truncating events.jsonl. See ADR-015 for why we need this.
    public func withoutClaudeJobs() -> AppState {
        var copy = self
        for projIdx in copy.projects.indices {
            for wtIdx in copy.projects[projIdx].worktrees.indices {
                copy.projects[projIdx].worktrees[wtIdx].jobs.removeAll { job in
                    if case .claude = job.kind { return true }
                    return false
                }
            }
        }
        return copy
    }

    // All `.claude` jobs across the state, paired with the (project,
    // worktree) UUIDs that own them. The Store uses this to terminate
    // their PTYs before invoking `withoutClaudeJobs()`.
    public func claudeJobs() -> [(JobPath, Job)] {
        var out: [(JobPath, Job)] = []
        for project in projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    guard case .claude = job.kind else { continue }
                    let path = JobPath(
                        project: project.id, worktree: worktree.id, job: job.id
                    )
                    out.append((path, job))
                }
            }
        }
        return out
    }
}

public struct Settings: Codable, Equatable {
    public var scrollbackCapBytes: Int
    public var snapshotIntervalSeconds: Int
    // Name of a Ghostty theme from the GhosttyTheme catalog, e.g. "Dracula",
    // "Tokyo Night Storm", "GitHub Light". Looked up at terminal-pane mount
    // time; changing requires re-mounting the affected pane.
    public var terminalTheme: String
    // Monospace font family name (PostScript or display name resolvable by
    // libghostty's font loader). Empty means "use libghostty default".
    public var terminalFontFamily: String
    // Point size for the terminal font.
    public var terminalFontSize: Int

    public init(
        scrollbackCapBytes: Int,
        snapshotIntervalSeconds: Int,
        terminalTheme: String,
        terminalFontFamily: String,
        terminalFontSize: Int
    ) {
        self.scrollbackCapBytes = scrollbackCapBytes
        self.snapshotIntervalSeconds = snapshotIntervalSeconds
        self.terminalTheme = terminalTheme
        self.terminalFontFamily = terminalFontFamily
        self.terminalFontSize = terminalFontSize
    }

    // Backward-compat decode: state.json files written before later fields
    // were added supply the defaults via decodeIfPresent.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.scrollbackCapBytes = try c.decode(Int.self, forKey: .scrollbackCapBytes)
        self.snapshotIntervalSeconds = try c.decode(Int.self, forKey: .snapshotIntervalSeconds)
        self.terminalTheme = (try? c.decodeIfPresent(String.self, forKey: .terminalTheme)) ?? "Dracula"
        self.terminalFontFamily = (try? c.decodeIfPresent(String.self, forKey: .terminalFontFamily)) ?? ""
        self.terminalFontSize = (try? c.decodeIfPresent(Int.self, forKey: .terminalFontSize)) ?? 13
    }
}
