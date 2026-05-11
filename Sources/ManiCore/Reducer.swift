import Foundation

public func reduce(_ state: AppState, _ action: Action) -> (events: [Event], effects: [Effect]) {
    switch action {

    case let .createProject(name, color):
        let project = Project(
            id: UUID(),
            name: name,
            color: color,
            enabled: true,
            worktrees: [],
            createdAt: Date()
        )
        let event = Event.projectCreated(project)
        return ([event], [.persistEvents([event])])

    case let .renameProject(id, name):
        guard state.projects.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.projectRenamed(id: id, name: name)
        return ([event], [.persistEvents([event])])

    case let .setProjectEnabled(id, enabled):
        guard let project = state.projects.first(where: { $0.id == id }) else {
            return ([], [])
        }
        let event = Event.projectEnabledChanged(id: id, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(contentsOf: terminationEffects(forProject: project))
        }
        return ([event], effects)

    case let .setProjectColor(id, color):
        guard state.projects.contains(where: { $0.id == id }) else { return ([], []) }
        let event = Event.projectColorChanged(id: id, color: color)
        return ([event], [.persistEvents([event])])

    case let .deleteProject(id):
        guard let project = state.projects.first(where: { $0.id == id }) else {
            return ([], [])
        }
        let event = Event.projectDeleted(id: id)
        var effects: [Effect] = [.persistEvents([event])]
        effects.append(contentsOf: terminationEffects(forProject: project))
        return ([event], effects)

    case let .createWorktree(projectId, name, kind, path):
        guard let project = state.projects.first(where: { $0.id == projectId }) else {
            return ([], [])
        }
        // First worktree added becomes primary automatically; the user
        // can promote a different one later via setWorktreePrimary.
        let isFirstWorktree = project.worktrees.isEmpty
        let worktree = Worktree(
            id: UUID(),
            name: name,
            path: path,
            kind: kind,
            enabled: true,
            missing: false,
            jobs: [],
            createdAt: Date(),
            primary: isFirstWorktree
        )
        let event = Event.worktreeCreated(projectId: projectId, worktree)
        var effects: [Effect] = [.persistEvents([event])]
        if case let .git(branch, baseRef) = kind {
            // `git worktree add` runs in the project's primary worktree
            // (its checkout's gitdir). Without a primary we skip the
            // effect; the worktree row appears in the sidebar as a
            // bare path that the user can populate manually.
            if let primary = project.worktrees.first(where: { $0.primary }) {
                effects.append(.createGitWorktree(
                    projectId: projectId,
                    repoRoot: primary.path,
                    branch: branch,
                    path: path,
                    baseRef: baseRef
                ))
            }
        }
        return ([event], effects)

    case let .setWorktreePrimary(at):
        guard findWorktree(state, at) != nil else { return ([], []) }
        let event = Event.worktreePrimaryChanged(at: at)
        return ([event], [.persistEvents([event])])

    case let .setWorktreeEnabled(at, enabled):
        guard let worktree = findWorktree(state, at) else { return ([], []) }
        let event = Event.worktreeEnabledChanged(at: at, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(contentsOf: terminationEffects(forWorktree: worktree))
        }
        return ([event], effects)

    case let .markWorktreeMissing(at):
        guard findWorktree(state, at) != nil else { return ([], []) }
        let event = Event.worktreeMarkedMissing(at: at)
        return ([event], [.persistEvents([event])])

    case let .deleteWorktree(at):
        guard let worktree = findWorktree(state, at) else { return ([], []) }
        let event = Event.worktreeDeleted(at: at)
        var effects: [Effect] = [.persistEvents([event])]
        effects.append(contentsOf: terminationEffects(forWorktree: worktree))
        return ([event], effects)

    case let .createJob(at, name, kind, primary, auxiliary):
        guard findWorktree(state, at) != nil else { return ([], []) }
        let job = Job(
            id: UUID(),
            name: name,
            kind: kind,
            enabled: true,
            status: .running,
            primary: primary,
            auxiliary: auxiliary,
            unread: 0,
            createdAt: Date(),
            completedAt: nil,
            renamed: false
        )
        let jobPath = JobPath(project: at.project, worktree: at.worktree, job: job.id)
        let event = Event.jobCreated(at: at, job)
        var effects: [Effect] = [
            .persistEvents([event]),
            .spawn(at: jobPath, index: 0, primary)
        ]
        for (i, aux) in auxiliary.enumerated() {
            effects.append(.spawn(at: jobPath, index: i + 1, aux))
        }
        return ([event], effects)

    case let .setJobEnabled(at, enabled):
        guard let job = findJob(state, at) else { return ([], []) }
        let event = Event.jobEnabledChanged(at: at, enabled: enabled)
        var effects: [Effect] = [.persistEvents([event])]
        if !enabled {
            effects.append(contentsOf: terminationEffects(forJob: job))
        }
        return ([event], effects)

    case let .linkClaudeSession(at, sessionId):
        guard let job = findJob(state, at), case .claude = job.kind else {
            return ([], [])
        }
        // Globally idempotent: refuse to link if a different job (anywhere
        // in state) already tracks this session id. claude sessions live
        // in a single cwd / worktree, so duplicates would be a bug.
        if let owner = state.jobOwningClaudeSession(sessionId), owner != at {
            return ([], [])
        }
        let event = Event.claudeSessionLinked(at: at, sessionId: sessionId)
        return ([event], [.persistEvents([event])])

    case let .renameJob(at, name):
        guard findJob(state, at) != nil else { return ([], []) }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return ([], []) }
        let event = Event.jobRenamed(at: at, name: trimmed)
        return ([event], [.persistEvents([event])])

    case let .deleteJob(at):
        guard let job = findJob(state, at) else { return ([], []) }
        let event = Event.jobDeleted(at: at)
        var effects: [Effect] = [.persistEvents([event])]
        // Terminate any live processes before removing the job from state,
        // so the EffectRunner cleans up its PTY map. Primary + aux pids
        // both qualify.
        if let pid = job.primary.pid {
            effects.append(.terminate(pid: pid, escalateAfter: 1.0))
        }
        for aux in job.auxiliary {
            if let pid = aux.pid {
                effects.append(.terminate(pid: pid, escalateAfter: 1.0))
            }
        }
        return ([event], effects)

    case let .discoverClaudeSession(at, sessionId, cwd):
        guard findWorktree(state, at) != nil else { return ([], []) }
        // Globally idempotent: a claude session must be tracked by at most
        // one job across the entire state. If any job already has it, no-op.
        if state.jobOwningClaudeSession(sessionId) != nil {
            return ([], [])
        }
        let job = Job(
            id: UUID(),
            name: "claude",
            kind: .claude(sessionId: sessionId),
            enabled: true,
            status: .running,
            // Placeholder spec — we don't own the process. Storing the cwd lets
            // recovery / scrollback restore know where it lives.
            primary: ProcessSpec(
                command: "(external claude)",
                args: [],
                env: [:],
                cwd: cwd,
                pid: nil,
                initialInput: nil, restartPolicy: .never),
            auxiliary: [],
            unread: 0,
            createdAt: Date(),
            completedAt: nil,
            renamed: false
        )
        let event = Event.jobCreated(at: at, job)
        return ([event], [.persistEvents([event])])

    case let .completeJob(at):
        guard let job = findJob(state, at) else { return ([], []) }
        let event = Event.jobCompleted(at: at, completedAt: Date())
        var effects: [Effect] = [.persistEvents([event])]
        effects.append(contentsOf: terminationEffects(forJob: job))
        return ([event], effects)

    case let .bumpUnread(at, by):
        guard findJob(state, at) != nil, by > 0 else { return ([], []) }
        let event = Event.jobUnreadBumped(at: at, by: by)
        return ([event], [.persistEvents([event])])

    case let .markRead(at):
        guard let job = findJob(state, at), job.unread > 0 else { return ([], []) }
        let event = Event.jobRead(at: at)
        return ([event], [.persistEvents([event])])

    case let .processStarted(at, index, pid):
        guard findJob(state, at) != nil else { return ([], []) }
        let event = Event.processStarted(at: at, index: index, pid: pid)
        return ([event], [.persistEvents([event])])

    case let .processExited(at, index, code):
        guard let job = findJob(state, at) else { return ([], []) }
        let event = Event.processExited(at: at, index: index, code: code)
        var effects: [Effect] = [.persistEvents([event])]
        if index == 0 {
            effects.append(.userNotification(
                title: "Task “\(job.name)” exited",
                body: code == 0 ? "completed" : "exit code \(code)"
            ))
        } else if job.enabled,
                  index - 1 < job.auxiliary.count,
                  job.auxiliary[index - 1].restartPolicy == .alwaysRestart {
            // Aux process with alwaysRestart fires a fresh spawn. Primary
            // restart is intentionally NOT modeled here — the user controls
            // primary lifecycle via the UI's Restart button.
            effects.append(.spawn(at: at, index: index, job.auxiliary[index - 1]))
        }
        return ([event], effects)

    case let .updateSettings(settings):
        let event = Event.settingsUpdated(settings)
        return ([event], [.persistEvents([event])])
    }
}

