import Foundation

public enum Event: Codable, Equatable {
    case projectCreated(Project)
    case projectRenamed(id: UUID, name: String)
    case projectEnabledChanged(id: UUID, enabled: Bool)
    case projectDeleted(id: UUID)

    case worktreeCreated(projectId: UUID, Worktree)
    case worktreeEnabledChanged(at: WorktreePath, enabled: Bool)
    case worktreeMarkedMissing(at: WorktreePath)
    case worktreeDeleted(at: WorktreePath)

    case jobCreated(at: WorktreePath, Job)
    case jobEnabledChanged(at: JobPath, enabled: Bool)
    case jobStatusChanged(at: JobPath, status: JobStatus)
    case jobCompleted(at: JobPath, completedAt: Date)
    case jobUnreadBumped(at: JobPath, by: Int)
    case jobRead(at: JobPath)
    case claudeSessionLinked(at: JobPath, sessionId: String)

    case processStarted(at: JobPath, index: Int, pid: Int32)
    case processExited(at: JobPath, index: Int, code: Int32)

    case settingsUpdated(Settings)
}
