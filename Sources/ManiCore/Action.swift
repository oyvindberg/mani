import Foundation

public enum Action {
    // MARK: Repo
    case createRepo(name: String, color: String, rootDir: URL)
    case renameRepo(id: UUID, name: String)
    case setRepoEnabled(id: UUID, enabled: Bool)
    case setRepoColor(id: UUID, color: String)
    case setRepoClaudeInvocation(id: UUID, invocation: String?)
    case setRepoRootDir(at: ProjectPath)
    case deleteRepo(id: UUID)

    // MARK: Project
    // `workspace` may point at an existing user-chosen folder or at a
    // path Mani is about to create via `git worktree add`. The reducer
    // emits a createGitWorktree effect when workspace.kind is
    // .gitWorktree, otherwise it trusts the caller to have already
    // verified the directory exists.
    case createProject(repoId: UUID, name: String, workspace: Workspace)
    case renameProject(at: ProjectPath, name: String)
    case archiveProject(at: ProjectPath)
    case unarchiveProject(at: ProjectPath)
    case markProjectWorkspaceMissing(at: ProjectPath)
    case deleteProject(at: ProjectPath)

    // MARK: Task
    // `autoSelect: true` is the user-initiated path — the new task
    // becomes the focused selection. `false` keeps the current
    // selection (used by background creators that mustn't yank focus
    // from whatever the user last had open).
    case createTask(at: ProjectPath, name: String, kind: TaskKind, spec: ProcessSpec, autoSelect: Bool)
    case setTaskEnabled(at: TaskPath, enabled: Bool)
    case renameTask(at: TaskPath, name: String)
    case deleteTask(at: TaskPath)
    case completeTask(at: TaskPath)
    case linkClaudeSession(at: TaskPath, sessionId: String)
    case bumpUnread(at: TaskPath, by: Int)
    case markRead(at: TaskPath)
    case restartTask(at: TaskPath)
    case setTaskSpec(at: TaskPath, spec: ProcessSpec)
    // Move a task from its current project to another. The target
    // project must live in the same repo, and the workspace.path
    // of source and target must match — the running process's cwd
    // is the source workspace, and the task keeps running there.
    // No process restart is needed; only the parent in the
    // hierarchy changes.
    case moveTask(from: TaskPath, to: ProjectPath)

    // MARK: Available worktrees
    // Workspace dirs left over from archived manual-worktree
    // projects. The archive reducer auto-adds them; the user can
    // remove from the sidebar list once they're truly done with
    // the directory.
    case removeAvailableWorktree(repoId: UUID, id: UUID)

    // MARK: External convos
    // Discovered via the FSEvents watcher on ~/.claude/projects. The
    // matched repo is identified by cwd ⊆ repo.rootDir.
    case discoverExternalConvo(repoId: UUID, sessionId: String, cwd: URL)
    case dismissExternalConvo(at: ExternalConvoPath)
    // Adopt an external convo into a project: spawn a Mani-managed
    // claude agent that --resumes the sid, and remove the convo
    // from the external list.
    case adoptExternalConvo(at: ExternalConvoPath, into: ProjectPath, name: String)

    // MARK: Selection
    // Currently focused task in the UI. nil deselects. The reducer
    // also auto-emits selection changes when the selected task,
    // its project, or its repo is deleted.
    case selectTask(at: TaskPath?)

    // MARK: Runtime lifecycle (dispatched by EffectRunner / boot reconcile)
    case taskSpawned(at: TaskPath, when: Date)
    case taskExited(at: TaskPath, when: Date, code: Int32)

    // MARK: Settings
    case updateSettings(Settings)
}
