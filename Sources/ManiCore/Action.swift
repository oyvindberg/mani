import Foundation

public enum Action {
    // MARK: Project
    case createProject(name: String, color: String, rootDir: URL)
    case renameProject(id: UUID, name: String)
    case setProjectEnabled(id: UUID, enabled: Bool)
    case setProjectColor(id: UUID, color: String)
    case setProjectClaudeInvocation(id: UUID, invocation: String?)
    // Promote the worktree at this path to be the project's rootDir.
    case setProjectRootDir(at: WorktreePath)
    case deleteProject(id: UUID)

    // MARK: Worktree
    case createWorktree(projectId: UUID, kind: WorktreeKind, path: URL)
    case setWorktreeEnabled(at: WorktreePath, enabled: Bool)
    case markWorktreeMissing(at: WorktreePath)
    case deleteWorktree(at: WorktreePath)

    // MARK: Task
    // `autoSelect: true` is the user-initiated path — the new task
    // becomes the focused selection. `false` keeps the current
    // selection (used by boot-time diff-task creators that mustn't
    // yank focus from whatever the user last had open).
    case createTask(at: WorktreePath, name: String, kind: TaskKind, spec: ProcessSpec, autoSelect: Bool)
    case setTaskEnabled(at: TaskPath, enabled: Bool)
    case renameTask(at: TaskPath, name: String)
    case deleteTask(at: TaskPath)
    case completeTask(at: TaskPath)
    case linkClaudeSession(at: TaskPath, sessionId: String)
    // Externally-running claude session discovered via the FSEvents watcher.
    // Creates a Task with runtime = .neverStarted (we don't own the process).
    case discoverClaudeSession(at: WorktreePath, sessionId: String, cwd: URL)
    case bumpUnread(at: TaskPath, by: Int)
    case markRead(at: TaskPath)
    // Re-spawn the agent for this Task with the current spec. Used by the
    // "Restart" button on a stopped task. New spec (for claude tasks that
    // need re-resolved --resume) flows via setTaskSpec first if needed.
    case restartTask(at: TaskPath)
    // Overwrite a Task's spec in place. Used by the Restart button on
    // claude tasks so we re-derive `claude --resume <sid>` against the
    // current project/settings invocation rather than reusing a stale
    // persisted spec.
    case setTaskSpec(at: TaskPath, spec: ProcessSpec)

    // MARK: Selection
    // Currently focused task in the UI. nil deselects. The reducer also
    // auto-emits selection changes when the selected task is created,
    // deleted, or its containing worktree/project is deleted.
    case selectTask(at: TaskPath?)

    // MARK: Runtime lifecycle (dispatched by EffectRunner / boot reconcile)
    // The agent for this Task has been spawned; reducer flips runtime
    // to .running.
    case taskSpawned(at: TaskPath, when: Date)
    // The agent for this Task has exited (or its socket has gone away).
    // Reducer flips runtime to .exited. May be dispatched by:
    //   - The AgentClient's onExit (identity-checked).
    //   - Any UI code that observes connect refused / EOF on first attach.
    //   - Boot reconciliation, for tasks in state with runtime = .running
    //     but no live agent on disk.
    case taskExited(at: TaskPath, when: Date, code: Int32)

    // MARK: Settings
    case updateSettings(Settings)
}
