import XCTest
@testable import ManiCore

final class ReducerTests: XCTestCase {

    // MARK: - createProject

    func test_createProject_emitsEventAndPersistEffect() {
        let state = AppState.empty
        let action = Action.createProject(
            name: "atlas",
            color: "#ff5500",
            rootDir: URL(fileURLWithPath: "/Users/me/pr/atlas")
        )

        let (events, effects) = reduce(state, action)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(effects.count, 1)
        guard case let .projectCreated(project) = events[0] else {
            return XCTFail("expected projectCreated, got \(events[0])")
        }
        XCTAssertEqual(project.name, "atlas")
        XCTAssertEqual(project.color, "#ff5500")
        XCTAssertTrue(project.enabled)
        XCTAssertTrue(project.worktrees.isEmpty)
    }

    func test_apply_projectCreated_appendsToState() {
        var state = AppState.empty
        let project = makeProject(id: UUID(), worktrees: [])

        apply(&state, .projectCreated(project))

        XCTAssertEqual(state.projects.count, 1)
        XCTAssertEqual(state.projects[0].id, project.id)
    }

    // MARK: - renameProject

    func test_renameProject_known_emitsEventAndApplies() {
        let id = UUID()
        var state = stateWith(projects: [makeProject(id: id, worktrees: [])])

        let (events, effects) = reduce(state, .renameProject(id: id, name: "renamed"))

        XCTAssertEqual(events, [.projectRenamed(id: id, name: "renamed")])
        XCTAssertEqual(effects.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.projects[0].name, "renamed")
    }

