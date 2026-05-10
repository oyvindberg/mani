import XCTest
@testable import ManiCore

final class ClaudeTaskSpecTests: XCTestCase {

    // MARK: - .make

    func test_make_freshSession_injectsClaudeNewline() {
        let cwd = URL(fileURLWithPath: "/Users/me/wt")
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil)

        XCTAssertEqual(spec.command, "/bin/zsh")
        XCTAssertEqual(spec.args, ["-l"])
        XCTAssertEqual(spec.cwd, cwd)
        XCTAssertNil(spec.pid)
        XCTAssertEqual(spec.initialInput, "claude\r")
    }

    func test_make_resumeSession_injectsResumeWithSessionId() {
        let spec = ClaudeTaskSpec.make(
            cwd: URL(fileURLWithPath: "/Users/me/wt"),
            sessionId: "abc-123"
        )

        XCTAssertEqual(spec.initialInput, "claude --resume abc-123\r")
    }

    // MARK: - .restartSpec

    func test_restartSpec_claudeJob_rebuildsFromFactory() {
        // Persisted as a stale pre-zsh-injection spec — what would have been
        // written by an older Mani build. restartSpec must IGNORE this and
        // produce the current factory shape.
        let stale = ProcessSpec(
            command: "/usr/bin/env",
            args: ["claude", "--resume", "old-session"],
            env: [:],
            cwd: URL(fileURLWithPath: "/old/cwd"),
            pid: nil,
            initialInput: nil, restartPolicy: .never)
        let job = makeJob(kind: .claude(sessionId: "old-session"), spec: stale)

        let restart = ClaudeTaskSpec.restartSpec(for: job)

        XCTAssertEqual(restart.command, "/bin/zsh")
        XCTAssertEqual(restart.args, ["-l"])
        XCTAssertEqual(restart.cwd, URL(fileURLWithPath: "/old/cwd"))
        XCTAssertEqual(restart.initialInput, "claude --resume old-session\r")
    }

    func test_restartSpec_freshClaudeJob_omitsResumeFlag() {
        let stale = ProcessSpec(
            command: "/usr/bin/env",
            args: ["claude"],
            env: [:],
            cwd: URL(fileURLWithPath: "/cwd"),
            pid: nil,
            initialInput: nil, restartPolicy: .never)
        let job = makeJob(kind: .claude(sessionId: nil), spec: stale)

        let restart = ClaudeTaskSpec.restartSpec(for: job)

        XCTAssertEqual(restart.initialInput, "claude\r")
    }

    func test_restartSpec_shellJob_returnsSpecVerbatim() {
        let original = ProcessSpec(
            command: "/usr/local/bin/dev",
            args: ["server", "--port", "8080"],
            env: ["FOO": "bar"],
            cwd: URL(fileURLWithPath: "/cwd"),
            pid: 42,
            initialInput: nil, restartPolicy: .never)
        let job = makeJob(kind: .shell, spec: original)

        let restart = ClaudeTaskSpec.restartSpec(for: job)

        XCTAssertEqual(restart, original)
    }

    // MARK: - AppState.withoutClaudeJobs / .claudeJobs

    func test_withoutClaudeJobs_removesClaude_keepsShell() {
        let claudeJob = makeJob(kind: .claude(sessionId: "s1"), spec: anySpec())
        let shellJob = makeJob(kind: .shell, spec: anySpec())
        let state = AppState(
            schemaVersion: 1,
            projects: [makeProject(jobs: [claudeJob, shellJob])],
            settings: anySettings()
        )

        let cleaned = state.withoutClaudeJobs()

        let remaining = cleaned.projects[0].worktrees[0].jobs
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].id, shellJob.id)
        XCTAssertEqual(remaining[0].kind, .shell)
    }

    func test_withoutClaudeJobs_emptyState_isUnchanged() {
        let state = AppState.empty
        XCTAssertEqual(state.withoutClaudeJobs(), state)
    }

    func test_withoutClaudeJobs_preservesProjectsAndWorktrees() {
        let claudeJob = makeJob(kind: .claude(sessionId: nil), spec: anySpec())
        let state = AppState(
            schemaVersion: 1,
            projects: [makeProject(jobs: [claudeJob])],
            settings: anySettings()
        )

        let cleaned = state.withoutClaudeJobs()

        XCTAssertEqual(cleaned.projects.count, 1)
        XCTAssertEqual(cleaned.projects[0].worktrees.count, 1)
        XCTAssertEqual(cleaned.projects[0].worktrees[0].jobs.count, 0)
    }

    func test_claudeJobs_returnsAllClaudePathsAcrossProjects() {
        let c1 = makeJob(kind: .claude(sessionId: "s1"), spec: anySpec())
        let c2 = makeJob(kind: .claude(sessionId: "s2"), spec: anySpec())
        let shell = makeJob(kind: .shell, spec: anySpec())
        let state = AppState(
            schemaVersion: 1,
            projects: [
                makeProject(jobs: [c1, shell]),
                makeProject(jobs: [c2]),
            ],
            settings: anySettings()
        )

        let pairs = state.claudeJobs()

        let ids = pairs.map { $0.1.id }
        XCTAssertEqual(Set(ids), Set([c1.id, c2.id]))
    }

    // MARK: - Test helpers

    private func makeJob(kind: JobKind, spec: ProcessSpec) -> Job {
        Job(
            id: UUID(),
            name: "test",
            kind: kind,
            enabled: true,
            status: .running,
            primary: spec,
            auxiliary: [],
            unread: 0,
            createdAt: Date(),
            completedAt: nil, renamed: false        )
    }

    private func makeProject(jobs: [Job]) -> Project {
        Project(
            id: UUID(),
            name: "p",
            color: "#000",
            rootDir: URL(fileURLWithPath: "/p"),
            enabled: true,
            worktrees: [
                Worktree(
                    id: UUID(),
                    name: "main",
                    path: URL(fileURLWithPath: "/p/main"),
                    kind: .folder,
                    enabled: true,
                    missing: false,
                    jobs: jobs,
                    createdAt: Date()
                )
            ],
            createdAt: Date()
        )
    }

    private func anySpec() -> ProcessSpec {
        ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:],
            cwd: URL(fileURLWithPath: "/cwd"),
            pid: nil,
            initialInput: nil, restartPolicy: .never)
    }

    private func anySettings() -> Settings {
        Settings(
            scrollbackCapBytes: 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13
        )
    }
}
