import Foundation

// Decoded `SessionStart` hook payload from Claude Code. Claude fires
// SessionStart on every session entry — fresh startup, --resume, /clear,
// /compact, /fork. session_id is claude's authoritative id; `source`
// distinguishes the entry kind. The payload reconciles a Mani Task's
// `kind: .claude(sid)` with whatever claude actually ended up using.

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

// Pure routing: given the current AppState and an incoming SessionStart
// payload, return the Action that should be dispatched (or nil to ignore).
//
// Rules:
//   - Ignore payloads whose cwd is missing OR is too broad ($HOME or "/").
//   - Ignore if the matching worktree already tracks this sid.
//   - source = resume / clear / compact: retarget the most-recently-created
//     `.claude(*)` Task in the worktree whose sid differs from the payload.
//   - source = startup: link to the first `.claude(nil)` Task in the
//     worktree if any; else fall through to discover.
//   - source = fork / other: discover (creates a sibling Task).
//   - Fallback: discover.
public func routeSessionStart(
    payload: SessionStartPayload,
    state: AppState,
    homePathToExclude: String
) -> Action? {
    guard let cwd = payload.cwd else { return nil }
    let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
    let tooBroad: Set<String> = [homePathToExclude, "/"]

    for repo in state.repos {
        for worktree in repo.worktrees {
            let wtPath = worktree.path.resolvingSymlinksInPath().path
            if tooBroad.contains(wtPath) { continue }
            guard cwdURL.path == wtPath || cwdURL.path.hasPrefix(wtPath + "/") else {
                continue
            }
            let wtPathStruct = WorktreePath(repo: repo.id, worktree: worktree.id)

            let alreadyTracked = worktree.tasks.contains { task in
                if case let .claude(sid) = task.kind, sid == payload.sessionId {
                    return true
                }
                return false
            }
            if alreadyTracked { return nil }

            let claudeTasks = worktree.tasks.filter { task in
                if case .claude = task.kind { return true }
                return false
            }

            switch payload.source {
            case .resume, .clear, .compact:
                if let target = mostRecentMismatch(
                    in: claudeTasks, sessionId: payload.sessionId
                ) {
                    let taskPath = TaskPath(
                        repo: repo.id, worktree: worktree.id, task: target.id
                    )
                    return .linkClaudeSession(at: taskPath, sessionId: payload.sessionId)
                }

            case .startup:
                if let unlinked = claudeTasks.first(where: { task in
                    if case let .claude(sid) = task.kind, sid == nil { return true }
                    return false
                }) {
                    let taskPath = TaskPath(
                        repo: repo.id, worktree: worktree.id, task: unlinked.id
                    )
                    return .linkClaudeSession(at: taskPath, sessionId: payload.sessionId)
                }

            case .fork, .other:
                break // discover below
            }

            return .discoverClaudeSession(
                at: wtPathStruct,
                sessionId: payload.sessionId,
                cwd: URL(fileURLWithPath: cwd)
            )
        }
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