    func test_renameProject_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .renameProject(id: UUID(), name: "x"))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - setProjectEnabled

    func test_setProjectEnabled_disabled_cascadesTerminations() {
        let projectId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: UUID(), jobs: [
                    makeJob(id: UUID(), primaryPid: 12345, auxPids: [12346])
                ])
            ])
        ])

        let (events, effects) = reduce(state, .setProjectEnabled(id: projectId, enabled: false))

        XCTAssertEqual(Set(terminatedPids(in: effects)), [12345, 12346])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.projects[0].enabled)
    }

    func test_setProjectEnabled_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .setProjectEnabled(id: UUID(), enabled: false))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - deleteProject

    func test_deleteProject_cascadesTerminationsAndRemovesProject() {
        let projectId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: UUID(), jobs: [
                    makeJob(id: UUID(), primaryPid: 7, auxPids: [8, 9])
                ])
            ])
        ])

        let (events, effects) = reduce(state, .deleteProject(id: projectId))

        XCTAssertEqual(events, [.projectDeleted(id: projectId)])
        XCTAssertEqual(Set(terminatedPids(in: effects)), [7, 8, 9])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.projects.isEmpty)
    }

    func test_deleteProject_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .deleteProject(id: UUID()))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - createWorktree

    func test_createWorktree_folder_emitsEventOnly() {
        let projectId = UUID()
        var state = stateWith(projects: [makeProject(id: projectId, worktrees: [])])

        let (events, effects) = reduce(state, .createWorktree(
            projectId: projectId,
            name: "main",
            kind: .folder,
            path: URL(fileURLWithPath: "/wt/main")
        ))

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(effects.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.projects[0].worktrees.count, 1)
        XCTAssertEqual(state.projects[0].worktrees[0].name, "main")
        XCTAssertEqual(state.projects[0].worktrees[0].kind, .folder)
        XCTAssertFalse(state.projects[0].worktrees[0].missing)
    }

    func test_createWorktree_git_alsoEmitsCreateGitWorktreeEffect() {
        let projectId = UUID()
        let state = stateWith(projects: [makeProject(id: projectId, worktrees: [])])

        let (_, effects) = reduce(state, .createWorktree(
            projectId: projectId,
            name: "feat",
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
        XCTAssertEqual(pid, projectId)
        XCTAssertEqual(repoRoot, URL(fileURLWithPath: "/p/atlas"))
        XCTAssertEqual(branch, "feat/auth")
        XCTAssertEqual(path, URL(fileURLWithPath: "/wt/feat"))
        XCTAssertEqual(baseRef, "main")
    }

    func test_createWorktree_unknownProject_isNoop() {
        let state = AppState.empty
        let (events, effects) = reduce(state, .createWorktree(
            projectId: UUID(),
            name: "main",
            kind: .folder,
            path: URL(fileURLWithPath: "/wt/main")
        ))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - setWorktreeEnabled

    func test_setWorktreeEnabled_disabled_cascadesTerminations() {
        let projectId = UUID()
        let worktreeId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: UUID(), primaryPid: 100, auxPids: [101])
                ])
            ])
        ])
        let path = WorktreePath(project: projectId, worktree: worktreeId)

        let (events, effects) = reduce(state, .setWorktreeEnabled(at: path, enabled: false))

        XCTAssertEqual(Set(terminatedPids(in: effects)), [100, 101])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.projects[0].worktrees[0].enabled)
    }

    func test_setWorktreeEnabled_unknownPath_isNoop() {
        let state = AppState.empty
        let path = WorktreePath(project: UUID(), worktree: UUID())
        let (events, effects) = reduce(state, .setWorktreeEnabled(at: path, enabled: false))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - markWorktreeMissing

    func test_markWorktreeMissing_setsMissingFlag() {
        let projectId = UUID()
        let worktreeId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [])
            ])
        ])
        let path = WorktreePath(project: projectId, worktree: worktreeId)

        let (events, _) = reduce(state, .markWorktreeMissing(at: path))

        XCTAssertEqual(events, [.worktreeMarkedMissing(at: path)])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.projects[0].worktrees[0].missing)
    }

    // MARK: - deleteWorktree

    func test_deleteWorktree_cascadesTerminationsAndRemoves() {
        let projectId = UUID()
        let worktreeId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: UUID(), primaryPid: 200, auxPids: [])
                ])
            ])
        ])
        let path = WorktreePath(project: projectId, worktree: worktreeId)

        let (events, effects) = reduce(state, .deleteWorktree(at: path))

        XCTAssertEqual(events, [.worktreeDeleted(at: path)])
        XCTAssertEqual(terminatedPids(in: effects), [200])
        for e in events { apply(&state, e) }
        XCTAssertTrue(state.projects[0].worktrees.isEmpty)
    }

    // MARK: - createJob

    func test_createJob_emitsSpawnForPrimaryAndAuxiliary() {
        let projectId = UUID()
        let worktreeId = UUID()
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [])
            ])
        ])
        let path = WorktreePath(project: projectId, worktree: worktreeId)
        let primary = ProcessSpec(
            command: "/bin/zsh",
            args: [],
            env: [:],
            cwd: URL(fileURLWithPath: "/wt"),
            pid: nil,
            initialInput: nil, restartPolicy: .never)
        let aux = ProcessSpec(
            command: "/usr/bin/dev",
            args: ["server"],
            env: [:],
            cwd: URL(fileURLWithPath: "/wt"),
            pid: nil,
            initialInput: nil, restartPolicy: .never)

        let (events, effects) = reduce(state, .createJob(
            at: path, name: "shell", kind: .shell,
            primary: primary, auxiliary: [aux]
        ))

        guard case let .jobCreated(receivedPath, job) = events.first else {
            return XCTFail("expected jobCreated event")
        }
        XCTAssertEqual(receivedPath, path)
        XCTAssertEqual(job.name, "shell")
        XCTAssertEqual(job.status, .running)
        XCTAssertTrue(job.enabled)

        let spawnIndices = effects.compactMap { effect -> Int? in
            if case let .spawn(_, index, _) = effect { return index }
            return nil
        }
        XCTAssertEqual(spawnIndices, [0, 1])
    }

    func test_createJob_unknownWorktree_isNoop() {
        let state = AppState.empty
        let path = WorktreePath(project: UUID(), worktree: UUID())
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/p"), pid: nil,
            initialInput: nil, restartPolicy: .never)
        let (events, effects) = reduce(state, .createJob(
            at: path, name: "x", kind: .shell, primary: spec, auxiliary: []
        ))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - setJobEnabled

    func test_setJobEnabled_disabled_cascadesTerminations() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: 555, auxPids: [556])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, effects) = reduce(state, .setJobEnabled(at: path, enabled: false))

        XCTAssertEqual(Set(terminatedPids(in: effects)), [555, 556])
        for e in events { apply(&state, e) }
        XCTAssertFalse(state.projects[0].worktrees[0].jobs[0].enabled)
    }

    // MARK: - linkClaudeSession

    func test_linkClaudeSession_claudeJob_appliesSessionId() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, kind: .claude(sessionId: nil), primaryPid: nil, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, _) = reduce(state, .linkClaudeSession(at: path, sessionId: "abc123"))

        XCTAssertEqual(events, [.claudeSessionLinked(at: path, sessionId: "abc123")])
        for e in events { apply(&state, e) }
        guard case let .claude(sessionId) = state.projects[0].worktrees[0].jobs[0].kind else {
            return XCTFail("expected claude kind")
        }
        XCTAssertEqual(sessionId, "abc123")
    }

    func test_linkClaudeSession_shellJob_isNoop() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: nil, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, effects) = reduce(state, .linkClaudeSession(at: path, sessionId: "x"))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - completeJob

    func test_completeJob_setsStatusAndCompletedAtAndCascades() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: 999, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, effects) = reduce(state, .completeJob(at: path))

        guard case let .jobCompleted(receivedPath, completedAt) = events.first else {
            return XCTFail("expected jobCompleted event")
        }
        XCTAssertEqual(receivedPath, path)
        XCTAssertEqual(terminatedPids(in: effects), [999])

        for e in events { apply(&state, e) }
        XCTAssertEqual(state.projects[0].worktrees[0].jobs[0].status, .completed)
        XCTAssertEqual(state.projects[0].worktrees[0].jobs[0].completedAt, completedAt)
    }

    // MARK: - processStarted / processExited

    func test_processStarted_setsPidOnPrimary() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: nil, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, _) = reduce(state, .processStarted(at: path, index: 0, pid: 4242))
        for e in events { apply(&state, e) }

        XCTAssertEqual(state.projects[0].worktrees[0].jobs[0].primary.pid, 4242)
    }

    func test_processStarted_setsPidOnAuxiliary() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: nil, auxPids: [nil])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, _) = reduce(state, .processStarted(at: path, index: 1, pid: 5151))
        for e in events { apply(&state, e) }

        XCTAssertEqual(state.projects[0].worktrees[0].jobs[0].auxiliary[0].pid, 5151)
    }

    // MARK: - renameJob

    func test_renameJob_known_emitsEventAndApplies() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: 1, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, effects) = reduce(state, .renameJob(at: path, name: "  api server  "))

        // Trimmed, persisted, applied.
        XCTAssertEqual(events, [.jobRenamed(at: path, name: "api server")])
        XCTAssertEqual(effects.count, 1)
        for e in events { apply(&state, e) }
        XCTAssertEqual(state.projects[0].worktrees[0].jobs[0].name, "api server")
    }

    func test_renameJob_emptyAfterTrim_isNoop() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: nil, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, effects) = reduce(state, .renameJob(at: path, name: "   "))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_renameJob_unknownPath_isNoop() {
        let state = AppState.empty
        let path = JobPath(project: UUID(), worktree: UUID(), job: UUID())
        let (events, effects) = reduce(state, .renameJob(at: path, name: "x"))
        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: - claude session-id uniqueness

    func test_linkClaudeSession_otherJobOwnsTheSid_isNoop() {
        let projectId = UUID()
        let worktreeId = UUID()
        let ownerId = UUID()
        let targetId = UUID()
        let owner = makeJob(
            id: ownerId, kind: .claude(sessionId: "shared"),
            primaryPid: nil, auxPids: []
        )
        let target = makeJob(
            id: targetId, kind: .claude(sessionId: nil),
            primaryPid: nil, auxPids: []
        )
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [owner, target])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: targetId)

        let (events, effects) = reduce(state, .linkClaudeSession(at: path, sessionId: "shared"))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_linkClaudeSession_sameJobReLinkingItsOwnSid_isAllowed() {
        // A sid the SAME job already tracks is fine to re-link (no-op on
        // disk, but not a "conflict" — the owner *is* this job).
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let job = makeJob(
            id: jobId, kind: .claude(sessionId: "live"),
            primaryPid: nil, auxPids: []
        )
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [job])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, effects) = reduce(state, .linkClaudeSession(at: path, sessionId: "live"))

        XCTAssertEqual(events, [.claudeSessionLinked(at: path, sessionId: "live")])
        XCTAssertEqual(effects.count, 1)
    }

    func test_discoverClaudeSession_sidTrackedInOtherWorktree_isNoop() {
        let projectId = UUID()
        let wtA = UUID()
        let wtB = UUID()
        let existing = makeJob(
            id: UUID(), kind: .claude(sessionId: "live"),
            primaryPid: nil, auxPids: []
        )
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: wtA, jobs: [existing]),
                makeWorktree(id: wtB, jobs: [])
            ])
        ])

        let (events, effects) = reduce(state, .discoverClaudeSession(
            at: WorktreePath(project: projectId, worktree: wtB),
            sessionId: "live",
            cwd: URL(fileURLWithPath: "/somewhere")
        ))

        XCTAssertTrue(events.isEmpty)
        XCTAssertTrue(effects.isEmpty)
    }

    func test_processExited_clearsPid() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        var state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [
                    makeJob(id: jobId, primaryPid: 333, auxPids: [])
                ])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (events, _) = reduce(state, .processExited(at: path, index: 0, code: 0))
        for e in events { apply(&state, e) }

        XCTAssertNil(state.projects[0].worktrees[0].jobs[0].primary.pid)
    }

    func test_processExited_aux_alwaysRestart_emitsSpawn() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let auxSpec = ProcessSpec(
            command: "/usr/local/bin/dev",
            args: ["server"],
            env: [:],
            cwd: URL(fileURLWithPath: "/wt"),
            pid: 9999,
            initialInput: nil,
            restartPolicy: .alwaysRestart
        )
        let job = Job(
            id: jobId, name: "stack", kind: .shell, enabled: true, status: .running,
            primary: ProcessSpec(
                command: "/bin/zsh", args: [], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                pid: 1, initialInput: nil, restartPolicy: .never
            ),
            auxiliary: [auxSpec],
            unread: 0, createdAt: Date(), completedAt: nil
        )
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [job])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (_, effects) = reduce(state, .processExited(at: path, index: 1, code: 1))

        let spawnEffects = effects.compactMap { effect -> ProcessSpec? in
            if case let .spawn(_, idx, spec) = effect, idx == 1 { return spec }
            return nil
        }
        XCTAssertEqual(spawnEffects.count, 1)
        XCTAssertEqual(spawnEffects[0].command, "/usr/local/bin/dev")
    }

    func test_processExited_aux_neverPolicy_doesNotRestart() {
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let job = Job(
            id: jobId, name: "j", kind: .shell, enabled: true, status: .running,
            primary: ProcessSpec(
                command: "/bin/zsh", args: [], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                pid: 1, initialInput: nil, restartPolicy: .never
            ),
            auxiliary: [ProcessSpec(
                command: "/bin/dev", args: [], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                pid: 2, initialInput: nil, restartPolicy: .never
            )],
            unread: 0, createdAt: Date(), completedAt: nil
        )
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [job])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (_, effects) = reduce(state, .processExited(at: path, index: 1, code: 0))

        XCTAssertFalse(effects.contains(where: { effect in
            if case .spawn = effect { return true }
            return false
        }))
    }

    func test_processExited_aux_alwaysRestart_butJobDisabled_doesNotRestart() {
        // Disabling the job is the user's panic switch — alwaysRestart must
        // not loop respawn while the job is off.
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let job = Job(
            id: jobId, name: "j", kind: .shell, enabled: false, status: .stopped,
            primary: ProcessSpec(
                command: "/bin/zsh", args: [], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                pid: nil, initialInput: nil, restartPolicy: .never
            ),
            auxiliary: [ProcessSpec(
                command: "/bin/dev", args: [], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                pid: 7, initialInput: nil, restartPolicy: .alwaysRestart
            )],
            unread: 0, createdAt: Date(), completedAt: nil
        )
        let state = stateWith(projects: [
            makeProject(id: projectId, worktrees: [
                makeWorktree(id: worktreeId, jobs: [job])
            ])
        ])
        let path = JobPath(project: projectId, worktree: worktreeId, job: jobId)

        let (_, effects) = reduce(state, .processExited(at: path, index: 1, code: 0))

        XCTAssertFalse(effects.contains(where: { effect in
            if case .spawn = effect { return true }
            return false
        }))
    }
}

