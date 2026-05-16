import XCTest
@testable import ManiCore

final class ReducerTests: XCTestCase {

    // MARK: - createRepo

    func test_createRepo_emitsEventAndPersistEffect() {
        let state = AppState.empty
        let action = Action.createRepo(
            name: "atlas",
            color: "#ff5500",
            rootDir: URL(fileURLWithPath: "/Users/me/atlas")
        )

        let (events, effects) = reduce(state, action)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(effects.count, 1)
        guard case let .repoCreated(repo) = events[0] else {
            return XCTFail("expected repoCreated, got \(events[0])")
        }
        XCTAssertEqual(repo.name, "atlas")
        XCTAssertEqual(repo.color, "#ff5500")
        XCTAssertTrue(repo.enabled)
        XCTAssertEqual(repo.rootDir.path, "/Users/me/atlas")
        XCTAssertEqual(repo.projects.count, 1)
        XCTAssertEqual(repo.projects[0].workspace.path.path, "/Users/me/atlas")
        XCTAssertTrue(repo.externalConvos.isEmpty)
    }

    func test_apply_repoCreated_appendsToState() {
        var state = AppState.empty
        let repo = makeRepo(id: UUID(), projects: [])
        apply(&state, .repoCreated(repo))
        XCTAssertEqual(state.repos.count, 1)
        XCTAssertEqual(state.repos[0].id, repo.id)
    }

    // MARK: - renameRepo