public func apply(_ state: inout AppState, _ event: Event) {
    switch event {

    case let .projectCreated(project):
        state.projects.append(project)

    case let .projectRenamed(id, name):
        if let i = state.projects.firstIndex(where: { $0.id == id }) {
            state.projects[i].name = name
        }

    case let .projectColorChanged(id, color):
        if let i = state.projects.firstIndex(where: { $0.id == id }) {
            state.projects[i].color = color
        }

    case let .projectEnabledChanged(id, enabled):
        if let i = state.projects.firstIndex(where: { $0.id == id }) {
            state.projects[i].enabled = enabled
        }

    case let .projectDeleted(id):
        state.projects.removeAll(where: { $0.id == id })

    case let .worktreeCreated(projectId, worktree):
        if let i = state.projects.firstIndex(where: { $0.id == projectId }) {
            state.projects[i].worktrees.append(worktree)
        }

    case let .worktreeEnabledChanged(at, enabled):
        mutateWorktree(&state, at) { $0.enabled = enabled }

    case let .worktreeMarkedMissing(at):
        mutateWorktree(&state, at) { $0.missing = true }

    case let .worktreePrimaryChanged(at):
        if let pi = state.projects.firstIndex(where: { $0.id == at.project }) {
            for wi in state.projects[pi].worktrees.indices {
                state.projects[pi].worktrees[wi].primary =
                    (state.projects[pi].worktrees[wi].id == at.worktree)
            }
        }

    case let .worktreeDeleted(at):
        if let pi = state.projects.firstIndex(where: { $0.id == at.project }) {
            state.projects[pi].worktrees.removeAll(where: { $0.id == at.worktree })
        }

    case let .jobCreated(at, job):
        mutateWorktree(&state, at) { $0.jobs.append(job) }

    case let .jobEnabledChanged(at, enabled):
        mutateJob(&state, at) { $0.enabled = enabled }

    case let .jobStatusChanged(at, status):
        mutateJob(&state, at) { $0.status = status }

    case let .jobCompleted(at, completedAt):
        mutateJob(&state, at) {
            $0.status = .completed
            $0.completedAt = completedAt
        }

    case let .jobUnreadBumped(at, by):
        mutateJob(&state, at) { $0.unread += by }

    case let .jobRead(at):
        mutateJob(&state, at) { $0.unread = 0 }

    case let .jobRenamed(at, name):
        mutateJob(&state, at) {
            $0.name = name
            $0.renamed = true
        }

    case let .jobDeleted(at):
        if let pi = state.projects.firstIndex(where: { $0.id == at.project }),
           let wi = state.projects[pi].worktrees.firstIndex(where: { $0.id == at.worktree }) {
            state.projects[pi].worktrees[wi].jobs.removeAll { $0.id == at.job }
        }

    case let .claudeSessionLinked(at, sessionId):
        mutateJob(&state, at) {
            if case .claude = $0.kind {
                $0.kind = .claude(sessionId: sessionId)
            }
        }

    case let .processStarted(at, index, pid):
        mutateJob(&state, at) { job in
            if index == 0 {
                job.primary.pid = pid
            } else if index - 1 < job.auxiliary.count {
                job.auxiliary[index - 1].pid = pid
            }
        }

    case let .processExited(at, index, _):
        mutateJob(&state, at) { job in
            if index == 0 {
                job.primary.pid = nil
            } else if index - 1 < job.auxiliary.count {
                job.auxiliary[index - 1].pid = nil
            }
        }

    case let .settingsUpdated(settings):
        state.settings = settings
    }
}

