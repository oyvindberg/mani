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

    // MARK: - resume retargets the most-recently-created mismatched job

    func test_route_resume_retargetsMatchingWorktreeJob() {
        let oldSid = "old-session-id"
        let newSid = "new-session-id"
        let projectId = UUID()
        let worktreeId = UUID()
        let jobId = UUID()
        let wtPath = URL(fileURLWithPath: "/Users/me/wt")
        let state = stateWith(
            projectId: projectId,
            worktreeId: worktreeId,
            worktreePath: wtPath,
            jobs: [
                claudeJob(id: jobId, sid: oldSid, createdAt: Date())
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
        XCTAssertEqual(at.job, jobId)
    }

    func test_route_resume_withMultipleMismatches_picksMostRecent() {
        let projectId = UUID()
        let worktreeId = UUID()
        let oldJob = claudeJob(id: UUID(), sid: "old-1", createdAt: Date(timeIntervalSinceReferenceDate: 1_000))
        let newJob = claudeJob(id: UUID(), sid: "old-2", createdAt: Date(timeIntervalSinceReferenceDate: 9_000))
        let state = stateWith(
            projectId: projectId,
            worktreeId: worktreeId,
            worktreePath: URL(fileURLWithPath: "/wt"),
            jobs: [oldJob, newJob]
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
        XCTAssertEqual(at.job, newJob.id)
    }

    // MARK: - clear / compact route like resume

    func test_route_clear_retargets() {
        let job = claudeJob(id: UUID(), sid: "old", createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            jobs: [job]
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
        let job = claudeJob(id: UUID(), sid: "old", createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            jobs: [job]
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
            jobs: [claudeJob(id: unlinkedId, sid: nil, createdAt: Date())]
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
        XCTAssertEqual(at.job, unlinkedId)
        XCTAssertEqual(sid, "fresh")
    }

    func test_route_startup_withNoUnlinkedSlot_discovers() {
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            jobs: [] // no claude jobs
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

    func test_route_fork_createsSibling_evenWhenExistingClaudeJobExists() {
        let existing = claudeJob(id: UUID(), sid: "original", createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            jobs: [existing]
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
        let job = claudeJob(id: UUID(), sid: sid, createdAt: Date())
        let state = stateWith(
            projectId: UUID(), worktreeId: UUID(),
            worktreePath: URL(fileURLWithPath: "/wt"),
            jobs: [job]
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
            jobs: [claudeJob(id: UUID(), sid: "old", createdAt: Date())]
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
            jobs: [claudeJob(id: UUID(), sid: "old", createdAt: Date())]
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
            jobs: [claudeJob(id: UUID(), sid: "old", createdAt: Date())]
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
        jobs: [Job]
    ) -> AppState {
        AppState(
            schemaVersion: 1,
            projects: [
                Project(
                    id: projectId, name: "p", color: "#000",
                    enabled: true,
                    worktrees: [
                        Worktree(
                            id: worktreeId, name: "wt",
                            path: worktreePath, kind: .folder,
                            enabled: true, missing: false,
                            jobs: jobs, createdAt: Date(),
                            primary: false
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
            )
        )
    }

    private func claudeJob(id: UUID, sid: String?, createdAt: Date) -> Job {
        Job(
            id: id, name: "claude",
            kind: .claude(sessionId: sid),
            enabled: true, status: .running,
            primary: ProcessSpec(
                command: "/bin/zsh", args: ["-l"], env: [:],
                cwd: URL(fileURLWithPath: "/wt"),
                pid: 100, initialInput: "claude\r", restartPolicy: .never
            ),
            auxiliary: [],
            unread: 0,
            createdAt: createdAt,
            completedAt: nil, renamed: false        )
    }
}
