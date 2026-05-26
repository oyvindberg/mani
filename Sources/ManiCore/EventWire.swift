import Foundation

// Wire-format Codable for Event. See WireFormat.swift for the envelope
// shape. This replaces the previous auto-synthesized Codable, which
// produced `{"caseName": {"_0": ...}}` — Swift-idiomatic but a poor
// shape for non-Swift consumers and for the v0.2 wire protocol.
//
// Migration: existing events.jsonl files (written with the old form)
// will fail to decode under the new format. PersistenceStore's
// readEvents already tolerates per-line decode failures, so old entries
// are skipped on first boot after this change. State.json is unaffected
// because it doesn't embed Event values.

extension Event {

    public func encode(to encoder: Encoder) throws {
        switch self {
        // MARK: Repo
        case let .repoCreated(repo):
            try encodeWireEnvelope(kind: "repoCreated", payload: [
                "repo": AnyEncodable(repo),
            ], to: encoder)
        case let .repoRenamed(id, name):
            try encodeWireEnvelope(kind: "repoRenamed", payload: [
                "id": AnyEncodable(id),
                "name": AnyEncodable(name),
            ], to: encoder)
        case let .repoEnabledChanged(id, enabled):
            try encodeWireEnvelope(kind: "repoEnabledChanged", payload: [
                "id": AnyEncodable(id),
                "enabled": AnyEncodable(enabled),
            ], to: encoder)
        case let .repoColorChanged(id, color):
            try encodeWireEnvelope(kind: "repoColorChanged", payload: [
                "id": AnyEncodable(id),
                "color": AnyEncodable(color),
            ], to: encoder)
        case let .repoClaudeInvocationChanged(id, invocation):
            try encodeWireEnvelope(kind: "repoClaudeInvocationChanged", payload: [
                "id": AnyEncodable(id),
                "invocation": AnyEncodable(invocation),
            ], to: encoder)
        case let .repoRootDirChanged(id, rootDir):
            try encodeWireEnvelope(kind: "repoRootDirChanged", payload: [
                "id": AnyEncodable(id),
                "rootDir": AnyEncodable(rootDir),
            ], to: encoder)
        case let .repoDeleted(id):
            try encodeWireEnvelope(kind: "repoDeleted", payload: [
                "id": AnyEncodable(id),
            ], to: encoder)
        case let .repoWorktreeModeChanged(id, mode):
            try encodeWireEnvelope(kind: "repoWorktreeModeChanged", payload: [
                "id": AnyEncodable(id),
                "mode": AnyEncodable(mode),
            ], to: encoder)
        case let .repoManagedWorktreesNamespaceChanged(id, namespace):
            try encodeWireEnvelope(kind: "repoManagedWorktreesNamespaceChanged", payload: [
                "id": AnyEncodable(id),
                "namespace": AnyEncodable(namespace),
            ], to: encoder)

        // MARK: Project
        case let .projectCreated(repoId, project):
            try encodeWireEnvelope(kind: "projectCreated", payload: [
                "repoId": AnyEncodable(repoId),
                "project": AnyEncodable(project),
            ], to: encoder)
        case let .projectRenamed(at, name):
            try encodeWireEnvelope(kind: "projectRenamed", payload: [
                "at": AnyEncodable(at),
                "name": AnyEncodable(name),
            ], to: encoder)
        case let .projectArchived(at, when):
            try encodeWireEnvelope(kind: "projectArchived", payload: [
                "at": AnyEncodable(at),
                "when": AnyEncodable(when),
            ], to: encoder)
        case let .projectUnarchived(at):
            try encodeWireEnvelope(kind: "projectUnarchived", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .projectWorkspaceMarkedMissing(at):
            try encodeWireEnvelope(kind: "projectWorkspaceMarkedMissing", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .projectDeleted(at):
            try encodeWireEnvelope(kind: "projectDeleted", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)

        // MARK: Task
        case let .taskCreated(at, task):
            try encodeWireEnvelope(kind: "taskCreated", payload: [
                "at": AnyEncodable(at),
                "task": AnyEncodable(task),
            ], to: encoder)
        case let .taskEnabledChanged(at, enabled):
            try encodeWireEnvelope(kind: "taskEnabledChanged", payload: [
                "at": AnyEncodable(at),
                "enabled": AnyEncodable(enabled),
            ], to: encoder)
        case let .taskCompleted(at, completedAt):
            try encodeWireEnvelope(kind: "taskCompleted", payload: [
                "at": AnyEncodable(at),
                "completedAt": AnyEncodable(completedAt),
            ], to: encoder)
        case let .taskUnreadBumped(at, by):
            try encodeWireEnvelope(kind: "taskUnreadBumped", payload: [
                "at": AnyEncodable(at),
                "by": AnyEncodable(by),
            ], to: encoder)
        case let .taskRead(at):
            try encodeWireEnvelope(kind: "taskRead", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .taskRenamed(at, name):
            try encodeWireEnvelope(kind: "taskRenamed", payload: [
                "at": AnyEncodable(at),
                "name": AnyEncodable(name),
            ], to: encoder)
        case let .taskDeleted(at):
            try encodeWireEnvelope(kind: "taskDeleted", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .taskSpecChanged(at, spec):
            try encodeWireEnvelope(kind: "taskSpecChanged", payload: [
                "at": AnyEncodable(at),
                "spec": AnyEncodable(spec),
            ], to: encoder)
        case let .claudeSessionLinked(at, sessionId):
            try encodeWireEnvelope(kind: "claudeSessionLinked", payload: [
                "at": AnyEncodable(at),
                "sessionId": AnyEncodable(sessionId),
            ], to: encoder)
        case let .taskMoved(from, to):
            try encodeWireEnvelope(kind: "taskMoved", payload: [
                "from": AnyEncodable(from),
                "to": AnyEncodable(to),
            ], to: encoder)

        // MARK: Available worktrees
        case let .availableWorktreeAdded(repoId, worktree):
            try encodeWireEnvelope(kind: "availableWorktreeAdded", payload: [
                "repoId": AnyEncodable(repoId),
                "availableWorktree": AnyEncodable(worktree),
            ], to: encoder)
        case let .availableWorktreeRemoved(repoId, id):
            try encodeWireEnvelope(kind: "availableWorktreeRemoved", payload: [
                "repoId": AnyEncodable(repoId),
                "id": AnyEncodable(id),
            ], to: encoder)

        // MARK: External convos
        case let .externalConvoDiscovered(repoId, convo):
            try encodeWireEnvelope(kind: "externalConvoDiscovered", payload: [
                "repoId": AnyEncodable(repoId),
                "externalConvo": AnyEncodable(convo),
            ], to: encoder)
        case let .externalConvoDismissed(at):
            try encodeWireEnvelope(kind: "externalConvoDismissed", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)

        // MARK: Selection
        case let .taskSelectionChanged(path):
            try encodeWireEnvelope(kind: "taskSelectionChanged", payload: [
                "taskPath": AnyEncodable(path),
            ], to: encoder)

        // MARK: Runtime
        case let .taskSpawned(at, when):
            try encodeWireEnvelope(kind: "taskSpawned", payload: [
                "at": AnyEncodable(at),
                "when": AnyEncodable(when),
            ], to: encoder)
        case let .taskExited(at, when, code):
            try encodeWireEnvelope(kind: "taskExited", payload: [
                "at": AnyEncodable(at),
                "when": AnyEncodable(when),
                "code": AnyEncodable(code),
            ], to: encoder)

        // MARK: Settings
        case let .settingsUpdated(settings):
            try encodeWireEnvelope(kind: "settingsUpdated", payload: [
                "settings": AnyEncodable(settings),
            ], to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let (kind, p) = try decodeWireEnvelope(from: decoder)
        switch kind {
        // MARK: Repo
        case "repoCreated":
            self = .repoCreated(try p.decode(Repo.self, forKey: .repo))
        case "repoRenamed":
            self = .repoRenamed(
                id: try p.decode(UUID.self, forKey: .id),
                name: try p.decode(String.self, forKey: .name)
            )
        case "repoEnabledChanged":
            self = .repoEnabledChanged(
                id: try p.decode(UUID.self, forKey: .id),
                enabled: try p.decode(Bool.self, forKey: .enabled)
            )
        case "repoColorChanged":
            self = .repoColorChanged(
                id: try p.decode(UUID.self, forKey: .id),
                color: try p.decode(String.self, forKey: .color)
            )
        case "repoClaudeInvocationChanged":
            self = .repoClaudeInvocationChanged(
                id: try p.decode(UUID.self, forKey: .id),
                invocation: try p.decodeIfPresent(String.self, forKey: .invocation)
            )
        case "repoRootDirChanged":
            self = .repoRootDirChanged(
                id: try p.decode(UUID.self, forKey: .id),
                rootDir: try p.decode(URL.self, forKey: .rootDir)
            )
        case "repoDeleted":
            self = .repoDeleted(id: try p.decode(UUID.self, forKey: .id))
        case "repoWorktreeModeChanged":
            self = .repoWorktreeModeChanged(
                id: try p.decode(UUID.self, forKey: .id),
                mode: try p.decode(WorktreeMode.self, forKey: .mode)
            )
        case "repoManagedWorktreesNamespaceChanged":
            self = .repoManagedWorktreesNamespaceChanged(
                id: try p.decode(UUID.self, forKey: .id),
                namespace: try p.decodeIfPresent(String.self, forKey: .namespace)
            )

        // MARK: Project
        case "projectCreated":
            self = .projectCreated(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                try p.decode(Project.self, forKey: .project)
            )
        case "projectRenamed":
            self = .projectRenamed(
                at: try p.decode(ProjectPath.self, forKey: .at),
                name: try p.decode(String.self, forKey: .name)
            )
        case "projectArchived":
            self = .projectArchived(
                at: try p.decode(ProjectPath.self, forKey: .at),
                when: try p.decode(Date.self, forKey: .when)
            )
        case "projectUnarchived":
            self = .projectUnarchived(at: try p.decode(ProjectPath.self, forKey: .at))
        case "projectWorkspaceMarkedMissing":
            self = .projectWorkspaceMarkedMissing(at: try p.decode(ProjectPath.self, forKey: .at))
        case "projectDeleted":
            self = .projectDeleted(at: try p.decode(ProjectPath.self, forKey: .at))

        // MARK: Task
        case "taskCreated":
            self = .taskCreated(
                at: try p.decode(ProjectPath.self, forKey: .at),
                try p.decode(Task.self, forKey: .task)
            )
        case "taskEnabledChanged":
            self = .taskEnabledChanged(
                at: try p.decode(TaskPath.self, forKey: .at),
                enabled: try p.decode(Bool.self, forKey: .enabled)
            )
        case "taskCompleted":
            self = .taskCompleted(
                at: try p.decode(TaskPath.self, forKey: .at),
                completedAt: try p.decode(Date.self, forKey: .completedAt)
            )
        case "taskUnreadBumped":
            self = .taskUnreadBumped(
                at: try p.decode(TaskPath.self, forKey: .at),
                by: try p.decode(Int.self, forKey: .by)
            )
        case "taskRead":
            self = .taskRead(at: try p.decode(TaskPath.self, forKey: .at))
        case "taskRenamed":
            self = .taskRenamed(
                at: try p.decode(TaskPath.self, forKey: .at),
                name: try p.decode(String.self, forKey: .name)
            )
        case "taskDeleted":
            self = .taskDeleted(at: try p.decode(TaskPath.self, forKey: .at))
        case "taskSpecChanged":
            self = .taskSpecChanged(
                at: try p.decode(TaskPath.self, forKey: .at),
                spec: try p.decode(ProcessSpec.self, forKey: .spec)
            )
        case "claudeSessionLinked":
            self = .claudeSessionLinked(
                at: try p.decode(TaskPath.self, forKey: .at),
                sessionId: try p.decode(String.self, forKey: .sessionId)
            )
        case "taskMoved":
            self = .taskMoved(
                from: try p.decode(TaskPath.self, forKey: .from),
                to: try p.decode(TaskPath.self, forKey: .to)
            )

        // MARK: Available worktrees
        case "availableWorktreeAdded":
            self = .availableWorktreeAdded(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                try p.decode(AvailableWorktree.self, forKey: .availableWorktree)
            )
        case "availableWorktreeRemoved":
            self = .availableWorktreeRemoved(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                id: try p.decode(UUID.self, forKey: .id)
            )

        // MARK: External convos
        case "externalConvoDiscovered":
            self = .externalConvoDiscovered(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                try p.decode(ExternalConvo.self, forKey: .externalConvo)
            )
        case "externalConvoDismissed":
            self = .externalConvoDismissed(at: try p.decode(ExternalConvoPath.self, forKey: .at))

        // MARK: Selection
        case "taskSelectionChanged":
            self = .taskSelectionChanged(try p.decodeIfPresent(TaskPath.self, forKey: .taskPath))

        // MARK: Runtime
        case "taskSpawned":
            self = .taskSpawned(
                at: try p.decode(TaskPath.self, forKey: .at),
                when: try p.decode(Date.self, forKey: .when)
            )
        case "taskExited":
            self = .taskExited(
                at: try p.decode(TaskPath.self, forKey: .at),
                when: try p.decode(Date.self, forKey: .when),
                code: try p.decode(Int32.self, forKey: .code)
            )

        // MARK: Settings
        case "settingsUpdated":
            self = .settingsUpdated(try p.decode(Settings.self, forKey: .settings))

        default:
            throw wireUnknownKind(kind, type: "Event")
        }
    }
}
