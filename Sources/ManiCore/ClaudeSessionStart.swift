import Foundation

// Decoded `SessionStart` hook payload. Claude Code fires SessionStart on
// every session entry — fresh startup, --resume, /clear, /compact, /fork.
// The session_id field is claude's authoritative truth (whatever id it is
// now writing under), and `source` distinguishes the entry kind. We use
// the payload to reconcile a Mani Job's `kind: .claude(sid)` with whatever
// claude actually ended up using. See ADR-016.

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
// payload, return the Action that should be dispatched (or nil if the
// payload should be ignored).
//
// Rules:
//   - Ignore payloads whose cwd is missing OR is a top-broad path (the
//     user's $HOME or "/") — those would link claude sessions run anywhere
//     on the machine to the matching worktree, which has caused phantom
//     job spam in the past.
//   - Ignore if any Job in the matching worktree already tracks this sid
//     (the redundant work of re-linking the same sid is harmless but noisy).
//   - source = resume / clear / compact: retarget the most-recently-created
//     `.claude(*)` Job in the worktree whose sid differs from the payload.
//     This is the "claude allocated a new session id under the hood"
//     reconciliation path.
//   - source = startup: link to the first `.claude(nil)` Job in the
//     worktree if one exists (the slot Mani created for a freshly-spawned
//     claude task). Otherwise fall through to discover.
//   - source = fork / other: discover (creates a sibling Job for the new sid,
//     leaving the original alone — that's the natural "fork" UX).
//   - Fallback when no source-specific rule matched: discover.
//
// The `homePathToExclude` argument is passed in (rather than read here) so
// the function stays pure — tests construct it explicitly.
public func routeSessionStart(
    payload: SessionStartPayload,
    state: AppState,
    homePathToExclude: String
) -> Action? {
    guard let cwd = payload.cwd else { return nil }
    let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
    let tooBroad: Set<String> = [homePathToExclude, "/"]

    for project in state.projects {
        for worktree in project.worktrees {
            let wtPath = worktree.path.resolvingSymlinksInPath().path
            if tooBroad.contains(wtPath) { continue }
            guard cwdURL.path == wtPath || cwdURL.path.hasPrefix(wtPath + "/") else {
                continue
            }
            let wtPathStruct = WorktreePath(project: project.id, worktree: worktree.id)

            let alreadyTracked = worktree.jobs.contains { job in
                if case let .claude(sid) = job.kind, sid == payload.sessionId {
                    return true
                }
                return false
            }
            if alreadyTracked { return nil }

            let claudeJobs = worktree.jobs.filter { job in
                if case .claude = job.kind { return true }
                return false
            }

            switch payload.source {
            case .resume, .clear, .compact:
                if let target = mostRecentMismatch(
                    in: claudeJobs, sessionId: payload.sessionId
                ) {
                    let jobPath = JobPath(
                        project: project.id, worktree: worktree.id, job: target.id
                    )
                    return .linkClaudeSession(at: jobPath, sessionId: payload.sessionId)
                }

            case .startup:
                if let unlinked = claudeJobs.first(where: { job in
                    if case let .claude(sid) = job.kind, sid == nil { return true }
                    return false
                }) {
                    let jobPath = JobPath(
                        project: project.id, worktree: worktree.id, job: unlinked.id
                    )
                    return .linkClaudeSession(at: jobPath, sessionId: payload.sessionId)
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

// Pick the claude job in `jobs` whose sid differs from sessionId and which
// was created most recently. Returns nil if no claude job has a non-matching
// sid (e.g. the worktree only has a `.claude(nil)` slot).
private func mostRecentMismatch(in jobs: [Job], sessionId: String) -> Job? {
    jobs
        .filter { job in
            if case let .claude(sid) = job.kind, sid != sessionId { return true }
            return false
        }
        .max(by: { $0.createdAt < $1.createdAt })
}
