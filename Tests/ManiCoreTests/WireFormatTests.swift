import XCTest
@testable import ManiCore

// Coverage of the {kind, payload} wire format for Action and Event.
//
// Two test patterns:
//
// 1. Round-trip per case: every Action / Event case encodes, decodes,
//    and re-encodes to identical JSON (sortedKeys for determinism).
//    Catches encode/decode asymmetry across every case.
//
// 2. Canonical-form goldens: a handful of representative cases assert
//    against literal JSON strings. Locks the on-the-wire shape so a
//    rename to a label or kind shows up as a test diff, not a silent
//    protocol break.
//
// Date encoding here uses JSONEncoder's default (Double seconds since
// 2001-01-01). The mani-server WebSocket transport will configure
// ISO 8601 when it lands — same Codable code, different encoder.
final class WireFormatTests: XCTestCase {

    // MARK: - Helpers

    private func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private func assertRoundTrips<T: Codable>(
        _ value: T,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let e = encoder()
        let data1 = try e.encode(value)
        let decoded = try JSONDecoder().decode(T.self, from: data1)
        let data2 = try e.encode(decoded)
        XCTAssertEqual(
            String(decoding: data1, as: UTF8.self),
            String(decoding: data2, as: UTF8.self),
            file: file, line: line
        )
    }

    private func assertEncodes<T: Encodable>(
        _ value: T,
        equals expected: String,
        file: StaticString = #file,
        line: UInt = #line
    ) throws {
        let data = try encoder().encode(value)
        XCTAssertEqual(
            String(decoding: data, as: UTF8.self),
            expected,
            file: file, line: line
        )
    }

    // Fixtures
    private let uuidA = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let uuidB = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let uuidT = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private let url = URL(fileURLWithPath: "/r")
    private let date = Date(timeIntervalSinceReferenceDate: 700_000_000)

    private func projectPath() -> ProjectPath {
        ProjectPath(repo: uuidA, project: uuidB)
    }

    private func taskPath() -> TaskPath {
        TaskPath(repo: uuidA, project: uuidB, task: uuidT)
    }

    private func externalConvoPath() -> ExternalConvoPath {
        ExternalConvoPath(repo: uuidA, convo: uuidB)
    }

    private func processSpec() -> ProcessSpec {
        ProcessSpec(
            command: "/bin/zsh",
            args: ["-l"],
            env: [:],
            cwd: url,
            initialInput: nil
        )
    }

    private func settings() -> Settings {
        Settings(
            scrollbackCapBytes: 32 * 1024 * 1024,
            snapshotIntervalSeconds: 30,
            terminalTheme: "Dracula",
            terminalFontFamily: "",
            terminalFontSize: 13,
            claudeInvocation: "claude"
        )
    }

    private func workspace() -> Workspace {
        Workspace(path: url, kind: .folder, missing: false)
    }

    // MARK: - Canonical form goldens (locks the wire shape)

    func test_canonical_action_renameRepo() throws {
        let a = Action.renameRepo(id: uuidA, name: "atlas")
        try assertEncodes(a, equals: """
            {"kind":"renameRepo","payload":{"id":"11111111-1111-1111-1111-111111111111","name":"atlas"}}
            """)
    }

