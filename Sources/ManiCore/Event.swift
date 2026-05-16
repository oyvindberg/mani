import Foundation

public enum Event: Codable, Equatable {
    // MARK: Repo
    case repoCreated(Repo)
    case repoRenamed(id: UUID, name: String)
    case repoEnabledChanged(id: UUID, enabled: Bool)
    case repoColorChanged(id: UUID, color: String)
    case repoClaudeInvocationChanged(id: UUID, invocation: String?)
    case repoRootDirChanged(id: UUID, rootDir: URL)
    case repoDeleted(id: UUID)

    // MARK: Project
    case projectCreated(repoId: UUID, Project)
    case projectRenamed(at: ProjectPath, name: String)
    case projectArchived(at: ProjectPath, when: Date)
    case projectUnarchived(at: ProjectPath)
    case projectWorkspaceMarkedMissing(at: ProjectPath)
    case projectDeleted(at: ProjectPath)

    // MARK: Task
    case taskCreated(at: ProjectPath, Task)
    case taskEnabledChanged(at: TaskPath, enabled: Bool)
    case taskCompleted(at: TaskPath, completedAt: Date)
    case taskUnreadBumped(at: TaskPath, by: Int)
    case taskRead(at: TaskPath)
    case taskRenamed(at: TaskPath, name: String)
    case taskDeleted(at: TaskPath)
    case taskSpecChanged(at: TaskPath, spec: ProcessSpec)
    case claudeSessionLinked(at: TaskPath, sessionId: String)

    // MARK: External convos
    case externalConvoDiscovered(repoId: UUID, ExternalConvo)
    case externalConvoDismissed(at: ExternalConvoPath)
    // Adoption is reified as taskCreated + externalConvoDismissed
    // pair from the reducer — no dedicated event is needed.

    // MARK: Selection
    case taskSelectionChanged(TaskPath?)

    // MARK: Runtime lifecycle
    case taskSpawned(at: TaskPath, when: Date)
    case taskExited(at: TaskPath, when: Date, code: Int32)

    // MARK: Settings
    case settingsUpdated(Settings)
}
