import Foundation

// A claude session running outside Mani that we discovered via the
// FSEvents watcher on ~/.claude/projects/<slug>/*.jsonl. We don't
// own the process — only observe its transcript — so this is a
// lighter shape than a Task: no spec, no runtime. The user can
// "adopt" it into one of the repo's projects, which spawns a managed
// agent that --resumes the session and moves the convo into that
// project's tasks list.
//
// Lives at the same level as Project under a Repo (Repo.externalConvos
// alongside Repo.projects).
public struct ExternalConvo: Codable, Equatable, Identifiable {
    public let id: UUID
    public var sessionId: String
    public var cwd: URL
    public var firstSeenAt: Date

    public init(id: UUID, sessionId: String, cwd: URL, firstSeenAt: Date) {
        self.id = id
        self.sessionId = sessionId
        self.cwd = cwd
        self.firstSeenAt = firstSeenAt
    }
}