    func test_renameRepo_known_emitsEventAndApplies() {
        let id = UUID()
        var state = stateWith(repos: [makeRepo(id: id, projects: [])])
        let (events, _) = reduce(state, .renameRepo(id: id, name: "renamed"))
        XCTAssertEqual(events, [.repoRenamed(id: id, name: "renamed")])
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].name, "renamed")
    }

    // MARK: - setRepoEnabled cascades

    func test_setRepoEnabled_disabled_cascadesTerminations() {
        let repoId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: UUID(), tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])

        let (events, effects) = reduce(state, .setRepoEnabled(id: repoId, enabled: false))

        XCTAssertEqual(Set(terminatedTaskIds(in: effects)), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.repos[0].enabled)
    }

    // MARK: - deleteRepo

    func test_deleteRepo_cascadesTerminationsAndRemoves() {
        let repoId = UUID()
        let t1 = UUID()
        let t2 = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: UUID(), tasks: [
                    makeTask(id: t1, runtime: .running(spawnedAt: Date())),
                    makeTask(id: t2, runtime: .exited(at: Date(), code: 0)),
                ])
            ])
        ])

        let (events, effects) = reduce(state, .deleteRepo(id: repoId))

        XCTAssertEqual(events, [.repoDeleted(id: repoId)])
        XCTAssertEqual(Set(terminatedTaskIds(in: effects)), [t1, t2])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos.isEmpty)
    }

    // MARK: - createProject

    func test_createProject_folder_emitsEventOnly() {
        let repoId = UUID()
        var state = stateWith(repos: [makeRepo(id: repoId, projects: [])])

        let workspace = Workspace(
            path: URL(fileURLWithPath: "/wt/main"),
            kind: .folder,
            missing: false
        )
        let (events, effects) = reduce(state, .createProject(
            repoId: repoId,
            name: "main",
            workspace: workspace
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(effects.count, 1) // just persistEvents
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].projects.count, 1)
        XCTAssertEqual(state.repos[0].projects[0].name, "main")
        XCTAssertEqual(state.repos[0].projects[0].workspace.path.lastPathComponent, "main")
        XCTAssertFalse(state.repos[0].projects[0].workspace.missing)
    }

    func test_createProject_gitWorktree_emitsCreateGitWorktreeEffect() {
        let repoId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: repoId, projects: [])
        ])

        let workspace = Workspace(
            path: URL(fileURLWithPath: "/wt/feat"),
            kind: .gitWorktree(branch: "feat/auth", baseRef: "main"),
            missing: false
        )
        let (_, effects) = reduce(state, .createProject(
            repoId: repoId,
            name: "feat",
            workspace: workspace
        ))

        let createEffect = effects.first { effect in
            if case .createGitWorktree = effect { return true }
            return false
        }
        guard case let .createGitWorktree(projectPath, repoRoot, branch, path, baseRef) = createEffect else {
            return XCTFail("expected createGitWorktree effect")
        }
        XCTAssertEqual(projectPath.repo, repoId)
        XCTAssertEqual(repoRoot, URL(fileURLWithPath: "/wt/main"))
        XCTAssertEqual(branch, "feat/auth")
        XCTAssertEqual(path, URL(fileURLWithPath: "/wt/feat"))
        XCTAssertEqual(baseRef, "main")
    }

    func test_createProject_unknownRepo_isNoop() {
        let state = AppState.empty
        let workspace = Workspace(
            path: URL(fileURLWithPath: "/x"),
            kind: .folder,
            missing: false
        )
        let (events, effects) = reduce(state, .createProject(
            repoId: UUID(),
            name: "x",
            workspace: workspace
        ))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - archive / unarchive

    func test_archiveProject_emitsArchivedAndTerminations() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = ProjectPath(repo: repoId, project: projectId)

        let (events, effects) = reduce(state, .archiveProject(at: path))

        guard case .projectArchived = events.first else {
            return XCTFail("expected projectArchived event")
        }
        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertNotNil(state.repos[0].projects[0].archivedAt)
        XCTAssertTrue(state.repos[0].projects[0].isArchived)
    }

    func test_archiveProject_alreadyArchived_isNoop() {
        let repoId = UUID()
        let projectId = UUID()
        var project = makeProject(id: projectId, tasks: [])
        project.archivedAt = Date()
        let state = stateWith(repos: [makeRepo(id: repoId, projects: [project])])
        let path = ProjectPath(repo: repoId, project: projectId)

        let (events, _) = reduce(state, .archiveProject(at: path))
        XCTAssertTrue(events.isEmpty)
    }

    func test_unarchiveProject_revertsArchivedAt() {
        let repoId = UUID()
        let projectId = UUID()
        var project = makeProject(id: projectId, tasks: [])
        project.archivedAt = Date()
        var state = stateWith(repos: [makeRepo(id: repoId, projects: [project])])
        let path = ProjectPath(repo: repoId, project: projectId)

        let (events, _) = reduce(state, .unarchiveProject(at: path))
        XCTAssertEqual(events, [.projectUnarchived(at: path)])
        for e in events { apply(&state, e) }
        XCTAssertNil(state.repos[0].projects[0].archivedAt)
    }

    // MARK: - deleteProject

    func test_deleteProject_cascadesTerminationsAndRemoves() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = ProjectPath(repo: repoId, project: projectId)

        let (events, effects) = reduce(state, .deleteProject(at: path))

        XCTAssertEqual(events, [.projectDeleted(at: path)])
        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos[0].projects.isEmpty)
    }

    func test_deleteProject_deselectsIfSelectionInside() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        let projectPath = ProjectPath(repo: repoId, project: projectId)
        let selected = TaskPath(repo: repoId, project: projectId, task: taskId)
        var state = stateWith(
            repos: [makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])],
            selectedTaskPath: selected
        )

        let (events, _) = reduce(state, .deleteProject(at: projectPath))
        XCTAssertTrue(events.contains(.taskSelectionChanged(nil)))
        for e in events { apply(&state, e) }
        XCTAssertNil(state.selectedTaskPath)
    }

    // MARK: - markProjectWorkspaceMissing

    func test_markProjectWorkspaceMissing_setsMissingFlag() {
        let repoId = UUID()
        let projectId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [])
            ])
        ])
        let path = ProjectPath(repo: repoId, project: projectId)

        let (events, _) = reduce(state, .markProjectWorkspaceMissing(at: path))
        XCTAssertEqual(events, [.projectWorkspaceMarkedMissing(at: path)])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos[0].projects[0].workspace.missing)
    }

    // MARK: - createTask

    func test_createTask_emitsTaskCreatedSpawnAndAutoSelection() {
        let repoId = UUID()
        let projectId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [])
            ])
        ])
        let path = ProjectPath(repo: repoId, project: projectId)
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/wt"),
            initialInput: nil
        )

        let (events, effects) = reduce(state, .createTask(
            at: path, name: "shell", kind: .shell, spec: spec, autoSelect: true
        ))

        guard case let .taskCreated(receivedPath, task) = events.first else {
            return XCTFail("expected taskCreated event")
        }
        XCTAssertEqual(receivedPath, path)

        let expectedTaskPath = TaskPath(
            repo: repoId, project: projectId, task: task.id
        )
        XCTAssertEqual(events.count, 2)
        if case let .taskSelectionChanged(p) = events[1] {
            XCTAssertEqual(p, expectedTaskPath)
        } else {
            XCTFail("expected taskSelectionChanged as 2nd event")
        }

        let spawnIds = effects.compactMap { effect -> UUID? in
            if case let .spawn(p, _) = effect { return p.task }
            return nil
        }
        XCTAssertEqual(spawnIds, [task.id])

        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].projects[0].tasks.count, 1)
        XCTAssertEqual(state.selectedTaskPath, expectedTaskPath)
    }

    func test_createTask_autoSelectFalse_doesNotChangeSelection() {
        let repoId = UUID()
        let projectId = UUID()
        let priorSelected = TaskPath(
            repo: repoId, project: projectId, task: UUID()
        )
        let state = stateWith(
            repos: [makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: priorSelected.task, runtime: .running(spawnedAt: Date()))
                ])
            ])],
            selectedTaskPath: priorSelected
        )
        let path = ProjectPath(repo: repoId, project: projectId)
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/p"),
            initialInput: nil
        )

        let (events, _) = reduce(state, .createTask(
            at: path, name: "diff", kind: .diff, spec: spec, autoSelect: false
        ))

        XCTAssertEqual(events.count, 1)
        guard case .taskCreated = events.first else {
            return XCTFail("expected only taskCreated")
        }
    }

    // MARK: - runtime lifecycle

    func test_taskSpawned_setsRunning() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .exited(at: Date(), code: 1))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, project: projectId, task: taskId)
        let now = Date()

        let (events, _) = reduce(state, .taskSpawned(at: path, when: now))
        for e in events { apply(&state, e) }

        if case let .running(when) = state.repos[0].projects[0].tasks[0].runtime {
            XCTAssertEqual(when, now)
        } else {
            XCTFail("expected runtime = .running")
        }
    }

    func test_taskExited_doesNotDowngradeCompletedRuntime() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        let completedAt = Date()
        var state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .completed(at: completedAt))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, project: projectId, task: taskId)

        let (events, _) = reduce(state, .taskExited(at: path, when: Date(), code: -1))
        for e in events { apply(&state, e) }

        if case let .completed(when) = state.repos[0].projects[0].tasks[0].runtime {
            XCTAssertEqual(when, completedAt)
        } else {
            XCTFail("completed runtime must not be downgraded by taskExited")
        }
    }

    // MARK: - external convo discover / dismiss / adopt

    func test_discoverExternalConvo_appendsConvo() {
        let repoId = UUID()
        var state = stateWith(repos: [makeRepo(id: repoId, projects: [])])

        let (events, _) = reduce(state, .discoverExternalConvo(
            repoId: repoId,
            sessionId: "sid-1",
            cwd: URL(fileURLWithPath: "/r")
        ))

        XCTAssertEqual(events.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].externalConvos.count, 1)
        XCTAssertEqual(state.repos[0].externalConvos[0].sessionId, "sid-1")
    }

    func test_discoverExternalConvo_existingSid_isNoop() {
        let repoId = UUID()
        var repo = makeRepo(id: repoId, projects: [])
        repo.externalConvos = [ExternalConvo(
            id: UUID(), sessionId: "sid-1",
            cwd: URL(fileURLWithPath: "/r"), firstSeenAt: Date()
        )]
        let state = stateWith(repos: [repo])

        let (events, _) = reduce(state, .discoverExternalConvo(
            repoId: repoId,
            sessionId: "sid-1",
            cwd: URL(fileURLWithPath: "/r")
        ))
        XCTAssertTrue(events.isEmpty)
    }

    func test_discoverExternalConvo_sidAlreadyTrackedAsTask_isNoop() {
        let repoId = UUID()
        let projectId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(
                        id: UUID(),
                        kind: .claude(sessionId: "sid-1"),
                        runtime: .running(spawnedAt: Date())
                    )
                ])
            ])
        ])

        let (events, _) = reduce(state, .discoverExternalConvo(
            repoId: repoId,
            sessionId: "sid-1",
            cwd: URL(fileURLWithPath: "/r")
        ))
        XCTAssertTrue(events.isEmpty)
    }

    func test_dismissExternalConvo_removes() {
        let repoId = UUID()
        let convoId = UUID()
        var repo = makeRepo(id: repoId, projects: [])
        repo.externalConvos = [ExternalConvo(
            id: convoId, sessionId: "sid-1",
            cwd: URL(fileURLWithPath: "/r"), firstSeenAt: Date()
        )]
        var state = stateWith(repos: [repo])
        let path = ExternalConvoPath(repo: repoId, convo: convoId)

        let (events, _) = reduce(state, .dismissExternalConvo(at: path))
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos[0].externalConvos.isEmpty)
    }

    func test_adoptExternalConvo_createsTaskAndRemovesConvo() {
        let repoId = UUID()
        let projectId = UUID()
        let convoId = UUID()
        var repo = makeRepo(id: repoId, projects: [
            makeProject(id: projectId, tasks: [])
        ])
        repo.externalConvos = [ExternalConvo(
            id: convoId,
            sessionId: "live-sid",
            cwd: URL(fileURLWithPath: "/r/feat"),
            firstSeenAt: Date()
        )]
        var state = stateWith(repos: [repo])

        let (events, effects) = reduce(state, .adoptExternalConvo(
            at: ExternalConvoPath(repo: repoId, convo: convoId),
            into: ProjectPath(repo: repoId, project: projectId),
            name: "claude (adopted)"
        ))

        XCTAssertEqual(events.count, 3)
        guard case let .taskCreated(at, task) = events[0],
              case .externalConvoDismissed = events[1],
              case .taskSelectionChanged = events[2] else {
            return XCTFail("unexpected event sequence: \(events)")
        }
        XCTAssertEqual(at.repo, repoId)
        XCTAssertEqual(at.project, projectId)
        if case let .claude(sid) = task.kind {
            XCTAssertEqual(sid, "live-sid")
        } else {
            XCTFail("expected claude kind")
        }
        XCTAssertTrue(effects.contains(where: { effect in
            if case .spawn = effect { return true }
            return false
        }))

        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].projects[0].tasks.count, 1)
        XCTAssertTrue(state.repos[0].externalConvos.isEmpty)
    }

    // MARK: - selection

    func test_selectTask_unknownPath_isNoop() {
        let state = AppState.empty
        let bogus = TaskPath(repo: UUID(), project: UUID(), task: UUID())
        let (events, _) = reduce(state, .selectTask(at: bogus))
        XCTAssertTrue(events.isEmpty)
    }

    func test_selectTask_validPath_emits() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        let path = TaskPath(repo: repoId, project: projectId, task: taskId)
        let state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])

        let (events, _) = reduce(state, .selectTask(at: path))
        XCTAssertEqual(events, [.taskSelectionChanged(path)])
    }

    // MARK: - restart / claude uniqueness

    func test_restartTask_emitsSpawnedAndSpawn_noTerminate() {
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [
                    makeTask(id: taskId, runtime: .exited(at: Date(), code: 1))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, project: projectId, task: taskId)

        let (events, effects) = reduce(state, .restartTask(at: path))
        guard case .taskSpawned = events.first else {
            return XCTFail("expected taskSpawned event")
        }
        XCTAssertFalse(effects.contains(where: { effect in
            if case .terminate = effect { return true }
            return false
        }))
        XCTAssertTrue(effects.contains(where: { effect in
            if case .spawn = effect { return true }
            return false
        }))
    }

    func test_linkClaudeSession_otherTaskOwnsSid_isNoop() {
        let repoId = UUID()
        let projectId = UUID()
        let ownerId = UUID()
        let targetId = UUID()
        let owner = makeTask(
            id: ownerId, kind: .claude(sessionId: "shared"),
            runtime: .running(spawnedAt: Date())
        )
        let target = makeTask(
            id: targetId, kind: .claude(sessionId: nil),
            runtime: .running(spawnedAt: Date())
        )
        let state = stateWith(repos: [
            makeRepo(id: repoId, projects: [
                makeProject(id: projectId, tasks: [owner, target])
            ])
        ])
        let path = TaskPath(repo: repoId, project: projectId, task: targetId)

        let (events, _) = reduce(state, .linkClaudeSession(
            at: path, sessionId: "shared"
        ))
        XCTAssertTrue(events.isEmpty)
    }
}

