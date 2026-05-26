import Foundation

// How a Repo treats worktrees.
//
// - `.manual`  — the user creates workspace directories outside Mani
//                (any folder or pre-existing git worktree). Mani never
//                runs `git worktree add` or `remove` on its own. This
//                is the default for existing repos and the legacy
//                behavior up through this commit.
//
// - `.managed` — Mani owns the lifecycle. Every project's workspace is
//                a git worktree under `<repo>/<namespace>/<slug>/`
//                (namespace defaults to `worktrees`). New projects
//                create the worktree; finishing a project can remove
//                it. The repo's main checkout is never used as a
//                project workspace.
public enum WorktreeMode: String, Codable, Equatable, CaseIterable {
    case manual
    case managed
}
