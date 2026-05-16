import Foundation

// A unit of intent: "what the user wants to do to a repo." Has a
// name, an embedded Workspace (the directory on disk it operates in),
// and a list of Tasks that run within that workspace. A project can
// span multiple agents, shells, branches, and PRs over time — they
// all live as Tasks here.
//
// Replaces the old Worktree as the entity nested under a Repo. The
// underlying git worktree directory is now an implementation detail
// of Workspace, not a top-level concept.
public struct Project: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var workspace: Workspace
    public var tasks: [Task]
    // nil = active. Non-nil = archived at that timestamp; running
    // agents are terminated on archive but tasks stay listed so the
    // user can read scrollback / unarchive later.
    public var archivedAt: Date?
    public var createdAt: Date

    public init(
        id: UUID,
        name: String,
        workspace: Workspace,
        tasks: [Task],
        archivedAt: Date?,
        createdAt: Date
    ) {
        self.id = id
        self.name = name
        self.workspace = workspace
        self.tasks = tasks
        self.archivedAt = archivedAt
        self.createdAt = createdAt
    }

    public var isArchived: Bool { archivedAt != nil }
}
