import XCTest
@testable import ManiCore

final class ReducerTests: XCTestCase {

    // MARK: - createRepo

    func test_createProject_emitsEventAndPersistEffect() {
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
        XCTAssertEqual(repo.worktrees.count, 1)
        XCTAssertEqual(repo.worktrees[0].path.path, "/Users/me/atlas")
    }

    func test_apply_projectCreated_appendsToState() {
        var state = AppState.empty
        let repo = makeRepo(id: UUID(), worktrees: [])

        apply(&state, .repoCreated(repo))

        XCTAssertEqual(state.repos.count, 1)
        XCTAssertEqual(state.repos[0].id, repo.id)
    }

    // MARK: - renameRepo

    func test_renameProject_known_emitsEventAndApplies() {
        let id = UUID()
        var state = stateWith(repos: [makeRepo(id: id, worktrees: [])])

        let (events, effects) = reduce(state, .renameRepo(id: id, name: "renamed"))

        XCTAssertEqual(events, [.repoRenamed(id: id, name: "renamed")])
        XCTAssertEqual(effects.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].name, "renamed")
    }

    func test_renameProject_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .renameRepo(id: UUID(), name: "x"))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - setProjectEnabled

    func test_setProjectEnabled_disabled_cascadesTerminations() {
        let repoId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: UUID(), tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])

        let (events, effects) = reduce(state, .setProjectEnabled(id: repoId, enabled: false))

        XCTAssertEqual(Set(terminatedTaskIds(in: effects)), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.repos[0].enabled)
    }

    func test_setProjectEnabled_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .setProjectEnabled(id: UUID(), enabled: false))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - deleteRepo

    func test_deleteProject_cascadesTerminationsAndRemovesRepo() {
        let repoId = UUID()
        let t1 = UUID()
        let t2 = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: UUID(), tasks: [
                    makeTask(id: t1, runtime: .running(spawnedAt: Date())),
                    makeTask(id: t2, runtime: .exited(at: Date(), code: 0)),
                ])
            ])
        ])

        let (events, effects) = reduce(state, .deleteRepo(id: repoId))

        XCTAssertEqual(events, [.repoDeleted(id: repoId)])
        // terminate fires for all tasks; host resolves whether anything's
        // actually alive. Reducer doesn't filter on runtime.
        XCTAssertEqual(Set(terminatedTaskIds(in: effects)), [t1, t2])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos.isEmpty)
    }

    func test_deleteProject_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .deleteRepo(id: UUID()))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - createWorktree

    func test_createWorktree_folder_emitsEventOnly() {
        let repoId = UUID()
        var state = stateWith(repos: [makeRepo(id: repoId, worktrees: [])])

        let (events, effects) = reduce(state, .createWorktree(
            repoId: repoId,
            kind: .folder,
            path: URL(fileURLWithPath: "/wt/main")
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(effects.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].worktrees.count, 1)
        XCTAssertEqual(state.repos[0].worktrees[0].path.lastPathComponent, "main")
        XCTAssertEqual(state.repos[0].worktrees[0].kind, .folder)
        XCTAssertFalse(state.repos[0].worktrees[0].missing)
    }

    func test_createWorktree_git_usesProjectRootDirAsRepoRoot() {
        let repoId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [])
        ])

        let (_, effects) = reduce(state, .createWorktree(
            repoId: repoId,
            kind: .git(branch: "feat/auth", baseRef: "main"),
            path: URL(fileURLWithPath: "/wt/feat")
        ))

        let createEffect = effects.first { effect in
            if case .createGitWorktree = effect { return true }
            return false
        }
        guard case let .createGitWorktree(pid, repoRoot, branch, path, baseRef) = createEffect else {
            return XCTFail("expected createGitWorktree effect")
        }
        XCTAssertEqual(pid, repoId)
        XCTAssertEqual(repoRoot, URL(fileURLWithPath: "/wt/main"))
        XCTAssertEqual(branch, "feat/auth")
        XCTAssertEqual(path, URL(fileURLWithPath: "/wt/feat"))
        XCTAssertEqual(baseRef, "main")
    }

    func test_createWorktree_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .createWorktree(
            repoId: UUID(),
            kind: .folder,
            path: URL(fileURLWithPath: "/wt/main")
        ))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - setWorktreeEnabled

    func test_setWorktreeEnabled_disabled_cascadesTerminations() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = WorktreePath(repo: repoId, worktree: worktreeId)

        let (events, effects) = reduce(state, .setWorktreeEnabled(at: path, enabled: false))

        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.repos[0].worktrees[0].enabled)
    }

    func test_setWorktreeEnabled_unknownPath_isNoop() {
        let state = AppState.empty
        let path = WorktreePath(repo: UUID(), worktree: UUID())
        let (events, effects) = reduce(state, .setWorktreeEnabled(at: path, enabled: false))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - markWorktreeMissing

    func test_markWorktreeMissing_setsMissingFlag() {
        let repoId = UUID()
        let worktreeId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [])
            ])
        ])
        let path = WorktreePath(repo: repoId, worktree: worktreeId)

        let (events, _) = reduce(state, .markWorktreeMissing(at: path))

        XCTAssertEqual(events, [.worktreeMarkedMissing(at: path)])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos[0].worktrees[0].missing)
    }

    // MARK: - deleteWorktree

    func test_deleteWorktree_cascadesTerminationsAndRemoves() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = WorktreePath(repo: repoId, worktree: worktreeId)

        let (events, effects) = reduce(state, .deleteWorktree(at: path))

        XCTAssertEqual(events, [.worktreeDeleted(at: path)])
        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos[0].worktrees.isEmpty)
    }

    // MARK: - createTask

    func test_createTask_emitsTaskCreatedSpawnAndAutoSelection() {
        let repoId = UUID()
        let worktreeId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [])
            ])
        ])
        let path = WorktreePath(repo: repoId, worktree: worktreeId)
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
        XCTAssertEqual(task.name, "shell")
        XCTAssertTrue(task.enabled)
        if case .running = task.runtime { /* expected */ } else {
            XCTFail("expected runtime to be .running on fresh task, got \(task.runtime)")
        }

        // Second event is the auto-selection — that's why the user
        // sees the new task immediately on creation.
        let expectedPath = TaskPath(repo: repoId, worktree: worktreeId, task: task.id)
        XCTAssertEqual(events.count, 2)
        if case let .taskSelectionChanged(p) = events[1] {
            XCTAssertEqual(p, expectedPath)
        } else {
            XCTFail("expected taskSelectionChanged as 2nd event, got \(events[1])")
        }

        // Exactly one spawn for the new task UUID.
        let spawnIds = effects.compactMap { effect -> UUID? in
            if case let .spawn(p, _) = effect { return p.task }
            return nil
        }
        XCTAssertEqual(spawnIds, [task.id])

        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].worktrees[0].tasks.count, 1)
        XCTAssertEqual(state.repos[0].worktrees[0].tasks[0].id, task.id)
        XCTAssertEqual(state.selectedTaskPath, expectedPath)
    }

    func test_createTask_unknownWorktree_isNoop() {
        let state = AppState.empty
        let path = WorktreePath(repo: UUID(), worktree: UUID())
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/p"),
            initialInput: nil
        )
        let (events, effects) = reduce(state, .createTask(
            at: path, name: "x", kind: .shell, spec: spec, autoSelect: true
        ))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_createTask_autoSelectFalse_doesNotChangeSelection() {
        let repoId = UUID()
        let worktreeId = UUID()
        let priorSelected = TaskPath(
            repo: repoId, worktree: worktreeId, task: UUID()
        )
        let state = stateWith(
            repos: [
                makeRepo(id: repoId, worktrees: [
                    makeWorktree(id: worktreeId, tasks: [
                        makeTask(id: priorSelected.task, runtime: .running(spawnedAt: Date()))
                    ])
                ])
            ],
            selectedTaskPath: priorSelected
        )
        let path = WorktreePath(repo: repoId, worktree: worktreeId)
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/p"),
            initialInput: nil
        )

        let (events, _) = reduce(state, .createTask(
            at: path, name: "diff", kind: .diff, spec: spec, autoSelect: false
        ))

        XCTAssertEqual(events.count, 1, "no selection event when autoSelect=false")
        guard case .taskCreated = events.first else {
            return XCTFail("expected only taskCreated")
        }
    }

    // MARK: - setTaskEnabled

    func test_setTaskEnabled_disabled_emitsTerminate() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .setTaskEnabled(at: path, enabled: false))

        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.repos[0].worktrees[0].tasks[0].enabled)
    }

    // MARK: - linkClaudeSession

    func test_linkClaudeSession_claudeTask_appliesSessionId() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, kind: .claude(sessionId: nil), runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, _) = reduce(state, .linkClaudeSession(at: path, sessionId: "abc123"))

        XCTAssertEqual(events, [.claudeSessionLinked(at: path, sessionId: "abc123")])
        for e in events { apply(&state, e) }
        guard case let .claude(sessionId) = state.repos[0].worktrees[0].tasks[0].kind else {
            return XCTFail("expected claude kind")
        }
        XCTAssertEqual(sessionId, "abc123")
    }

    func test_linkClaudeSession_shellTask_isNoop() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .neverStarted)
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .linkClaudeSession(at: path, sessionId: "x"))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - completeTask

    func test_completeTask_setsRuntimeToCompletedAndTerminates() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .completeTask(at: path))

        guard case let .taskCompleted(receivedPath, completedAt) = events.first else {
            return XCTFail("expected taskCompleted event")
        }
        XCTAssertEqual(receivedPath, path)
        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])

        for e in events { apply(&state, e) }
        if case let .completed(when) = state.repos[0].worktrees[0].tasks[0].runtime {
            XCTAssertEqual(when, completedAt)
        } else {
            XCTFail("expected runtime = .completed")
        }
    }

    // MARK: - taskSpawned / taskExited

    func test_taskSpawned_setsRunningRuntime() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .exited(at: Date(), code: 1))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        let now = Date()

        let (events, _) = reduce(state, .taskSpawned(at: path, when: now))
        for e in events { apply(&state, e) }

        if case let .running(when) = state.repos[0].worktrees[0].tasks[0].runtime {
            XCTAssertEqual(when, now)
        } else {
            XCTFail("expected runtime = .running")
        }
    }

    func test_taskExited_flipsRunningToExited() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        let when = Date()

        let (events, _) = reduce(state, .taskExited(at: path, when: when, code: 42))
        for e in events { apply(&state, e) }

        if case let .exited(receivedAt, code) = state.repos[0].worktrees[0].tasks[0].runtime {
            XCTAssertEqual(receivedAt, when)
            XCTAssertEqual(code, 42)
        } else {
            XCTFail("expected runtime = .exited")
        }
    }

    func test_taskExited_doesNotDowngradeCompletedRuntime() {
        // .completed reflects the user's intent — a late .exited from the
        // agent must not stomp on it. Tested because the order is racy
        // in practice: completeTask fires a terminate effect which yields
        // an exit code shortly after.
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let completedAt = Date()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .completed(at: completedAt))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, _) = reduce(state, .taskExited(at: path, when: Date(), code: -1))
        for e in events { apply(&state, e) }

        if case let .completed(when) = state.repos[0].worktrees[0].tasks[0].runtime {
            XCTAssertEqual(when, completedAt, "completion timestamp must be preserved")
        } else {
            XCTFail("completed runtime must not be downgraded by taskExited")
        }
    }

    // MARK: - renameTask

    func test_renameTask_known_emitsEventAndApplies() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .renameTask(at: path, name: "  api server  "))

        XCTAssertEqual(events, [.taskRenamed(at: path, name: "api server")])
        XCTAssertEqual(effects.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.repos[0].worktrees[0].tasks[0].name, "api server")
        XCTAssertTrue(state.repos[0].worktrees[0].tasks[0].renamed)
    }

    func test_renameTask_emptyAfterTrim_isNoop() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .neverStarted)
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .renameTask(at: path, name: "   "))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_renameTask_unknownPath_isNoop() {
        let state = AppState.empty
        let path = TaskPath(repo: UUID(), worktree: UUID(), task: UUID())
        let (events, effects) = reduce(state, .renameTask(at: path, name: "x"))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - deleteTask

    func test_deleteTask_unselected_emitsTaskDeletedAndTerminate() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .deleteTask(at: path))

        XCTAssertEqual(events, [.taskDeleted(at: path)])
        XCTAssertEqual(terminatedTaskIds(in: effects), [taskId])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.repos[0].worktrees[0].tasks.isEmpty)
    }

    func test_deleteTask_currentlySelected_alsoEmitsTaskSelectionChangedNil() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        var state = stateWith(
            repos: [
                makeRepo(id: repoId, worktrees: [
                    makeWorktree(id: worktreeId, tasks: [
                        makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                    ])
                ])
            ],
            selectedTaskPath: path
        )

        let (events, _) = reduce(state, .deleteTask(at: path))

        XCTAssertEqual(events, [
            .taskDeleted(at: path),
            .taskSelectionChanged(nil),
        ])
        for e in events { apply(&state, e) }
        XCTAssertNil(state.selectedTaskPath)
    }

    func test_deleteTask_unknown_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(
            state,
            .deleteTask(at: TaskPath(repo: UUID(), worktree: UUID(), task: UUID()))
        )
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - restartTask

    func test_restartTask_emitsSpawnedAndSpawn_noStandaloneTerminate() {
        // Restart emits ONLY .spawn (no separate .terminate) because
        // EffectRunner.spawn is responsible for terminating any stale
        // agent before launching the replacement — emitting both as
        // independent effects races and produced the "code -1 on
        // Restart" bug.
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .exited(at: Date(), code: 1))
                ])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .restartTask(at: path))

        guard case .taskSpawned = events.first else {
            return XCTFail("expected taskSpawned event")
        }
        XCTAssertFalse(effects.contains(where: { effect in
            if case .terminate = effect { return true }
            return false
        }), "restartTask must NOT emit a standalone .terminate effect")
        XCTAssertTrue(effects.contains(where: { effect in
            if case let .spawn(p, _) = effect, p.task == taskId { return true }
            return false
        }))

        for e in events { apply(&state, e) }
        if case .running = state.repos[0].worktrees[0].tasks[0].runtime { /* ok */ } else {
            XCTFail("expected runtime to flip back to .running after restartTask")
        }
    }

    func test_restartTask_externalClaude_isNoop() {
        // External claudes (discovered via FSEvents) have no agent we own;
        // Restart on them is a UX-level no-op, not a spawn.
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        var externalTask = makeTask(
            id: taskId, kind: .claude(sessionId: "sid"), runtime: .neverStarted
        )
        externalTask.spec = ProcessSpec(
            command: "(external claude)", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/somewhere"), initialInput: nil
        )
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [externalTask])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .restartTask(at: path))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - dedupe

    func test_duplicateClaudeTasksToRemove_prefersLiveRuntime() {
        let dupSid = "shared-sid"
        let repoId = UUID()
        let worktreeId = UUID()
        let live = makeTask(
            id: UUID(), kind: .claude(sessionId: dupSid),
            runtime: .running(spawnedAt: Date())
        )
        let dead = makeTask(
            id: UUID(), kind: .claude(sessionId: dupSid),
            runtime: .exited(at: Date(), code: 0)
        )
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [dead, live])
            ])
        ])

        let toRemove = state.duplicateClaudeTasksToRemove()

        XCTAssertEqual(toRemove.count, 1)
        XCTAssertEqual(toRemove[0].task, dead.id)
    }

    func test_duplicateClaudeTasksToRemove_tieBreaksOnUnreadThenCreatedAt() {
        let sid = "s"
        var high = makeTask(
            id: UUID(), kind: .claude(sessionId: sid), runtime: .exited(at: Date(), code: 0)
        )
        high.unread = 5
        let low = makeTask(
            id: UUID(), kind: .claude(sessionId: sid), runtime: .exited(at: Date(), code: 0)
        )
        let state = stateWith(repos: [
            makeRepo(id: UUID(), worktrees: [
                makeWorktree(id: UUID(), tasks: [low, high])
            ])
        ])

        let toRemove = state.duplicateClaudeTasksToRemove()

        XCTAssertEqual(toRemove.count, 1)
        XCTAssertEqual(toRemove[0].task, low.id)
    }

    func test_duplicateClaudeTasksToRemove_renamedBeatsLiveRuntime() {
        let sid = "shared"
        let renamedId = UUID()
        let liveId = UUID()
        var renamedTask = makeTask(
            id: renamedId, kind: .claude(sessionId: sid), runtime: .exited(at: Date(), code: 0)
        )
        renamedTask.name = "my custom name"
        renamedTask.renamed = true
        let liveTask = makeTask(
            id: liveId, kind: .claude(sessionId: sid), runtime: .running(spawnedAt: Date())
        )
        let state = stateWith(repos: [
            makeRepo(id: UUID(), worktrees: [
                makeWorktree(id: UUID(), tasks: [liveTask, renamedTask])
            ])
        ])

        let toRemove = state.duplicateClaudeTasksToRemove()

        XCTAssertEqual(toRemove.count, 1)
        XCTAssertEqual(toRemove[0].task, liveId,
            "expected the renamed Task to survive, not the live unnamed one")
    }

    func test_duplicateClaudeTasksToRemove_ignoresUnlinkedAndUniqueSids() {
        let aId = UUID()
        let bId = UUID()
        let unlinkedId = UUID()
        let state = stateWith(repos: [
            makeRepo(id: UUID(), worktrees: [
                makeWorktree(id: UUID(), tasks: [
                    makeTask(id: aId, kind: .claude(sessionId: "A"), runtime: .neverStarted),
                    makeTask(id: bId, kind: .claude(sessionId: "B"), runtime: .neverStarted),
                    makeTask(id: unlinkedId, kind: .claude(sessionId: nil), runtime: .neverStarted),
                ])
            ])
        ])

        XCTAssertTrue(state.duplicateClaudeTasksToRemove().isEmpty)
    }

    // MARK: - selectTask

    func test_selectTask_validPath_emitsAndApplies() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        var state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [
                    makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                ])
            ])
        ])

        let (events, _) = reduce(state, .selectTask(at: path))

        XCTAssertEqual(events, [.taskSelectionChanged(path)])
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.selectedTaskPath, path)
    }

    func test_selectTask_unknownPath_isNoop() {
        // Guarding against dangling selections at the reducer layer
        // means the UI never has to defend against them.
        let state = AppState.empty
        let bogus = TaskPath(repo: UUID(), worktree: UUID(), task: UUID())
        let (events, effects) = reduce(state, .selectTask(at: bogus))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_selectTask_alreadySelected_isNoop() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        let state = stateWith(
            repos: [
                makeRepo(id: repoId, worktrees: [
                    makeWorktree(id: worktreeId, tasks: [
                        makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                    ])
                ])
            ],
            selectedTaskPath: path
        )

        let (events, _) = reduce(state, .selectTask(at: path))
        XCTAssertTrue(events.isEmpty)
    }

    func test_selectTask_nil_deselects() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        var state = stateWith(
            repos: [
                makeRepo(id: repoId, worktrees: [
                    makeWorktree(id: worktreeId, tasks: [
                        makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                    ])
                ])
            ],
            selectedTaskPath: path
        )

        let (events, _) = reduce(state, .selectTask(at: nil))
        XCTAssertEqual(events, [.taskSelectionChanged(nil)])
        for e in events { apply(&state, e) }
        XCTAssertNil(state.selectedTaskPath)
    }

    func test_deleteWorktree_deselectsIfSelectionWasInside() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let wtPath = WorktreePath(repo: repoId, worktree: worktreeId)
        let selected = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        var state = stateWith(
            repos: [
                makeRepo(id: repoId, worktrees: [
                    makeWorktree(id: worktreeId, tasks: [
                        makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                    ])
                ])
            ],
            selectedTaskPath: selected
        )

        let (events, _) = reduce(state, .deleteWorktree(at: wtPath))

        XCTAssertTrue(events.contains(.taskSelectionChanged(nil)))
        for e in events { apply(&state, e) }
        XCTAssertNil(state.selectedTaskPath)
    }

    func test_deleteProject_deselectsIfSelectionWasInside() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let selected = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)
        var state = stateWith(
            repos: [
                makeRepo(id: repoId, worktrees: [
                    makeWorktree(id: worktreeId, tasks: [
                        makeTask(id: taskId, runtime: .running(spawnedAt: Date()))
                    ])
                ])
            ],
            selectedTaskPath: selected
        )

        let (events, _) = reduce(state, .deleteRepo(id: repoId))

        XCTAssertTrue(events.contains(.taskSelectionChanged(nil)))
        for e in events { apply(&state, e) }
        XCTAssertNil(state.selectedTaskPath)
    }

    // MARK: - claude session-id uniqueness

    func test_linkClaudeSession_otherTaskOwnsTheSid_isNoop() {
        let repoId = UUID()
        let worktreeId = UUID()
        let ownerId = UUID()
        let targetId = UUID()
        let owner = makeTask(
            id: ownerId, kind: .claude(sessionId: "shared"), runtime: .running(spawnedAt: Date())
        )
        let target = makeTask(
            id: targetId, kind: .claude(sessionId: nil), runtime: .running(spawnedAt: Date())
        )
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [owner, target])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: targetId)

        let (events, effects) = reduce(state, .linkClaudeSession(at: path, sessionId: "shared"))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_linkClaudeSession_sameTaskReLinkingItsOwnSid_isAllowed() {
        let repoId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let task = makeTask(
            id: taskId, kind: .claude(sessionId: "live"), runtime: .running(spawnedAt: Date())
        )
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: worktreeId, tasks: [task])
            ])
        ])
        let path = TaskPath(repo: repoId, worktree: worktreeId, task: taskId)

        let (events, effects) = reduce(state, .linkClaudeSession(at: path, sessionId: "live"))

        XCTAssertEqual(events, [.claudeSessionLinked(at: path, sessionId: "live")])
        XCTAssertEqual(effects.count, 1)
    }

    func test_discoverClaudeSession_sidTrackedInOtherWorktree_isNoop() {
        let repoId = UUID()
        let wtA = UUID()
        let wtB = UUID()
        let existing = makeTask(
            id: UUID(), kind: .claude(sessionId: "live"), runtime: .running(spawnedAt: Date())
        )
        let state = stateWith(repos: [
            makeRepo(id: repoId, worktrees: [
                makeWorktree(id: wtA, tasks: [existing]),
                makeWorktree(id: wtB, tasks: [])
            ])
        ])

        let (events, effects) = reduce(state, .discoverClaudeSession(
            at: WorktreePath(repo: repoId, worktree: wtB),
            sessionId: "live",
            cwd: URL(fileURLWithPath: "/somewhere")
        ))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
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

private func makeRepo(id: UUID, worktrees: [Worktree]) -> Repo {
    Repo(
        id: id,
        name: "atlas",
        color: "#ff5500",
        enabled: true,
        rootDir: URL(fileURLWithPath: "/wt/main"),
        worktrees: worktrees,
        createdAt: Date(),
        claudeInvocation: nil
    )
}

private func makeWorktree(id: UUID, tasks: [Task]) -> Worktree {
    Worktree(
        id: id,
        path: URL(fileURLWithPath: "/wt/main"),
        kind: .folder,
        enabled: true,
        missing: false,
        tasks: tasks,
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
