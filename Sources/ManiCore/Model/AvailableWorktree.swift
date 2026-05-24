import Foundation

// A directory on disk under a Repo that's available for use as a
// new Project's workspace, but isn't currently bound 1:1 to an
// active project.
//
// Created when:
//   - A user archives a project whose workspace is a manual
//     `.folder` — the directory stays on disk, the project's
//     active row disappears, and the workspace surfaces here so
//     it's still discoverable from the sidebar.
//   - (future) A user manually adds a workspace path to the repo
//     without spawning a project right away.
//
// The id is independent of any project that may have lived in
// (or comes to live in) the path — multiple projects can share a
// workspace path, but only one AvailableWorktree per id exists.
public struct AvailableWorktree: Codable, Equatable, Identifiable {
    public let id: UUID
    public var path: URL
    public var kind: WorkspaceKind
    public var addedAt: Date

    public init(
        id: UUID,
        path: URL,
        kind: WorkspaceKind,
        addedAt: Date
    ) {
        self.id = id
        self.path = path
        self.kind = kind
        self.addedAt = addedAt
    }

    public var displayName: String {
        URL(fileURLWithPath: path.path).lastPathComponent
    }
}
