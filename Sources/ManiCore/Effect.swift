import Foundation

public enum Effect {
    case persistEvents([Event])
    case writeSnapshot
    case spawn(at: JobPath, index: Int, ProcessSpec)
    case terminate(pid: Int32, escalateAfter: TimeInterval)
    case createGitWorktree(projectId: UUID, repoRoot: URL, branch: String, path: URL, baseRef: String?)
    case archive(at: JobPath)
    case watchClaudeProjects(URL)
    case userNotification(title: String, body: String)
}
