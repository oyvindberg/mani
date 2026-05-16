import Foundation

public func reduce(_ state: AppState, _ action: Action) -> (events: [Event], effects: [Effect]) {
    switch action {

    // MARK: Repo lifecycle

    case let .createRepo(name, color, rootDir):
        // A newly-created repo starts with one Project whose workspace
        // IS the rootDir. The user is going to do at least one thing
        // here, and the empty-state otherwise looks broken.
        let initialProject = Project(
            id: UUID(),
            name: URL(fileURLWithPath: rootDir.path).lastPathComponent,
            workspace: Workspace(path: rootDir, kind: .folder, missing: false),
            tasks: [],
            archivedAt: nil,
            createdAt: Date()
        )
        let repo = Repo(
            id: UUID(),
            name: name,
            color: color,
            enabled: true,
            rootDir: rootDir,
            projects: [initialProject],
            externalConvos: [],
            createdAt: Date(),
            claudeInvocation: nil
        )
        let event = Event.repoCreated(repo)
        return ([event], [.persistEvents([event])])

    case let .renameRepo(id, name):
        guard state.repos.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.repoRenamed(id: id, name: name)
        return ([event], [.persistEvents([event])])

    case let .setRepoEnabled(id, enabled):
        guard let repo = state.repos.first(where: { $0.id == id }) else {
            return ([], [])
        }
        let event = Event.repoEnabledChanged(id: id, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(contentsOf: terminationEffects(forRepo: repo))
        }
        return ([event], effects)

    case let .setRepoColor(id, color):
        guard state.repos.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.repoColorChanged(id: id, color: color)
        return ([event], [.persistEvents([event])])

    case let .setRepoClaudeInvocation(id, invocation):
        guard state.repos.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.repoClaudeInvocationChanged(id: id, invocation: invocation)
        return ([event], [.persistEvents([event])])

    case let .setRepoRootDir(at):
        guard let project = findProject(state, at) else { return ([], []) }
        let event = Event.repoRootDirChanged(id: at.repo, rootDir: project.workspace.path)
        return ([event], [.persistEvents([event])])

    case let .deleteRepo(id):
        guard let repo = state.repos.first(where: { $0.id == id }) else {
            return ([], [])
        }
        var events: [Event] = [.repoDeleted(id: id)]
        if let sel = state.selectedTaskPath, sel.repo == id {
            events.append(.taskSelectionChanged(nil))
        }
        var effects: [Effect] = [.persistEvents(events)]
        effects.append(contentsOf: terminationEffects(forRepo: repo))
        return (events, effects)

    // MARK: Project lifecycle

    case let .createProject(repoId, name, workspace):
        guard let repo = state.repos.first(where: { $0.id == repoId }) else {
            return ([], [])
        }
        let project = Project(
            id: UUID(),
            name: name,
            workspace: workspace,
            tasks: [],
            archivedAt: nil,
            createdAt: Date()
        )
        let projectPath = ProjectPath(repo: repoId, project: project.id)
        let event = Event.projectCreated(repoId: repoId, project)
        var effects: [Effect] = [.persistEvents([event])]
        if case let .gitWorktree(branch, baseRef) = workspace.kind {
            effects.append(.createGitWorktree(
                projectPath: projectPath,
                repoRoot: repo.rootDir,
                branch: branch,
                path: workspace.path,
                baseRef: baseRef
            ))
        }
        return ([event], effects)

    case let .renameProject(at, name):
        guard findProject(state, at) != nil else { return ([], []) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }
        let event = Event.projectRenamed(at: at, name: trimmed)
        return ([event], [.persistEvents([event])])

    case let .archiveProject(at):
        guard let project = findProject(state, at) else { return ([], []) }
        if project.archivedAt != nil { return ([], []) }
        let when = Date()
        var events: [Event] = [.projectArchived(at: at, when: when)]
        if let sel = state.selectedTaskPath, sel.projectPath == at {
            events.append(.taskSelectionChanged(nil))
        }
        var effects: [Effect] = [.persistEvents(events)]
        effects.append(contentsOf: project.tasks.map { task in
            .terminate(at: TaskPath(repo: at.repo, project: at.project, task: task.id))
        })
        return (events, effects)

    case let .unarchiveProject(at):
        guard let project = findProject(state, at) else { return ([], []) }
        if project.archivedAt == nil { return ([], []) }
        let event = Event.projectUnarchived(at: at)
        return ([event], [.persistEvents([event])])

    case let .markProjectWorkspaceMissing(at):
        guard findProject(state, at) != nil else { return ([], []) }
        let event = Event.projectWorkspaceMarkedMissing(at: at)
        return ([event], [.persistEvents([event])])

    case let .deleteProject(at):
        guard let project = findProject(state, at) else { return ([], []) }
        var events: [Event] = [.projectDeleted(at: at)]
        if let sel = state.selectedTaskPath, sel.projectPath == at {
            events.append(.taskSelectionChanged(nil))
        }
        var effects: [Effect] = [.persistEvents(events)]
        effects.append(contentsOf: project.tasks.map { task in
            .terminate(at: TaskPath(repo: at.repo, project: at.project, task: task.id))
        })
        return (events, effects)

    // MARK: Task lifecycle

    case let .createTask(at, name, kind, spec, autoSelect):
        guard findProject(state, at) != nil else { return ([], []) }
        let task = Task(
            id: UUID(),
            name: name,
            kind: kind,
            enabled: true,
            spec: spec,
            runtime: .running(spawnedAt: Date()),
            unread: 0,
            createdAt: Date(),
            renamed: false
        )
        let taskPath = TaskPath(repo: at.repo, project: at.project, task: task.id)
        var events: [Event] = [.taskCreated(at: at, task)]
        if autoSelect {
            events.append(.taskSelectionChanged(taskPath))
        }
        let effects: [Effect] = [
            .persistEvents(events),
            .spawn(at: taskPath, spec: spec),
        ]
        return (events, effects)

    case let .setTaskEnabled(at, enabled):
        guard findTask(state, at) != nil else { return ([], []) }
        let event = Event.taskEnabledChanged(at: at, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(.terminate(at: at))
        }
        return ([event], effects)

    case let .linkClaudeSession(at, sessionId):
        guard let task = findTask(state, at), case .claude = task.kind else {
            return ([], [])
        }
        if let owner = state.taskOwningClaudeSession(sessionId), owner != at {
            return ([], [])
        }
        let event = Event.claudeSessionLinked(at: at, sessionId: sessionId)
        return ([event], [.persistEvents([event])])

    case let .renameTask(at, name):
        guard findTask(state, at) != nil else { return ([], []) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }
        let event = Event.taskRenamed(at: at, name: trimmed)
        return ([event], [.persistEvents([event])])

    case let .deleteTask(at):
        guard findTask(state, at) != nil else { return ([], []) }
        var events: [Event] = [.taskDeleted(at: at)]
        if state.selectedTaskPath == at {
            events.append(.taskSelectionChanged(nil))
        }
        let effects: [Effect] = [.persistEvents(events), .terminate(at: at)]
        return (events, effects)

    case let .completeTask(at):
        guard findTask(state, at) != nil else { return ([], []) }
        let event = Event.taskCompleted(at: at, completedAt: Date())
        let effects: [Effect] = [.persistEvents([event]), .terminate(at: at)]
        return ([event], effects)

    case let .bumpUnread(at, by):
        guard findTask(state, at) != nil, by > 0 else { return ([], []) }
        let event = Event.taskUnreadBumped(at: at, by: by)
        return ([event], [.persistEvents([event])])

    case let .markRead(at):
        guard let task = findTask(state, at), task.unread > 0 else { return ([], []) }
        let event = Event.taskRead(at: at)
        return ([event], [.persistEvents([event])])

    case let .restartTask(at):
        guard let task = findTask(state, at) else { return ([], []) }
        if task.spec.command == "(external claude)" { return ([], []) }
        let now = Date()
        let event = Event.taskSpawned(at: at, when: now)
        let effects: [Effect] = [
            .persistEvents([event]),
            .spawn(at: at, spec: task.spec),
        ]
        return ([event], effects)

    case let .setTaskSpec(at, spec):
        guard findTask(state, at) != nil else { return ([], []) }
        let event = Event.taskSpecChanged(at: at, spec: spec)
        return ([event], [.persistEvents([event])])

    case let .taskSpawned(at, when):
        guard findTask(state, at) != nil else { return ([], []) }
        let event = Event.taskSpawned(at: at, when: when)
        return ([event], [.persistEvents([event])])

    case let .taskExited(at, when, code):
        guard let task = findTask(state, at) else { return ([], []) }
        let event = Event.taskExited(at: at, when: when, code: code)
        var effects: [Effect] = [.persistEvents([event])]
        if case .completed = task.runtime {
            // user-initiated completion; no notification
        } else {
            effects.append(.userNotification(
                title: "Task “\(task.name)” exited",
                body: code == 0 ? "completed" : "exit code \(code)"
            ))
        }
        return ([event], effects)

    // MARK: External convos

    case let .discoverExternalConvo(repoId, sessionId, cwd):
        guard state.repos.contains(where: { $0.id == repoId }) else { return ([], []) }
        // Globally idempotent: ignore a sid we already track anywhere
        // (as a task or as an external convo in any repo).
        if state.taskOwningClaudeSession(sessionId) != nil { return ([], []) }
        if state.repos.contains(where: { repo in
            repo.externalConvos.contains(where: { $0.sessionId == sessionId })
        }) { return ([], []) }
        let convo = ExternalConvo(
            id: UUID(),
            sessionId: sessionId,
            cwd: cwd,
            firstSeenAt: Date()
        )
        let event = Event.externalConvoDiscovered(repoId: repoId, convo)
        return ([event], [.persistEvents([event])])

    case let .dismissExternalConvo(at):
        guard findExternalConvo(state, at) != nil else { return ([], []) }
        let event = Event.externalConvoDismissed(at: at)
        return ([event], [.persistEvents([event])])

    case let .adoptExternalConvo(at, into, name):
        guard let convo = findExternalConvo(state, at),
              findProject(state, into) != nil,
              let repo = state.repos.first(where: { $0.id == into.repo })
        else { return ([], []) }
        if state.taskOwningClaudeSession(convo.sessionId) != nil {
            return ([], [])
        }
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: state.settings
        )
        let spec = ClaudeTaskSpec.make(
            cwd: convo.cwd,
            sessionId: convo.sessionId,
            invocation: invocation
        )
        let task = Task(
            id: UUID(),
            name: name,
            kind: .claude(sessionId: convo.sessionId),
            enabled: true,
            spec: spec,
            runtime: .running(spawnedAt: Date()),
            unread: 0,
            createdAt: Date(),
            renamed: false
        )
        let taskPath = TaskPath(repo: into.repo, project: into.project, task: task.id)
        let events: [Event] = [
            .taskCreated(at: into, task),
            .externalConvoDismissed(at: at),
            .taskSelectionChanged(taskPath),
        ]
        let effects: [Effect] = [
            .persistEvents(events),
            .spawn(at: taskPath, spec: spec),
        ]
        return (events, effects)

    // MARK: Selection

    case let .selectTask(at):
        if let at, findTask(state, at) == nil { return ([], []) }
        if state.selectedTaskPath == at { return ([], []) }
        let event = Event.taskSelectionChanged(at)
        return ([event], [.persistEvents([event])])

    // MARK: Settings

    case let .updateSettings(settings):
        let event = Event.settingsUpdated(settings)
        return ([event], [.persistEvents([event])])
    }
}

