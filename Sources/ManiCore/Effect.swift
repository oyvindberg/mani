import Foundation

public enum Effect {
    case persistEvents([Event])
    case writeSnapshot
    // Tell the host to start an agent for this Task. The agent's identity
    // on disk is the task UUID, so the host has everything it needs from
    // the path alone — the spec is included for the spawn args.
    case spawn(at: TaskPath, spec: ProcessSpec)
    // Tell the host to kill the agent for this Task. Resolution is by
    // task UUID; no pid required because Mani doesn't store kernel pids.
    case terminate(at: TaskPath)
    case createGitWorktree(projectId: UUID, repoRoot: URL, branch: String, path: URL, baseRef: String?)
    case archive(at: TaskPath)
    case watchClaudeProjects(URL)
    case userNotification(title: String, body: String)
}
