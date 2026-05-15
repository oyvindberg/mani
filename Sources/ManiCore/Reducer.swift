import Foundation

public func reduce(_ state: AppState, _ action: Action) -> (events: [Event], effects: [Effect]) {
    switch action {

    case let .createRepo(name, color, rootDir):
        // The repo's primary workspace is implicit: a Worktree is
        // materialized at the rootDir so the sidebar has a row and tasks
        // spawned at the repo root have somewhere to attach.
        let initialWorktree = Worktree(
            id: UUID(),
            path: rootDir,
            kind: .folder,
            enabled: true,
            missing: false,
            tasks: [],
            createdAt: Date()
        )
        let repo = Repo(
            id: UUID(),
            name: name,
            color: color,
            enabled: true,
            rootDir: rootDir,
            worktrees: [initialWorktree],
            createdAt: Date(),
            claudeInvocation: nil
        )
        let event = Event.repoCreated(repo)
        return ([event], [.persistEvents([event])])

    case let .renameRepo(id, name):
        guard state.repos.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.repoRenamed(id: id, name: name)
        return ([event], [.persistEvents([event])])

    case let .setProjectEnabled(id, enabled):
        guard let repo = state.repos.first(where: { $0.id == id }) else {
            return ([], [])
        }
        let event = Event.repoEnabledChanged(id: id, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(contentsOf: terminationEffects(forRepo: repo))
        }
        return ([event], effects)

    case let .setProjectColor(id, color):
        guard state.repos.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.repoColorChanged(id: id, color: color)
        return ([event], [.persistEvents([event])])

    case let .setProjectClaudeInvocation(id, invocation):
        guard state.repos.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.repoClaudeInvocationChanged(id: id, invocation: invocation)
        return ([event], [.persistEvents([event])])

    case let .setProjectRootDir(at):
        guard let worktree = findWorktree(state, at) else { return ([], []) }
        let event = Event.repoRootDirChanged(id: at.repo, rootDir: worktree.path)
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

    case let .createWorktree(repoId, kind, path):
        guard let repo = state.repos.first(where: { $0.id == repoId }) else {
            return ([], [])
        }
        let worktree = Worktree(
            id: UUID(),
            path: path,
            kind: kind,
            enabled: true,
            missing: false,
            tasks: [],
            createdAt: Date()
        )
        let event = Event.worktreeCreated(repoId: repoId, worktree)
        var effects: [Effect] = [.persistEvents([event])]
        if case let .git(branch, baseRef) = kind {
            effects.append(.createGitWorktree(
                repoId: repoId,
                repoRoot: repo.rootDir,
                branch: branch,
                path: path,
                baseRef: baseRef
            ))
        }
        return ([event], effects)

    case let .setWorktreeEnabled(at, enabled):
        guard let worktree = findWorktree(state, at) else { return ([], []) }
        let event = Event.worktreeEnabledChanged(at: at, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(contentsOf: terminationEffects(forWorktree: worktree, at: at))
        }
        return ([event], effects)

    case let .markWorktreeMissing(at):
        guard findWorktree(state, at) != nil else { return ([], []) }
        let event = Event.worktreeMarkedMissing(at: at)
        return ([event], [.persistEvents([event])])

    case let .deleteWorktree(at):
        guard let worktree = findWorktree(state, at) else { return ([], []) }
        var events: [Event] = [.worktreeDeleted(at: at)]
        if let sel = state.selectedTaskPath, sel.worktreePath == at {
            events.append(.taskSelectionChanged(nil))
        }
        var effects: [Effect] = [.persistEvents(events)]
        effects.append(contentsOf: terminationEffects(forWorktree: worktree, at: at))
        return (events, effects)

    case let .createTask(at, name, kind, spec, autoSelect):
        guard findWorktree(state, at) != nil else { return ([], []) }
        // Externally-discovered claude tasks never get a spawn effect —
        // those flow through .discoverClaudeSession. Everything else
        // starts as .running (the spawn is fired immediately); the
        // EffectRunner reports back .taskExited if the spawn fails.
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
        let taskPath = TaskPath(repo: at.repo, worktree: at.worktree, task: task.id)
        var events: [Event] = [.taskCreated(at: at, task)]
        if autoSelect {
            events.append(.taskSelectionChanged(taskPath))
        }
        let effects: [Effect] = [
            .persistEvents(events),
            .spawn(at: taskPath, spec: spec)
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
        // Globally idempotent: refuse to link if a different task already
        // tracks this session id. claude sessions live in one cwd, so
        // duplicates would be a bug.
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

    case let .discoverClaudeSession(at, sessionId, cwd):
        guard findWorktree(state, at) != nil else { return ([], []) }
        // Globally idempotent: a claude session must be tracked by at most
        // one task. If any task already has it, no-op.
        if state.taskOwningClaudeSession(sessionId) != nil {
            return ([], [])
        }
        // External claude tasks: we don't own the process. spec.command is
        // a sentinel string that lets the UI and respawn paths distinguish
        // them. runtime stays .neverStarted — there's no agent to attach to.
        let task = Task(
            id: UUID(),
            name: "claude",
            kind: .claude(sessionId: sessionId),
            enabled: true,
            spec: ProcessSpec(
                command: "(external claude)",
                args: [],
                env: [:],
                cwd: cwd,
                initialInput: nil
            ),
            runtime: .neverStarted,
            unread: 0,
            createdAt: Date(),
            renamed: false
        )
        let event = Event.taskCreated(at: at, task)
        return ([event], [.persistEvents([event])])

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
        // External claudes have no agent of ours to restart; reject quietly.
        if task.spec.command == "(external claude)" { return ([], []) }
        // We emit ONLY .spawn — the EffectRunner's spawn handler is
        // idempotent: it terminates any existing agent for this task.id
        // and waits for the socket to disappear before launching the
        // replacement. Emitting a separate .terminate here would race
        // the spawn (both run on independent Tasks from the Store) and
        // produced the "code -1 on Restart" symptom.
        // .taskSpawned is emitted optimistically; if spawn fails the
        // EffectRunner dispatches .taskExited to reconcile.
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
        // Only notify if the user hadn't already marked it completed.
        // (.completed → .exited is suppressed below in apply, but the
        // notification is reducer-time.)
        if case .completed = task.runtime {
            // user-initiated completion; no notification
        } else {
            effects.append(.userNotification(
                title: "Task “\(task.name)” exited",
                body: code == 0 ? "completed" : "exit code \(code)"
            ))
        }
        return ([event], effects)

    case let .selectTask(at):
        // Refuse to set a selection pointing at a non-existent task so
        // the UI never has to defend against dangling selections.
        if let at, findTask(state, at) == nil { return ([], []) }
        if state.selectedTaskPath == at { return ([], []) }
        let event = Event.taskSelectionChanged(at)
        return ([event], [.persistEvents([event])])

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
        // Every implicit task loss in this codebase has been traced to
        // a cascade through here. Log so the next regression is one
        // grep away.
        let lost = state.repos
            .first(where: { $0.id == id })?
            .worktrees.reduce(0) { $0 + $1.tasks.count } ?? 0
        if lost > 0 {
            print("[reducer] repoDeleted \(id) removed \(lost) tasks")
        }
        state.repos.removeAll(where: { $0.id == id })

    case let .worktreeCreated(repoId, worktree):
        if let i = state.repos.firstIndex(where: { $0.id == repoId }) {
            state.repos[i].worktrees.append(worktree)
        }

    case let .worktreeEnabledChanged(at, enabled):
        mutateWorktree(&state, at) { $0.enabled = enabled }

    case let .worktreeMarkedMissing(at):
        mutateWorktree(&state, at) { $0.missing = true }

    case let .worktreeDeleted(at):
        if let pi = state.repos.firstIndex(where: { $0.id == at.repo }) {
            let lost = state.repos[pi].worktrees
                .first(where: { $0.id == at.worktree })?.tasks.count ?? 0
            if lost > 0 {
                print("[reducer] worktreeDeleted \(at.worktree) removed \(lost) tasks")
            }
            state.repos[pi].worktrees.removeAll(where: { $0.id == at.worktree })
        }

    case let .taskCreated(at, task):
        mutateWorktree(&state, at) { $0.tasks.append(task) }

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
        if let pi = state.repos.firstIndex(where: { $0.id == at.repo }),
           let wi = state.repos[pi].worktrees.firstIndex(where: { $0.id == at.worktree }) {
            print("[reducer] taskDeleted \(at.task)")
            state.repos[pi].worktrees[wi].tasks.removeAll { $0.id == at.task }
        }

    case let .taskSpecChanged(at, spec):
        mutateTask(&state, at) { $0.spec = spec }

    case let .claudeSessionLinked(at, sessionId):
        mutateTask(&state, at) {
            if case .claude = $0.kind {
                $0.kind = .claude(sessionId: sessionId)
            }
        }

    case let .taskSpawned(at, when):
        mutateTask(&state, at) { $0.runtime = .running(spawnedAt: when) }

    case let .taskExited(at, when, code):
        mutateTask(&state, at) { task in
            // Don't downgrade a user-completed task back to .exited —
            // completion is the user's intent, exit is the kernel's
            // notification, and we keep the user's intent visible.
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

// Termination effects fan out by TaskPath only. The host resolves
// task → agent → kernel pid internally; the reducer doesn't model it.
private func terminationEffects(forRepo repo: Repo) -> [Effect] {
    repo.worktrees.flatMap { worktree in
        let wtPath = WorktreePath(repo: repo.id, worktree: worktree.id)
        return terminationEffects(forWorktree: worktree, at: wtPath)
    }
}

private func terminationEffects(forWorktree worktree: Worktree, at: WorktreePath) -> [Effect] {
    worktree.tasks.map { task in
        .terminate(at: TaskPath(
            repo: at.repo, worktree: at.worktree, task: task.id
        ))
    }
}

private func findWorktree(_ state: AppState, _ at: WorktreePath) -> Worktree? {
    guard let repo = state.repos.first(where: { $0.id == at.repo }) else {
        return nil
    }
    return repo.worktrees.first(where: { $0.id == at.worktree })
}

private func findTask(_ state: AppState, _ at: TaskPath) -> Task? {
    guard let repo = state.repos.first(where: { $0.id == at.repo }),
          let worktree = repo.worktrees.first(where: { $0.id == at.worktree }) else {
        return nil
    }
    return worktree.tasks.first(where: { $0.id == at.task })
}

private func mutateWorktree(
    _ state: inout AppState,
    _ at: WorktreePath,
    _ mutate: (inout Worktree) -> Void
) {
    guard let pi = state.repos.firstIndex(where: { $0.id == at.repo }) else { return }
    guard let wi = state.repos[pi].worktrees.firstIndex(where: { $0.id == at.worktree }) else { return }
    mutate(&state.repos[pi].worktrees[wi])
}

private func mutateTask(
    _ state: inout AppState,
    _ at: TaskPath,
    _ mutate: (inout Task) -> Void
) {
    guard let pi = state.repos.firstIndex(where: { $0.id == at.repo }) else { return }
    guard let wi = state.repos[pi].worktrees.firstIndex(where: { $0.id == at.worktree }) else { return }
    guard let ti = state.repos[pi].worktrees[wi].tasks.firstIndex(where: { $0.id == at.task }) else { return }
    mutate(&state.repos[pi].worktrees[wi].tasks[ti])
}