public func apply(_ state: inout AppState, _ event: Event) {
    switch event {

    case let .repoCreated(repo):
        state.repos.append(repo)

    case let .repoRenamed(id, name):
        if let i = state.repos.firstIndex(where: { $0.id == id }) {
            state.repos[i].name = name
        }

    case let .repoColorChanged(id, color):
        if let i = state.repos.firstIndex(where: { $0.id == id }) {
            state.repos[i].color = color
        }

    case let .repoClaudeInvocationChanged(id, invocation):
        if let i = state.repos.firstIndex(where: { $0.id == id }) {
            state.repos[i].claudeInvocation = invocation
        }

    case let .repoEnabledChanged(id, enabled):
        if let i = state.repos.firstIndex(where: { $0.id == id }) {
            state.repos[i].enabled = enabled
        }

    case let .repoRootDirChanged(id, rootDir):
        if let i = state.repos.firstIndex(where: { $0.id == id }) {
            state.repos[i].rootDir = rootDir
        }

    case let .repoDeleted(id):
        let lost = state.repos
            .first(where: { $0.id == id })?
            .projects.reduce(0) { $0 + $1.tasks.count } ?? 0
        if lost > 0 {
            print("[reducer] repoDeleted \(id) removed \(lost) tasks")
        }
        state.repos.removeAll(where: { $0.id == id })

    case let .projectCreated(repoId, project):
        if let i = state.repos.firstIndex(where: { $0.id == repoId }) {
            state.repos[i].projects.append(project)
        }

    case let .projectRenamed(at, name):
        mutateProject(&state, at) { $0.name = name }

    case let .projectArchived(at, when):
        mutateProject(&state, at) { $0.archivedAt = when }

    case let .projectUnarchived(at):
        mutateProject(&state, at) { $0.archivedAt = nil }

    case let .projectWorkspaceMarkedMissing(at):
        mutateProject(&state, at) { $0.workspace.missing = true }

    case let .projectDeleted(at):
        if let ri = state.repos.firstIndex(where: { $0.id == at.repo }) {
            let lost = state.repos[ri].projects
                .first(where: { $0.id == at.project })?.tasks.count ?? 0
            if lost > 0 {
                print("[reducer] projectDeleted \(at.project) removed \(lost) tasks")
            }
            state.repos[ri].projects.removeAll(where: { $0.id == at.project })
        }

    case let .taskCreated(at, task):
        mutateProject(&state, at) { $0.tasks.append(task) }

    case let .taskEnabledChanged(at, enabled):
        mutateTask(&state, at) { $0.enabled = enabled }

    case let .taskCompleted(at, completedAt):
        mutateTask(&state, at) { $0.runtime = .completed(at: completedAt) }

    case let .taskUnreadBumped(at, by):
        mutateTask(&state, at) { $0.unread += by }

    case let .taskRead(at):
        mutateTask(&state, at) { $0.unread = 0 }

    case let .taskRenamed(at, name):
        mutateTask(&state, at) {
            $0.name = name
            $0.renamed = true
        }

    case let .taskDeleted(at):
        if let ri = state.repos.firstIndex(where: { $0.id == at.repo }),
           let pi = state.repos[ri].projects.firstIndex(where: { $0.id == at.project }) {
            print("[reducer] taskDeleted \(at.task)")
            state.repos[ri].projects[pi].tasks.removeAll { $0.id == at.task }
        }

    case let .taskSpecChanged(at, spec):
        mutateTask(&state, at) { $0.spec = spec }

    case let .claudeSessionLinked(at, sessionId):
        mutateTask(&state, at) {
            if case .claude = $0.kind {
                $0.kind = .claude(sessionId: sessionId)
            }
        }

    case let .externalConvoDiscovered(repoId, convo):
        if let i = state.repos.firstIndex(where: { $0.id == repoId }) {
            state.repos[i].externalConvos.append(convo)
        }

    case let .externalConvoDismissed(at):
        if let i = state.repos.firstIndex(where: { $0.id == at.repo }) {
            state.repos[i].externalConvos.removeAll(where: { $0.id == at.convo })
        }

    case let .taskSpawned(at, when):
        mutateTask(&state, at) { $0.runtime = .running(spawnedAt: when) }

    case let .taskExited(at, when, code):
        mutateTask(&state, at) { task in
            if case .completed = task.runtime { return }
            task.runtime = .exited(at: when, code: code)
        }

    case let .taskSelectionChanged(path):
        state.selectedTaskPath = path

    case let .settingsUpdated(settings):
        state.settings = settings
    }
}

