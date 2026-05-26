import XCTest
@testable import ManiCore

final class ClaudeTaskSpecTests: XCTestCase {

    // MARK: - .make

    func test_make_freshSession_typesClaude() {
        let cwd = URL(fileURLWithPath: "/Users/me/wt")
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil, invocation: "claude")

        XCTAssertEqual(spec.command, "/bin/zsh")
        XCTAssertEqual(spec.args, ["-l"])
        XCTAssertEqual(spec.cwd, cwd)
        XCTAssertEqual(spec.initialInput, "claude\r")
    }

    func test_make_resumeSession_typesResume() {
        let spec = ClaudeTaskSpec.make(
            cwd: URL(fileURLWithPath: "/Users/me/wt"),
            sessionId: "abc-123",
            invocation: "claude"
        )

        XCTAssertEqual(spec.initialInput, "claude --resume abc-123\r")
    }

    func test_make_customInvocation_preserved() {
        let spec = ClaudeTaskSpec.make(
            cwd: URL(fileURLWithPath: "/cwd"),
            sessionId: nil,
            invocation: "claude --dangerously-skip-permissions"
        )

        XCTAssertEqual(spec.initialInput, "claude --dangerously-skip-permissions\r")
    }

    func test_make_customInvocation_resumeAppended() {
        let spec = ClaudeTaskSpec.make(
            cwd: URL(fileURLWithPath: "/cwd"),
            sessionId: "s1",
            invocation: "claude --dangerously-skip-permissions"
        )

        XCTAssertEqual(spec.initialInput, "claude --dangerously-skip-permissions --resume s1\r")
    }

    func test_make_emptyInvocation_fallsBackToClaude() {
        let spec = ClaudeTaskSpec.make(
            cwd: URL(fileURLWithPath: "/cwd"),
            sessionId: nil,
            invocation: "   "
        )

        XCTAssertEqual(spec.initialInput, "claude\r")
    }

    // MARK: - .resolveInvocation

    func test_resolveInvocation_projectNil_usesSettings() {
        var s = anySettings()
        s.claudeInvocation = "claude --dangerously-skip-permissions"
        let resolved = ClaudeTaskSpec.resolveInvocation(repo: nil, settings: s)
        XCTAssertEqual(resolved, "claude --dangerously-skip-permissions")
    }

    func test_resolveInvocation_projectOverride_takesPrecedence() {
        var repo = makeRepo(tasks: [])
        repo.claudeInvocation = "claude --my-flag"
        var s = anySettings()
        s.claudeInvocation = "claude"
        let resolved = ClaudeTaskSpec.resolveInvocation(repo: repo, settings: s)
        XCTAssertEqual(resolved, "claude --my-flag")
    }

    func test_resolveInvocation_projectEmpty_fallsBackToClaude() {
        var repo = makeRepo(tasks: [])
        repo.claudeInvocation = "   "
        let resolved = ClaudeTaskSpec.resolveInvocation(repo: repo, settings: anySettings())
        XCTAssertEqual(resolved, "claude")
    }

    // MARK: - .restartSpec

    func test_restartSpec_claudeTask_rebuildsFromFactory() {
        let stale = ProcessSpec(
            command: "/bin/zsh",
            args: ["-l"],
            env: [:],
            cwd: URL(fileURLWithPath: "/old/cwd"),
            initialInput: "claude --resume old-session\r"
        )
        let task = makeTask(kind: .claude(sessionId: "old-session"), spec: stale)

        let restart = ClaudeTaskSpec.restartSpec(for: task, invocation: "claude")

        XCTAssertEqual(restart.command, "/bin/zsh")
        XCTAssertEqual(restart.args, ["-l"])
        XCTAssertEqual(restart.cwd, URL(fileURLWithPath: "/old/cwd"))
        XCTAssertEqual(restart.initialInput, "claude --resume old-session\r")
    }

    func test_restartSpec_freshClaudeTask_omitsResumeFlag() {
        let stale = ProcessSpec(
            command: "/usr/bin/env",
            args: ["claude"],
            env: [:],
            cwd: URL(fileURLWithPath: "/cwd"),
            initialInput: nil
        )
        let task = makeTask(kind: .claude(sessionId: nil), spec: stale)

        let restart = ClaudeTaskSpec.restartSpec(for: task, invocation: "claude")

        XCTAssertEqual(restart.initialInput, "claude\r")
    }

    func test_restartSpec_shellTask_returnsSpecVerbatim() {
        let original = ProcessSpec(
            command: "/usr/local/bin/dev",
            args: ["server", "--port", "8080"],
            env: ["FOO": "bar"],
            cwd: URL(fileURLWithPath: "/cwd"),
            initialInput: nil
        )
        let task = makeTask(kind: .shell, spec: original)

        let restart = ClaudeTaskSpec.restartSpec(for: task, invocation: "claude")

        XCTAssertEqual(restart, original)
    }

    // MARK: - AppState.claudeTasks

    func test_claudeTasks_returnsAllClaudePathsAcrossProjects() {
        let c1 = makeTask(kind: .claude(sessionId: "s1"), spec: anySpec())
        let c2 = makeTask(kind: .claude(sessionId: "s2"), spec: anySpec())
        let shell = makeTask(kind: .shell, spec: anySpec())
        let state = AppState(
            schemaVersion: 2,
            repos: [
                makeRepo(tasks: [c1, shell]),
                makeRepo(tasks: [c2]),
            ],
            settings: anySettings(),
            selectedTaskPath: nil
        )

        let pairs = state.claudeTasks()

        let ids = pairs.map { $0.1.id }
        XCTAssertEqual(Set(ids), Set([c1.id, c2.id]))
    }

    // MARK: - Test helpers

    private func makeTask(kind: TaskKind, spec: ProcessSpec) -> Task {
        Task(
            id: UUID(),
            name: "test",
            kind: kind,
            enabled: true,
            spec: spec,
            runtime: .running(spawnedAt: Date()),
            unread: 0,
            createdAt: Date(),
            renamed: false
        )
    }

    private func makeRepo(tasks: [Task]) -> Repo {
        Repo(
            id: UUID(),
            name: "p",
            color: "#000",
            enabled: true,
            rootDir: URL(fileURLWithPath: "/p/main"),
            projects: [
                Project(
                    id: UUID(),
                    name: "main",
                    workspace: Workspace(
                        path: URL(fileURLWithPath: "/p/main"),
                        kind: .folder,
                        missing: false
                    ),
                    tasks: tasks,
                    archivedAt: nil,
                    createdAt: Date()
                )
            ],
            externalConvos: [],
            availableWorktrees: [],
            createdAt: Date(),
            claudeInvocation: nil,
            worktreeMode: .manual,
            managedWorktreesNamespace: nil
        )
    }

    private func anySpec() -> ProcessSpec {
        ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:],
            cwd: URL(fileURLWithPath: "/cwd"),
            initialInput: nil
        )
    }

    private func anySettings() -> Settings {
        Settings(
            scrollbackCapBytes: 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13,
            claudeInvocation: "claude"
        )
    }
}
