import XCTest
@testable import ManiCore

final class ClaudeSessionStartTests: XCTestCase {

    // MARK: - Source enum parsing

    func test_source_knownStrings_decodeToTypedCases() {
        XCTAssertEqual(SessionStartPayload.Source(rawValue: "startup"), .startup)
        XCTAssertEqual(SessionStartPayload.Source(rawValue: "resume"),  .resume)
        XCTAssertEqual(SessionStartPayload.Source(rawValue: "clear"),   .clear)
        XCTAssertEqual(SessionStartPayload.Source(rawValue: "compact"), .compact)
        XCTAssertEqual(SessionStartPayload.Source(rawValue: "fork"),    .fork)
    }

    func test_source_unknownString_decodesToOther() {
        XCTAssertEqual(
            SessionStartPayload.Source(rawValue: "rewind"),
            .other("rewind")
        )
    }

    // MARK: - resume retargets the most-recently-created mismatched task

    func test_route_resume_retargetsMatchingWorktreeTask() {
        let oldSid = "old-session-id"
        let newSid = "new-session-id"
        let projectId = UUID()
        let worktreeId = UUID()
        let taskId = UUID()
        let wtPath = URL(fileURLWithPath: "/Users/me/wt")
        let state = stateWith(
            projectId: projectId,
            worktreeId: worktreeId,
            worktreePath: wtPath,
            tasks: [
                claudeTask(id: taskId, sid: oldSid, createdAt: Date())
            ]
        )
        let payload = SessionStartPayload(
            sessionId: newSid,
            cwd: wtPath.path,
            transcriptPath: nil,
            source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/Users/me"
        )

        guard case let .linkClaudeSession(at, sid) = action else {
            return XCTFail("expected linkClaudeSession, got \(String(describing: action))")
        }
        XCTAssertEqual(sid, newSid)
        XCTAssertEqual(at.project, projectId)
        XCTAssertEqual(at.worktree, worktreeId)
        XCTAssertEqual(at.task, taskId)
    }

    func test_route_resume_withMultipleMismatches_picksMostRecent() {
        let projectId = UUID()
        let worktreeId = UUID()
        let oldTask = claudeTask(id: UUID(), sid: "old-1", createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        let newTask = claudeTask(id: UUID(), sid: "old-2", createdAt: Date(timeIntervalSinceReferenceDate: 9_000))
        let state = stateWith(
            projectId: projectId,
            worktreeId: worktreeId,
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [oldTask, newTask]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: "/wt", transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .linkClaudeSession(at, _) = action else {
            return XCTFail("expected linkClaudeSession")
        }
        XCTAssertEqual(at.task, newTask.id)
    }

    // MARK: - clear / compact route like resume

    func test_route_clear_retargets() {
        let task = claudeTask(id: UUID(), sid: "old", createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [task]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: "/wt", transcriptPath: nil, source: .clear
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case .linkClaudeSession = action else {
            return XCTFail("expected linkClaudeSession for clear")
        }
    }

    func test_route_compact_retargets() {
        let task = claudeTask(id: UUID(), sid: "old", createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [task]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: "/wt", transcriptPath: nil, source: .compact
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case .linkClaudeSession = action else {
            return XCTFail("expected linkClaudeSession for compact")
        }
    }

    // MARK: - startup links to an unlinked .claude(nil) slot

    func test_route_startup_linksToUnlinkedSlot() {
        let projectId = UUID()
        let worktreeId = UUID()
        let unlinkedId = UUID()
        let state = stateWith(
            projectId: projectId, worktreeId: worktreeId,
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [claudeTask(id: unlinkedId, sid: nil, createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "fresh", cwd: "/wt", transcriptPath: nil, source: .startup
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .linkClaudeSession(at, sid) = action else {
            return XCTFail("expected linkClaudeSession for startup")
        }
        XCTAssertEqual(at.task, unlinkedId)
        XCTAssertEqual(sid, "fresh")
    }

    func test_route_startup_withNoUnlinkedSlot_discovers() {
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: []
        )
        let payload = SessionStartPayload(
            sessionId: "fresh", cwd: "/wt", transcriptPath: nil, source: .startup
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .discoverClaudeSession(_, sid, cwd) = action else {
            return XCTFail("expected discoverClaudeSession fallback")
        }
        XCTAssertEqual(sid, "fresh")
        XCTAssertEqual(cwd.path, "/wt")
    }

    // MARK: - fork always creates a sibling

    func test_route_fork_createsSibling_evenWhenExistingClaudeTaskExists() {
        let existing = claudeTask(id: UUID(), sid: "original", createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [existing]
        )
        let payload = SessionStartPayload(
            sessionId: "forked", cwd: "/wt", transcriptPath: nil, source: .fork
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .discoverClaudeSession(_, sid, _) = action else {
            return XCTFail("expected discoverClaudeSession for fork")
        }
        XCTAssertEqual(sid, "forked")
    }

    // MARK: - idempotence

    func test_route_alreadyTrackedSid_returnsNil() {
        let sid = "live"
        let task = claudeTask(id: UUID(), sid: sid, createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [task]
        )
        let payload = SessionStartPayload(
            sessionId: sid, cwd: "/wt", transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        XCTAssertNil(action)
    }

    // MARK: - cwd-not-matched and broad-cwd guards

    func test_route_cwdDoesNotMatchWorktree_returnsNil() {
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt-a"),
            tasks: [claudeTask(id: UUID(), sid: "old", createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: "/somewhere/else", transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        XCTAssertNil(action)
    }

    func test_route_worktreeAtHome_isSkipped_evenIfCwdMatches() {
        let homePath = "/Users/me"
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: homePath),
            tasks: [claudeTask(id: UUID(), sid: "old", createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "new",
            cwd: "\(homePath)/some/sub",
            transcriptPath: nil,
            source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: homePath
        )

        XCTAssertNil(action)
    }

    func test_route_missingCwd_returnsNil() {
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            tasks: [claudeTask(id: UUID(), sid: "old", createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: nil, transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        XCTAssertNil(action)
    }

    // MARK: - Test helpers

    private func stateWith(
        projectId: UUID,
        worktreeId: UUID,
        worktreePath: URL,
        tasks: [Task]
    ) -> AppState {
        AppState(
            schemaVersion: 2,
            projects: [
                Project(
                    id: projectId, name: "p", color: "#000",
                    enabled: true,
                    rootDir: worktreePath,
                    worktrees: [
                        Worktree(
                            id: worktreeId,
                            path: worktreePath, kind: .folder,
                            enabled: true, missing: false,
                            tasks: tasks, createdAt: Date()
                        )
                    ],
                    createdAt: Date(),
                    claudeInvocation: nil
                )
            ],
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

    private func claudeTask(id: UUID, sid: String?, createdAt: Date) -> Task {
        Task(
            id: id, name: "claude",
            kind: .claude(sessionId: sid),
            enabled: true,
            spec: ProcessSpec(
                command: "/bin/zsh", args: ["-l"], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                initialInput: "claude\r"
            ),
            runtime: .running(spawnedAt: createdAt),
            unread: 0,
            createdAt: createdAt,
            renamed: false
        )
    }
}