// MARK: - Helpers

private func terminationEffects(forRepo repo: Repo) -> [Effect] {
    repo.projects.flatMap { project in
        project.tasks.map { task in
            .terminate(at: TaskPath(repo: repo.id, project: project.id, task: task.id))
        }
    }
}

private func findProject(_ state: AppState, _ at: ProjectPath) -> Project? {
    guard let repo = state.repos.first(where: { $0.id == at.repo }) else {
        return nil
    }
    return repo.projects.first(where: { $0.id == at.project })
}

private func findTask(_ state: AppState, _ at: TaskPath) -> Task? {
    guard let repo = state.repos.first(where: { $0.id == at.repo }),
          let project = repo.projects.first(where: { $0.id == at.project })
    else { return nil }
    return project.tasks.first(where: { $0.id == at.task })
}

private func findExternalConvo(_ state: AppState, _ at: ExternalConvoPath) -> ExternalConvo? {
    guard let repo = state.repos.first(where: { $0.id == at.repo }) else {
        return nil
    }
    return repo.externalConvos.first(where: { $0.id == at.convo })
}

private func mutateProject(
    _ state: inout AppState,
    _ at: ProjectPath,
    _ mutate: (inout Project) -> Void
) {
    guard let ri = state.repos.firstIndex(where: { $0.id == at.repo }) else { return }
    guard let pi = state.repos[ri].projects.firstIndex(where: { $0.id == at.project }) else { return }
    mutate(&state.repos[ri].projects[pi])
}

private func mutateTask(
    _ state: inout AppState,
    _ at: TaskPath,
    _ mutate: (inout Task) -> Void
) {
    guard let ri = state.repos.firstIndex(where: { $0.id == at.repo }) else { return }
    guard let pi = state.repos[ri].projects.firstIndex(where: { $0.id == at.project }) else { return }
    guard let ti = state.repos[ri].projects[pi].tasks.firstIndex(where: { $0.id == at.task }) else { return }
    mutate(&state.repos[ri].projects[pi].tasks[ti])
}