    func test_canonical_action_updateSettings_unlabeledArgUsesTypeNameLabel() throws {
        let a = Action.updateSettings(settings())
        // The single unlabeled associated value is keyed by lowercased
        // type name → "settings".
        let data = try encoder().encode(a)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix(#"{"kind":"updateSettings","payload":{"settings":{"#))
    }

    func test_canonical_action_selectTask_nilOptionalEncodesNull() throws {
        let a = Action.selectTask(at: nil)
        try assertEncodes(a, equals: """
            {"kind":"selectTask","payload":{"at":null}}
            """)
    }

    func test_canonical_event_repoDeleted() throws {
        let e = Event.repoDeleted(id: uuidA)
        try assertEncodes(e, equals: """
            {"kind":"repoDeleted","payload":{"id":"11111111-1111-1111-1111-111111111111"}}
            """)
    }

    func test_canonical_event_taskSelectionChanged_nilEncodesNull() throws {
        let e = Event.taskSelectionChanged(nil)
        try assertEncodes(e, equals: """
            {"kind":"taskSelectionChanged","payload":{"taskPath":null}}
            """)
    }

    func test_canonical_event_taskMoved_fromTo() throws {
        let tp = taskPath()
        let e = Event.taskMoved(from: tp, to: tp)
        let data = try encoder().encode(e)
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.hasPrefix(#"{"kind":"taskMoved","payload":{"from":"#))
        XCTAssertTrue(s.contains(#""to":"#))
    }

    func test_decode_unknownKind_throws() {
        let bad = #"{"kind":"nopeNope","payload":{}}"#.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(Action.self, from: bad))
        XCTAssertThrowsError(try JSONDecoder().decode(Event.self, from: bad))
    }

    // MARK: - Action round-trips

    func test_action_createRepo_roundTrips() throws {
        try assertRoundTrips(Action.createRepo(name: "atlas", color: "#ff5500", rootDir: url))
    }
    func test_action_renameRepo_roundTrips() throws {
        try assertRoundTrips(Action.renameRepo(id: uuidA, name: "atlas"))
    }
    func test_action_setRepoEnabled_roundTrips() throws {
        try assertRoundTrips(Action.setRepoEnabled(id: uuidA, enabled: false))
    }
    func test_action_setRepoColor_roundTrips() throws {
        try assertRoundTrips(Action.setRepoColor(id: uuidA, color: "#fff"))
    }
    func test_action_setRepoClaudeInvocation_nil_roundTrips() throws {
        try assertRoundTrips(Action.setRepoClaudeInvocation(id: uuidA, invocation: nil))
    }
    func test_action_setRepoClaudeInvocation_value_roundTrips() throws {
        try assertRoundTrips(Action.setRepoClaudeInvocation(id: uuidA, invocation: "claude --foo"))
    }
    func test_action_setRepoRootDir_roundTrips() throws {
        try assertRoundTrips(Action.setRepoRootDir(at: projectPath()))
    }
    func test_action_deleteRepo_roundTrips() throws {
        try assertRoundTrips(Action.deleteRepo(id: uuidA))
    }
    func test_action_setRepoWorktreeMode_roundTrips() throws {
        try assertRoundTrips(Action.setRepoWorktreeMode(id: uuidA, mode: .managed))
    }
    func test_action_setRepoManagedWorktreesNamespace_nil_roundTrips() throws {
        try assertRoundTrips(Action.setRepoManagedWorktreesNamespace(id: uuidA, namespace: nil))
    }
    func test_action_setRepoManagedWorktreesNamespace_value_roundTrips() throws {
        try assertRoundTrips(Action.setRepoManagedWorktreesNamespace(id: uuidA, namespace: "wt"))
    }
    func test_action_createProject_roundTrips() throws {
        try assertRoundTrips(Action.createProject(repoId: uuidA, name: "p", workspace: workspace()))
    }
    func test_action_renameProject_roundTrips() throws {
        try assertRoundTrips(Action.renameProject(at: projectPath(), name: "p"))
    }
    func test_action_archiveProject_roundTrips() throws {
        try assertRoundTrips(Action.archiveProject(at: projectPath()))
    }
    func test_action_unarchiveProject_roundTrips() throws {
        try assertRoundTrips(Action.unarchiveProject(at: projectPath()))
    }
    func test_action_markProjectWorkspaceMissing_roundTrips() throws {
        try assertRoundTrips(Action.markProjectWorkspaceMissing(at: projectPath()))
    }
    func test_action_deleteProject_roundTrips() throws {
        try assertRoundTrips(Action.deleteProject(at: projectPath()))
    }
    func test_action_finishProject_roundTrips() throws {
        try assertRoundTrips(Action.finishProject(at: projectPath(), cleanup: .archiveOnly))
    }
    func test_action_createTask_roundTrips() throws {
        try assertRoundTrips(Action.createTask(
            at: projectPath(),
            name: "t",
            kind: .shell,
            spec: processSpec(),
            autoSelect: true
        ))
    }
    func test_action_setTaskEnabled_roundTrips() throws {
        try assertRoundTrips(Action.setTaskEnabled(at: taskPath(), enabled: false))
    }
    func test_action_renameTask_roundTrips() throws {
        try assertRoundTrips(Action.renameTask(at: taskPath(), name: "t"))
    }
    func test_action_deleteTask_roundTrips() throws {
        try assertRoundTrips(Action.deleteTask(at: taskPath()))
    }
    func test_action_completeTask_roundTrips() throws {
        try assertRoundTrips(Action.completeTask(at: taskPath()))
    }
    func test_action_linkClaudeSession_roundTrips() throws {
        try assertRoundTrips(Action.linkClaudeSession(at: taskPath(), sessionId: "sid"))
    }
    func test_action_bumpUnread_roundTrips() throws {
        try assertRoundTrips(Action.bumpUnread(at: taskPath(), by: 3))
    }
    func test_action_markRead_roundTrips() throws {
        try assertRoundTrips(Action.markRead(at: taskPath()))
    }
    func test_action_restartTask_roundTrips() throws {
        try assertRoundTrips(Action.restartTask(at: taskPath()))
    }
    func test_action_setTaskSpec_roundTrips() throws {
        try assertRoundTrips(Action.setTaskSpec(at: taskPath(), spec: processSpec()))
    }
    func test_action_moveTask_roundTrips() throws {
        try assertRoundTrips(Action.moveTask(from: taskPath(), to: projectPath()))
    }
    func test_action_removeAvailableWorktree_roundTrips() throws {
        try assertRoundTrips(Action.removeAvailableWorktree(repoId: uuidA, id: uuidB))
    }
    func test_action_addAvailableWorktree_roundTrips() throws {
        try assertRoundTrips(Action.addAvailableWorktree(repoId: uuidA, path: url, kind: .folder))
    }
    func test_action_discoverExternalConvo_roundTrips() throws {
        try assertRoundTrips(Action.discoverExternalConvo(repoId: uuidA, sessionId: "sid", cwd: url))
    }
    func test_action_dismissExternalConvo_roundTrips() throws {
        try assertRoundTrips(Action.dismissExternalConvo(at: externalConvoPath()))
    }
    func test_action_adoptExternalConvo_roundTrips() throws {
        try assertRoundTrips(Action.adoptExternalConvo(at: externalConvoPath(), into: projectPath(), name: "n"))
    }
    func test_action_selectTask_nil_roundTrips() throws {
        try assertRoundTrips(Action.selectTask(at: nil))
    }
    func test_action_selectTask_value_roundTrips() throws {
        try assertRoundTrips(Action.selectTask(at: taskPath()))
    }
    func test_action_taskSpawned_roundTrips() throws {
        try assertRoundTrips(Action.taskSpawned(at: taskPath(), when: date))
    }
    func test_action_taskExited_roundTrips() throws {
        try assertRoundTrips(Action.taskExited(at: taskPath(), when: date, code: 0))
    }
    func test_action_updateSettings_roundTrips() throws {
        try assertRoundTrips(Action.updateSettings(settings()))
    }

    // MARK: - Event round-trips

    private func repoFixture() -> Repo {
        Repo(
            id: uuidA,
            name: "atlas",
            color: "#fff",
            enabled: true,
            rootDir: url,
            projects: [],
            externalConvos: [],
            availableWorktrees: [],
            createdAt: date,
            claudeInvocation: nil,
            worktreeMode: .manual,
            managedWorktreesNamespace: nil
        )
    }

    private func projectFixture() -> Project {
        Project(
            id: uuidB,
            name: "p",
            workspace: workspace(),
            tasks: [],
            archivedAt: nil,
            createdAt: date
        )
    }

    private func taskFixture() -> ManiCore.Task {
        ManiCore.Task(
            id: uuidT,
            name: "t",
            kind: .shell,
            enabled: true,
            spec: processSpec(),
            runtime: .neverStarted,
            unread: 0,
            createdAt: date,
            renamed: false
        )
    }

    private func availableWorktreeFixture() -> AvailableWorktree {
        AvailableWorktree(id: uuidA, path: url, kind: .folder, addedAt: date)
    }

    private func externalConvoFixture() -> ExternalConvo {
        ExternalConvo(id: uuidB, sessionId: "sid", cwd: url, firstSeenAt: date)
    }

    func test_event_repoCreated_roundTrips() throws {
        try assertRoundTrips(Event.repoCreated(repoFixture()))
    }
    func test_event_repoRenamed_roundTrips() throws {
        try assertRoundTrips(Event.repoRenamed(id: uuidA, name: "atlas"))
    }
    func test_event_repoEnabledChanged_roundTrips() throws {
        try assertRoundTrips(Event.repoEnabledChanged(id: uuidA, enabled: false))
    }
    func test_event_repoColorChanged_roundTrips() throws {
        try assertRoundTrips(Event.repoColorChanged(id: uuidA, color: "#fff"))
    }
    func test_event_repoClaudeInvocationChanged_nil_roundTrips() throws {
        try assertRoundTrips(Event.repoClaudeInvocationChanged(id: uuidA, invocation: nil))
    }
    func test_event_repoClaudeInvocationChanged_value_roundTrips() throws {
        try assertRoundTrips(Event.repoClaudeInvocationChanged(id: uuidA, invocation: "claude"))
    }
    func test_event_repoRootDirChanged_roundTrips() throws {
        try assertRoundTrips(Event.repoRootDirChanged(id: uuidA, rootDir: url))
    }
    func test_event_repoDeleted_roundTrips() throws {
        try assertRoundTrips(Event.repoDeleted(id: uuidA))
    }
    func test_event_repoWorktreeModeChanged_roundTrips() throws {
        try assertRoundTrips(Event.repoWorktreeModeChanged(id: uuidA, mode: .managed))
    }
    func test_event_repoManagedWorktreesNamespaceChanged_value_roundTrips() throws {
        try assertRoundTrips(Event.repoManagedWorktreesNamespaceChanged(id: uuidA, namespace: "wt"))
    }
    func test_event_projectCreated_roundTrips() throws {
        try assertRoundTrips(Event.projectCreated(repoId: uuidA, projectFixture()))
    }
    func test_event_projectRenamed_roundTrips() throws {
        try assertRoundTrips(Event.projectRenamed(at: projectPath(), name: "p"))
    }
    func test_event_projectArchived_roundTrips() throws {
        try assertRoundTrips(Event.projectArchived(at: projectPath(), when: date))
    }
    func test_event_projectUnarchived_roundTrips() throws {
        try assertRoundTrips(Event.projectUnarchived(at: projectPath()))
    }
    func test_event_projectWorkspaceMarkedMissing_roundTrips() throws {
        try assertRoundTrips(Event.projectWorkspaceMarkedMissing(at: projectPath()))
    }
    func test_event_projectDeleted_roundTrips() throws {
        try assertRoundTrips(Event.projectDeleted(at: projectPath()))
    }
    func test_event_taskCreated_roundTrips() throws {
        try assertRoundTrips(Event.taskCreated(at: projectPath(), taskFixture()))
    }
    func test_event_taskEnabledChanged_roundTrips() throws {
        try assertRoundTrips(Event.taskEnabledChanged(at: taskPath(), enabled: false))
    }
    func test_event_taskCompleted_roundTrips() throws {
        try assertRoundTrips(Event.taskCompleted(at: taskPath(), completedAt: date))
    }
    func test_event_taskUnreadBumped_roundTrips() throws {
        try assertRoundTrips(Event.taskUnreadBumped(at: taskPath(), by: 3))
    }
    func test_event_taskRead_roundTrips() throws {
        try assertRoundTrips(Event.taskRead(at: taskPath()))
    }
    func test_event_taskRenamed_roundTrips() throws {
        try assertRoundTrips(Event.taskRenamed(at: taskPath(), name: "t"))
    }
    func test_event_taskDeleted_roundTrips() throws {
        try assertRoundTrips(Event.taskDeleted(at: taskPath()))
    }
    func test_event_taskSpecChanged_roundTrips() throws {
        try assertRoundTrips(Event.taskSpecChanged(at: taskPath(), spec: processSpec()))
    }
    func test_event_claudeSessionLinked_roundTrips() throws {
        try assertRoundTrips(Event.claudeSessionLinked(at: taskPath(), sessionId: "sid"))
    }
    func test_event_taskMoved_roundTrips() throws {
        try assertRoundTrips(Event.taskMoved(from: taskPath(), to: taskPath()))
    }
    func test_event_availableWorktreeAdded_roundTrips() throws {
        try assertRoundTrips(Event.availableWorktreeAdded(repoId: uuidA, availableWorktreeFixture()))
    }
    func test_event_availableWorktreeRemoved_roundTrips() throws {
        try assertRoundTrips(Event.availableWorktreeRemoved(repoId: uuidA, id: uuidB))
    }
    func test_event_externalConvoDiscovered_roundTrips() throws {
        try assertRoundTrips(Event.externalConvoDiscovered(repoId: uuidA, externalConvoFixture()))
    }
    func test_event_externalConvoDismissed_roundTrips() throws {
        try assertRoundTrips(Event.externalConvoDismissed(at: externalConvoPath()))
    }
    func test_event_taskSelectionChanged_nil_roundTrips() throws {
        try assertRoundTrips(Event.taskSelectionChanged(nil))
    }
    func test_event_taskSelectionChanged_value_roundTrips() throws {
        try assertRoundTrips(Event.taskSelectionChanged(taskPath()))
    }
    func test_event_taskSpawned_roundTrips() throws {
        try assertRoundTrips(Event.taskSpawned(at: taskPath(), when: date))
    }
    func test_event_taskExited_roundTrips() throws {
        try assertRoundTrips(Event.taskExited(at: taskPath(), when: date, code: 0))
    }
    func test_event_settingsUpdated_roundTrips() throws {
        try assertRoundTrips(Event.settingsUpdated(settings()))
    }
}
