import Foundation

// Cleanup intensity when finishing a project. Selected by the user
// in the Finish modal; consumed by the reducer's `finishProject`
// arm to decide which effects to emit alongside the archive.
//
// - `.archiveOnly` matches the existing `archiveProject` action:
//   terminate tasks, mark archived, fetch + reset workspace to the
//   remote's default branch, leave everything else on disk.
// - `.removeWorktree` is the recommended path for managed
//   worktrees: terminate tasks, archive, run `git worktree remove`.
//   The work survives as a branch in the main repo; the worktree
//   directory is gone.
// - `.removeWorktreeAndBranch` is destructive: same as
//   `.removeWorktree` plus `git branch -D <branch>` afterwards.
//   Only meaningful for `.gitWorktree` workspaces.
//
// `.removeWorktree` and `.removeWorktreeAndBranch` carry a `force`
// flag for use when the user has acknowledged a dirty workspace.
// `.archiveOnly` doesn't need it — fetch+reset doesn't touch worktrees.
public enum FinishCleanup: Codable, Equatable {
    case archiveOnly
    case removeWorktree(force: Bool)
    case removeWorktreeAndBranch(force: Bool)
}
