import Foundation

// Decoded `SessionStart` hook payload from Claude Code. Claude fires
// SessionStart on every session entry — fresh startup, --resume,
// /clear, /compact, /fork. session_id is claude's authoritative id;
// `source` distinguishes the entry kind. The payload reconciles a
// Mani Task's `kind: .claude(sid)` with whatever claude actually
// ended up using.

public struct SessionStartPayload: Equatable {
    public enum Source: Equatable {
        case startup, resume, clear, compact, fork
        case other(String)

        public init(rawValue: String) {
            switch rawValue {
            case "startup": self = .startup
            case "resume":  self = .resume
            case "clear":   self = .clear
            case "compact": self = .compact
            case "fork":    self = .fork
            default:        self = .other(rawValue)
            }
        }
    }

    public let sessionId: String
    public let cwd: String?
    public let transcriptPath: String?
    public let source: Source

    public init(
        sessionId: String,
        cwd: String?,
        transcriptPath: String?,
        source: Source
    ) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.transcriptPath = transcriptPath
        self.source = source
    }
}

// Pure routing: given the current AppState and an incoming
// SessionStart payload, return the Action that should be dispatched
// (or nil to ignore).
//
// Match priority:
//   1. The hook's cwd is matched against project workspace paths
//      first (so an exact match to a Mani-managed project wins).
//   2. If no project workspace matches, fall back to matching the
//      hook's cwd against a repo's rootDir or any descendant — that
//      becomes an external convo under that repo.
//
// Rules per source after a project match:
//   - resume / clear / compact: retarget the most-recently-created
//     `.claude(*)` Task in the project whose sid differs.
//   - startup: link to the first `.claude(nil)` Task in the project.
//   - fork / other: discover as external (a fork creates a sibling
//     conversation, not a new managed task).
public func routeSessionStart(
    payload: SessionStartPayload,
    state: AppState,
    homePathToExclude: String
) -> Action? {
    guard let cwd = payload.cwd else { return nil }
    let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
    let tooBroad: Set<String> = [homePathToExclude, "/"]
    let cwdPath = cwdURL.path

    // Pass 1: exact / descendant match against any project's workspace.
    for repo in state.repos {
        for project in repo.projects {
            let wsPath = project.workspace.path.resolvingSymlinksInPath().path
            if tooBroad.contains(wsPath) { continue }
            guard cwdPath == wsPath || cwdPath.hasPrefix(wsPath + "/") else {
                continue
            }
            let projectPath = ProjectPath(repo: repo.id, project: project.id)

            let alreadyTracked = project.tasks.contains { task in
                if case let .claude(sid) = task.kind, sid == payload.sessionId {
                    return true
                }
                return false
            }
            if alreadyTracked { return nil }

            let claudeTasks = project.tasks.filter { task in
                if case .claude = task.kind { return true }
                return false
            }

            switch payload.source {
            case .resume, .clear, .compact:
                if let target = mostRecentMismatch(
                    in: claudeTasks, sessionId: payload.sessionId
                ) {
                    let taskPath = TaskPath(
                        repo: repo.id, project: project.id, task: target.id
                    )
                    return .linkClaudeSession(at: taskPath, sessionId: payload.sessionId)
                }

            case .startup:
                if let unlinked = claudeTasks.first(where: { task in
                    if case let .claude(sid) = task.kind, sid == nil { return true }
                    return false
                }) {
                    let taskPath = TaskPath(
                        repo: repo.id, project: project.id, task: unlinked.id
                    )
                    return .linkClaudeSession(at: taskPath, sessionId: payload.sessionId)
                }

            case .fork, .other:
                break
            }

            // No project-level Task to link/retarget — fall through to
            // discovery as an external convo under this repo.
            _ = projectPath
            return .discoverExternalConvo(
                repoId: repo.id,
                sessionId: payload.sessionId,
                cwd: URL(fileURLWithPath: cwd)
            )
        }
    }

    // Pass 2: the cwd falls under a repo's rootDir but didn't match
    // any project. Discover as a repo-level external convo.
    for repo in state.repos {
        let rootPath = repo.rootDir.resolvingSymlinksInPath().path
        if tooBroad.contains(rootPath) { continue }
        guard cwdPath == rootPath || cwdPath.hasPrefix(rootPath + "/") else {
            continue
        }
        return .discoverExternalConvo(
            repoId: repo.id,
            sessionId: payload.sessionId,
            cwd: URL(fileURLWithPath: cwd)
        )
    }
    return nil
}

private func mostRecentMismatch(in tasks: [Task], sessionId: String) -> Task? {
    tasks
        .filter { task in
            if case let .claude(sid) = task.kind, sid != sessionId { return true }
            return false
        }
        .max(by: { $0.createdAt < $1.createdAt })
}