// MARK: - Helpers

private func terminationEffects(forProject project: Project) -> [Effect] {
    project.worktrees.flatMap { terminationEffects(forWorktree: $0) }
}

private func terminationEffects(forWorktree worktree: Worktree) -> [Effect] {
    worktree.jobs.flatMap { terminationEffects(forJob: $0) }
}

private func terminationEffects(forJob job: Job) -> [Effect] {
    var effects: [Effect] = []
    if let pid = job.primary.pid {
        effects.append(.terminate(pid: pid, escalateAfter: 5))
    }
    for aux in job.auxiliary {
        if let pid = aux.pid {
            effects.append(.terminate(pid: pid, escalateAfter: 5))
        }
    }
    return effects
}

private func findWorktree(_ state: AppState, _ at: WorktreePath) -> Worktree? {
    guard let project = state.projects.first(where: { $0.id == at.project }) else {
        return nil
    }
    return project.worktrees.first(where: { $0.id == at.worktree })
}

private func findJob(_ state: AppState, _ at: JobPath) -> Job? {
    guard let project = state.projects.first(where: { $0.id == at.project }),
          let worktree = project.worktrees.first(where: { $0.id == at.worktree }) else {
        return nil
    }
    return worktree.jobs.first(where: { $0.id == at.job })
}

private func mutateWorktree(
    _ state: inout AppState,
    _ at: WorktreePath,
    _ mutate: (inout Worktree) -> Void
) {
    guard let pi = state.projects.firstIndex(where: { $0.id == at.project }) else { return }
    guard let wi = state.projects[pi].worktrees.firstIndex(where: { $0.id == at.worktree }) else { return }
    mutate(&state.projects[pi].worktrees[wi])
}

private func mutateJob(
    _ state: inout AppState,
    _ at: JobPath,
    _ mutate: (inout Job) -> Void
) {
    guard let pi = state.projects.firstIndex(where: { $0.id == at.project }) else { return }
    guard let wi = state.projects[pi].worktrees.firstIndex(where: { $0.id == at.worktree }) else { return }
    guard let ji = state.projects[pi].worktrees[wi].jobs.firstIndex(where: { $0.id == at.job }) else { return }
    mutate(&state.projects[pi].worktrees[wi].jobs[ji])
}
