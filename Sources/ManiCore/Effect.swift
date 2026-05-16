import Foundation

public enum Effect {
    case persistEvents([Event])
    case writeSnapshot
    // Tell the host to start an agent for this Task. The agent's
    // identity on disk is the task UUID, so the host has everything
    // it needs from the path alone — the spec is included for the
    // spawn args.
    case spawn(at: TaskPath, spec: ProcessSpec)
    // Tell the host to kill the agent for this Task.
    case terminate(at: TaskPath)
    // Invoke `git worktree add` for a newly-created project whose
    // workspace.kind == .gitWorktree. projectPath identifies the
    // project the worktree belongs to so the runner can mark it
    // missing if the git invocation fails.
    case createGitWorktree(
        projectPath: ProjectPath,
        repoRoot: URL,
        branch: String,
        path: URL,
        baseRef: String?
    )
    case watchClaudeProjects(URL)
    case userNotification(title: String, body: String)
}
