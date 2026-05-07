import Foundation

public enum Action {
    case createProject(name: String, color: String, rootDir: URL)
    case renameProject(id: UUID, name: String)
    case setProjectEnabled(id: UUID, enabled: Bool)
    case deleteProject(id: UUID)

    case createWorktree(projectId: UUID, name: String, kind: WorktreeKind, path: URL)
    case setWorktreeEnabled(at: WorktreePath, enabled: Bool)
    case markWorktreeMissing(at: WorktreePath)
    case deleteWorktree(at: WorktreePath)

    case createJob(at: WorktreePath, name: String, kind: JobKind, primary: ProcessSpec, auxiliary: [ProcessSpec])
    case setJobEnabled(at: JobPath, enabled: Bool)
    case linkClaudeSession(at: JobPath, sessionId: String)
    case completeJob(at: JobPath)

    case processStarted(at: JobPath, index: Int, pid: Int32)
    case processExited(at: JobPath, index: Int, code: Int32)
}
