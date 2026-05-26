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

// The `managed` flag on `.gitWorktree` records whether Mani owns the
// worktree's lifecycle. Managed worktrees can be cleaned up by
// `finishProject` (running `git worktree remove`); unmanaged ones
// (created outside Mani and registered as-is) stay on disk on archive.
public enum WorkspaceKind: Equatable {
    case folder
    case gitWorktree(branch: String, baseRef: String?, managed: Bool)
}

// Custom Codable for backwards compatibility with state.json files
// written before the `managed` payload existed. The legacy shape was
//   { "gitWorktree": { "branch": "x", "baseRef": "y" } }
// and decodes here as managed: false (i.e. pre-existing worktrees are
// assumed manual).
extension WorkspaceKind: Codable {
    private enum CodingKeys: String, CodingKey {
        case folder
        case gitWorktree
    }

    private struct GitWorktreePayload: Codable {
        var branch: String
        var baseRef: String?
        var managed: Bool?  // optional for legacy decode
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.folder) {
            self = .folder
            return
        }
        if let payload = try? c.decode(GitWorktreePayload.self, forKey: .gitWorktree) {
            self = .gitWorktree(
                branch: payload.branch,
                baseRef: payload.baseRef,
                managed: payload.managed ?? false
            )
            return
        }
        throw DecodingError.dataCorruptedError(
            forKey: .folder,
            in: c,
            debugDescription: "WorkspaceKind: unrecognised shape"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .folder:
            try c.encode([String: String](), forKey: .folder)
        case let .gitWorktree(branch, baseRef, managed):
            try c.encode(
                GitWorktreePayload(branch: branch, baseRef: baseRef, managed: managed),
                forKey: .gitWorktree
            )
        }
    }
}
