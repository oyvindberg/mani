import Foundation

// The physical backing directory of a Project. Embedded value type
// (no UUID of its own) — the Project owns its workspace 1:1.
// kind distinguishes a user-pointed folder from one Mani created via
// `git worktree add`; the sidebar uses that for the git badge, and
// archive/delete can offer `git worktree remove` for managed ones.
public struct Workspace: Codable, Equatable {
    public var path: URL
    public var kind: WorkspaceKind
    public var missing: Bool

    public init(path: URL, kind: WorkspaceKind, missing: Bool) {
        self.path = path
        self.kind = kind
        self.missing = missing
    }

    // Display label — matches what the sidebar shows when a project
    // has no user-given name (which shouldn't happen in the new model,
    // but the helper is useful as a default-name source on create).
    public var displayName: String {
        URL(fileURLWithPath: path.path).lastPathComponent
    }
}

public enum WorkspaceKind: Codable, Equatable {
    case folder
    // baseRef is the branch the worktree was created off (e.g. "main");
    // kept for diagnostics only — the live branch comes from git.
    case gitWorktree(branch: String, baseRef: String?)
}