// MARK: - Helpers

private func stateWith(repos: [Repo]) -> AppState {
    AppState(
        schemaVersion: 2,
        repos: repos,
        settings: Settings(
            scrollbackCapBytes: 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13,
            claudeInvocation: "claude"
        ),
        selectedTaskPath: nil
    )
}

private func stateWith(repos: [Repo], selectedTaskPath: TaskPath?) -> AppState {
    AppState(
        schemaVersion: 2,
        repos: repos,
        settings: Settings(
            scrollbackCapBytes: 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13,
            claudeInvocation: "claude"
        ),
        selectedTaskPath: selectedTaskPath
    )
}

private func makeRepo(id: UUID, projects: [Project]) -> Repo {
    Repo(
        id: id,
        name: "atlas",
        color: "#ff5500",
        enabled: true,
        rootDir: URL(fileURLWithPath: "/wt/main"),
        projects: projects,
        externalConvos: [],
        createdAt: Date(),
        claudeInvocation: nil
    )
}

private func makeProject(id: UUID, tasks: [Task]) -> Project {
    Project(
        id: id,
        name: "main",
        workspace: Workspace(
            path: URL(fileURLWithPath: "/wt/main"),
            kind: .folder,
            missing: false
        ),
        tasks: tasks,
        archivedAt: nil,
        createdAt: Date()
    )
}

private func makeTask(id: UUID, runtime: TaskRuntime) -> Task {
    makeTask(id: id, kind: .shell, runtime: runtime)
}

private func makeTask(id: UUID, kind: TaskKind, runtime: TaskRuntime) -> Task {
    Task(
        id: id,
        name: "shell",
        kind: kind,
        enabled: true,
        spec: ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/wt/main"),
            initialInput: nil
        ),
        runtime: runtime,
        unread: 0,
        createdAt: Date(),
        renamed: false
    )
}

private func terminatedTaskIds(in effects: [Effect]) -> [UUID] {
    effects.compactMap { effect -> UUID? in
        if case let .terminate(path) = effect { return path.task }
        return nil
    }
}