// MARK: - Helpers

private func stateWith(projects: [Project]) -> AppState {
    AppState(
        schemaVersion: 1,
        projects: projects,
        settings: Settings(scrollbackCapBytes: 1024, snapshotIntervalSeconds: 30, terminalTheme: "Dracula", terminalFontFamily: "", terminalFontSize: 13)
    )
}

private func makeProject(id: UUID, worktrees: [Worktree]) -> Project {
    Project(
        id: id,
        name: "atlas",
        color: "#ff5500",
        rootDir: URL(fileURLWithPath: "/p/atlas"),
        enabled: true,
        worktrees: worktrees,
        createdAt: Date()
    )
}

private func makeWorktree(id: UUID, jobs: [Job]) -> Worktree {
    Worktree(
        id: id,
        name: "main",
        path: URL(fileURLWithPath: "/wt/main"),
        kind: .folder,
        enabled: true,
        missing: false,
        jobs: jobs,
        createdAt: Date()
    )
}

private func makeJob(id: UUID, primaryPid: Int32?, auxPids: [Int32?]) -> Job {
    makeJob(id: id, kind: .shell, primaryPid: primaryPid, auxPids: auxPids)
}

private func makeJob(id: UUID, kind: JobKind, primaryPid: Int32?, auxPids: [Int32?]) -> Job {
    Job(
        id: id,
        name: "shell",
        kind: kind,
        enabled: true,
        status: .running,
        primary: ProcessSpec(
            command: "/bin/zsh",
            args: [],
            env: [:],
            cwd: URL(fileURLWithPath: "/wt/main"),
            pid: primaryPid,
            initialInput: nil, restartPolicy: .never),
        auxiliary: auxPids.map { pid in
            ProcessSpec(
                command: "/usr/local/bin/aux",
                args: [],
                env: [:],
                cwd: URL(fileURLWithPath: "/wt/main"),
                pid: pid,
                initialInput: nil, restartPolicy: .never)
        },
        unread: 0,
        createdAt: Date(),
        completedAt: nil
    )
}

private func terminatedPids(in effects: [Effect]) -> [Int32] {
    effects.compactMap { effect -> Int32? in
        if case let .terminate(pid, _) = effect { return pid }
        return nil
    }
}
