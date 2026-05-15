import Foundation

public enum Event: Codable, Equatable {
    // MARK: Project
    case projectCreated(Project)
    case projectRenamed(id: UUID, name: String)
    case projectEnabledChanged(id: UUID, enabled: Bool)
    case projectColorChanged(id: UUID, color: String)
    case projectClaudeInvocationChanged(id: UUID, invocation: String?)
    case projectRootDirChanged(id: UUID, rootDir: URL)
    case projectDeleted(id: UUID)

    // MARK: Worktree
    case worktreeCreated(projectId: UUID, Worktree)
    case worktreeEnabledChanged(at: WorktreePath, enabled: Bool)
    case worktreeMarkedMissing(at: WorktreePath)
    case worktreeDeleted(at: WorktreePath)

    // MARK: Task
    case taskCreated(at: WorktreePath, Task)
    case taskEnabledChanged(at: TaskPath, enabled: Bool)
    case taskCompleted(at: TaskPath, completedAt: Date)
    case taskUnreadBumped(at: TaskPath, by: Int)
    case taskRead(at: TaskPath)
    case taskRenamed(at: TaskPath, name: String)
    case taskDeleted(at: TaskPath)
    case taskSpecChanged(at: TaskPath, spec: ProcessSpec)
    case claudeSessionLinked(at: TaskPath, sessionId: String)

    // MARK: Selection
    case taskSelectionChanged(TaskPath?)

    // MARK: Runtime lifecycle
    case taskSpawned(at: TaskPath, when: Date)
    case taskExited(at: TaskPath, when: Date, code: Int32)

    // MARK: Settings
    case settingsUpdated(Settings)
}
