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

    func test_route_resume_retargetsMatchingProjectTask() {
        let oldSid = "old-session-id"
        let newSid = "new-session-id"
        let repoId = UUID()
        let projectId = UUID()
        let taskId = UUID()
        let wsPath = URL(fileURLWithPath: "/Users/me/wt")
        let state = stateWith(
            repoId: repoId,
            projectId: projectId,
            workspacePath: wsPath,
            tasks: [claudeTask(id: taskId, sid: oldSid, createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: newSid, cwd: wsPath.path,
            transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/Users/me"
        )

        guard case let .linkClaudeSession(at, sid) = action else {
            return XCTFail("expected linkClaudeSession, got \(String(describing: action))")
        }
        XCTAssertEqual(sid, newSid)
        XCTAssertEqual(at.repo, repoId)
        XCTAssertEqual(at.project, projectId)
        XCTAssertEqual(at.task, taskId)
    }

    func test_route_startup_linksToUnlinkedSlot() {
        let repoId = UUID()
        let projectId = UUID()
        let unlinkedId = UUID()
        let state = stateWith(
            repoId: repoId, projectId: projectId,
            workspacePath: URL(fileURLWithPath: "/wt"),
            tasks: [claudeTask(id: unlinkedId, sid: nil, createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "fresh", cwd: "/wt",
            transcriptPath: nil, source: .startup
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .linkClaudeSession(at, sid) = action else {
            return XCTFail("expected linkClaudeSession")
        }
        XCTAssertEqual(at.task, unlinkedId)
        XCTAssertEqual(sid, "fresh")
    }

    func test_route_startup_noUnlinkedSlot_discoversExternalConvo() {
        let repoId = UUID()
        let state = stateWith(
            repoId: repoId, projectId: UUID(),
            workspacePath: URL(fileURLWithPath: "/wt"),
            tasks: []
        )
        let payload = SessionStartPayload(
            sessionId: "fresh", cwd: "/wt",
            transcriptPath: nil, source: .startup
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .discoverExternalConvo(r, sid, cwd) = action else {
            return XCTFail("expected discoverExternalConvo, got \(String(describing: action))")
        }
        XCTAssertEqual(r, repoId)
        XCTAssertEqual(sid, "fresh")
        XCTAssertEqual(cwd.path, "/wt")
    }

    func test_route_fork_alwaysDiscoversExternalConvo() {
        let repoId = UUID()
        let existing = claudeTask(id: UUID(), sid: "original", createdAt: Date())
        let state = stateWith(
            repoId: repoId, projectId: UUID(),
            workspacePath: URL(fileURLWithPath: "/wt"),
            tasks: [existing]
        )
        let payload = SessionStartPayload(
            sessionId: "forked", cwd: "/wt",
            transcriptPath: nil, source: .fork
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        guard case let .discoverExternalConvo(r, sid, _) = action else {
            return XCTFail("expected discoverExternalConvo for fork")
        }
        XCTAssertEqual(r, repoId)
        XCTAssertEqual(sid, "forked")
    }

    func test_route_alreadyTrackedSid_returnsNil() {
        let sid = "live"
        let task = claudeTask(id: UUID(), sid: sid, createdAt: Date())
        let state = stateWith(
            repoId: UUID(), projectId: UUID(),
            workspacePath: URL(fileURLWithPath: "/wt"),
            tasks: [task]
        )
        let payload = SessionStartPayload(
            sessionId: sid, cwd: "/wt",
            transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        XCTAssertNil(action)
    }

    func test_route_cwdDoesNotMatchAnyRepo_returnsNil() {
        let state = stateWith(
            repoId: UUID(), projectId: UUID(),
            workspacePath: URL(fileURLWithPath: "/wt-a"),
            tasks: [claudeTask(id: UUID(), sid: "old", createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: "/somewhere/else",
            transcriptPath: nil, source: .resume
        )
        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )
        XCTAssertNil(action)
    }

    func test_route_workspaceAtHome_isSkipped_evenIfCwdMatches() {
        let homePath = "/Users/me"
        let state = stateWith(
            repoId: UUID(), projectId: UUID(),
            workspacePath: URL(fileURLWithPath: homePath),
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
            repoId: UUID(), projectId: UUID(),
            workspacePath: URL(fileURLWithPath: "/wt"),
            tasks: [claudeTask(id: UUID(), sid: "old", createdAt: Date())]
        )
        let payload = SessionStartPayload(
            sessionId: "new", cwd: nil,
            transcriptPath: nil, source: .resume
        )

        let action = routeSessionStart(
            payload: payload, state: state, homePathToExclude: "/home"
        )

        XCTAssertNil(action)
    }

    // MARK: - Test helpers

    private func stateWith(
        repoId: UUID,
        projectId: UUID,
        workspacePath: URL,
        tasks: [Task]
    ) -> AppState {
        AppState(
            schemaVersion: 2,
            repos: [
                Repo(
                    id: repoId, name: "r", color: "#000",
                    enabled: true,
                    rootDir: workspacePath,
                    projects: [
                        Project(
                            id: projectId, name: "p",
                            workspace: Workspace(
                                path: workspacePath, kind: .folder, missing: false
                            ),
                            tasks: tasks,
                            archivedAt: nil,
                            createdAt: Date()
                        )
                    ],
                    externalConvos: [],
                    availableWorktrees: [],
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
