import Foundation

// Wire-format Codable for Action. See WireFormat.swift for the
// envelope shape. Action wasn't Codable before this — it's only sent
// across the wire by remote clients; the local UI dispatches it
// in-process.

extension Action: Codable {

    public func encode(to encoder: Encoder) throws {
        switch self {
        // MARK: Repo
        case let .createRepo(name, color, rootDir):
            try encodeWireEnvelope(kind: "createRepo", payload: [
                "name": AnyEncodable(name),
                "color": AnyEncodable(color),
                "rootDir": AnyEncodable(rootDir),
            ], to: encoder)
        case let .renameRepo(id, name):
            try encodeWireEnvelope(kind: "renameRepo", payload: [
                "id": AnyEncodable(id),
                "name": AnyEncodable(name),
            ], to: encoder)
        case let .setRepoEnabled(id, enabled):
            try encodeWireEnvelope(kind: "setRepoEnabled", payload: [
                "id": AnyEncodable(id),
                "enabled": AnyEncodable(enabled),
            ], to: encoder)
        case let .setRepoColor(id, color):
            try encodeWireEnvelope(kind: "setRepoColor", payload: [
                "id": AnyEncodable(id),
                "color": AnyEncodable(color),
            ], to: encoder)
        case let .setRepoClaudeInvocation(id, invocation):
            try encodeWireEnvelope(kind: "setRepoClaudeInvocation", payload: [
                "id": AnyEncodable(id),
                "invocation": AnyEncodable(invocation),
            ], to: encoder)
        case let .setRepoRootDir(at):
            try encodeWireEnvelope(kind: "setRepoRootDir", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .deleteRepo(id):
            try encodeWireEnvelope(kind: "deleteRepo", payload: [
                "id": AnyEncodable(id),
            ], to: encoder)
        case let .setRepoWorktreeMode(id, mode):
            try encodeWireEnvelope(kind: "setRepoWorktreeMode", payload: [
                "id": AnyEncodable(id),
                "mode": AnyEncodable(mode),
            ], to: encoder)
        case let .setRepoManagedWorktreesNamespace(id, namespace):
            try encodeWireEnvelope(kind: "setRepoManagedWorktreesNamespace", payload: [
                "id": AnyEncodable(id),
                "namespace": AnyEncodable(namespace),
            ], to: encoder)

        // MARK: Project
        case let .createProject(repoId, name, workspace):
            try encodeWireEnvelope(kind: "createProject", payload: [
                "repoId": AnyEncodable(repoId),
                "name": AnyEncodable(name),
                "workspace": AnyEncodable(workspace),
            ], to: encoder)
        case let .renameProject(at, name):
            try encodeWireEnvelope(kind: "renameProject", payload: [
                "at": AnyEncodable(at),
                "name": AnyEncodable(name),
            ], to: encoder)
        case let .archiveProject(at):
            try encodeWireEnvelope(kind: "archiveProject", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .unarchiveProject(at):
            try encodeWireEnvelope(kind: "unarchiveProject", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .markProjectWorkspaceMissing(at):
            try encodeWireEnvelope(kind: "markProjectWorkspaceMissing", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .deleteProject(at):
            try encodeWireEnvelope(kind: "deleteProject", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .finishProject(at, cleanup):
            try encodeWireEnvelope(kind: "finishProject", payload: [
                "at": AnyEncodable(at),
                "cleanup": AnyEncodable(cleanup),
            ], to: encoder)

        // MARK: Task
        case let .createTask(at, name, kind, spec, autoSelect):
            try encodeWireEnvelope(kind: "createTask", payload: [
                "at": AnyEncodable(at),
                "name": AnyEncodable(name),
                "kind": AnyEncodable(kind),
                "spec": AnyEncodable(spec),
                "autoSelect": AnyEncodable(autoSelect),
            ], to: encoder)
        case let .setTaskEnabled(at, enabled):
            try encodeWireEnvelope(kind: "setTaskEnabled", payload: [
                "at": AnyEncodable(at),
                "enabled": AnyEncodable(enabled),
            ], to: encoder)
        case let .renameTask(at, name):
            try encodeWireEnvelope(kind: "renameTask", payload: [
                "at": AnyEncodable(at),
                "name": AnyEncodable(name),
            ], to: encoder)
        case let .deleteTask(at):
            try encodeWireEnvelope(kind: "deleteTask", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .completeTask(at):
            try encodeWireEnvelope(kind: "completeTask", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .linkClaudeSession(at, sessionId):
            try encodeWireEnvelope(kind: "linkClaudeSession", payload: [
                "at": AnyEncodable(at),
                "sessionId": AnyEncodable(sessionId),
            ], to: encoder)
        case let .bumpUnread(at, by):
            try encodeWireEnvelope(kind: "bumpUnread", payload: [
                "at": AnyEncodable(at),
                "by": AnyEncodable(by),
            ], to: encoder)
        case let .markRead(at):
            try encodeWireEnvelope(kind: "markRead", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .restartTask(at):
            try encodeWireEnvelope(kind: "restartTask", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .setTaskSpec(at, spec):
            try encodeWireEnvelope(kind: "setTaskSpec", payload: [
                "at": AnyEncodable(at),
                "spec": AnyEncodable(spec),
            ], to: encoder)
        case let .moveTask(from, to):
            try encodeWireEnvelope(kind: "moveTask", payload: [
                "from": AnyEncodable(from),
                "to": AnyEncodable(to),
            ], to: encoder)

        // MARK: Available worktrees
        case let .removeAvailableWorktree(repoId, id):
            try encodeWireEnvelope(kind: "removeAvailableWorktree", payload: [
                "repoId": AnyEncodable(repoId),
                "id": AnyEncodable(id),
            ], to: encoder)
        case let .addAvailableWorktree(repoId, path, kind):
            try encodeWireEnvelope(kind: "addAvailableWorktree", payload: [
                "repoId": AnyEncodable(repoId),
                "path": AnyEncodable(path),
                "kind": AnyEncodable(kind),
            ], to: encoder)

        // MARK: External convos
        case let .discoverExternalConvo(repoId, sessionId, cwd):
            try encodeWireEnvelope(kind: "discoverExternalConvo", payload: [
                "repoId": AnyEncodable(repoId),
                "sessionId": AnyEncodable(sessionId),
                "cwd": AnyEncodable(cwd),
            ], to: encoder)
        case let .dismissExternalConvo(at):
            try encodeWireEnvelope(kind: "dismissExternalConvo", payload: [
                "at": AnyEncodable(at),
            ], to: encoder)
        case let .adoptExternalConvo(at, into, name):
            try encodeWireEnvelope(kind: "adoptExternalConvo", payload: [
                "at": AnyEncodable(at),
                "into": AnyEncodable(into),
                "name": AnyEncodable(name),
            ], to: encoder)

        // MARK: Selection
        case let .selectTask(at):
            try encodeWireEnvelope(kind: "selectTask", payload: [
                "at": AnyEncodable(at),
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
        case let .updateSettings(settings):
            try encodeWireEnvelope(kind: "updateSettings", payload: [
                "settings": AnyEncodable(settings),
            ], to: encoder)
        }
    }

    public init(from decoder: Decoder) throws {
        let (kind, p) = try decodeWireEnvelope(from: decoder)
        switch kind {
        // MARK: Repo
        case "createRepo":
            self = .createRepo(
                name: try p.decode(String.self, forKey: .name),
                color: try p.decode(String.self, forKey: .color),
                rootDir: try p.decode(URL.self, forKey: .rootDir)
            )
        case "renameRepo":
            self = .renameRepo(
                id: try p.decode(UUID.self, forKey: .id),
                name: try p.decode(String.self, forKey: .name)
            )
        case "setRepoEnabled":
            self = .setRepoEnabled(
                id: try p.decode(UUID.self, forKey: .id),
                enabled: try p.decode(Bool.self, forKey: .enabled)
            )
        case "setRepoColor":
            self = .setRepoColor(
                id: try p.decode(UUID.self, forKey: .id),
                color: try p.decode(String.self, forKey: .color)
            )
        case "setRepoClaudeInvocation":
            self = .setRepoClaudeInvocation(
                id: try p.decode(UUID.self, forKey: .id),
                invocation: try p.decodeIfPresent(String.self, forKey: .invocation)
            )
        case "setRepoRootDir":
            self = .setRepoRootDir(
                at: try p.decode(ProjectPath.self, forKey: .at)
            )
        case "deleteRepo":
            self = .deleteRepo(
                id: try p.decode(UUID.self, forKey: .id)
            )
        case "setRepoWorktreeMode":
            self = .setRepoWorktreeMode(
                id: try p.decode(UUID.self, forKey: .id),
                mode: try p.decode(WorktreeMode.self, forKey: .mode)
            )
        case "setRepoManagedWorktreesNamespace":
            self = .setRepoManagedWorktreesNamespace(
                id: try p.decode(UUID.self, forKey: .id),
                namespace: try p.decodeIfPresent(String.self, forKey: .namespace)
            )

        // MARK: Project
        case "createProject":
            self = .createProject(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                name: try p.decode(String.self, forKey: .name),
                workspace: try p.decode(Workspace.self, forKey: .workspace)
            )
        case "renameProject":
            self = .renameProject(
                at: try p.decode(ProjectPath.self, forKey: .at),
                name: try p.decode(String.self, forKey: .name)
            )
        case "archiveProject":
            self = .archiveProject(at: try p.decode(ProjectPath.self, forKey: .at))
        case "unarchiveProject":
            self = .unarchiveProject(at: try p.decode(ProjectPath.self, forKey: .at))
        case "markProjectWorkspaceMissing":
            self = .markProjectWorkspaceMissing(at: try p.decode(ProjectPath.self, forKey: .at))
        case "deleteProject":
            self = .deleteProject(at: try p.decode(ProjectPath.self, forKey: .at))
        case "finishProject":
            self = .finishProject(
                at: try p.decode(ProjectPath.self, forKey: .at),
                cleanup: try p.decode(FinishCleanup.self, forKey: .cleanup)
            )

        // MARK: Task
        case "createTask":
            self = .createTask(
                at: try p.decode(ProjectPath.self, forKey: .at),
                name: try p.decode(String.self, forKey: .name),
                kind: try p.decode(TaskKind.self, forKey: .kind),
                spec: try p.decode(ProcessSpec.self, forKey: .spec),
                autoSelect: try p.decode(Bool.self, forKey: .autoSelect)
            )
        case "setTaskEnabled":
            self = .setTaskEnabled(
                at: try p.decode(TaskPath.self, forKey: .at),
                enabled: try p.decode(Bool.self, forKey: .enabled)
            )
        case "renameTask":
            self = .renameTask(
                at: try p.decode(TaskPath.self, forKey: .at),
                name: try p.decode(String.self, forKey: .name)
            )
        case "deleteTask":
            self = .deleteTask(at: try p.decode(TaskPath.self, forKey: .at))
        case "completeTask":
            self = .completeTask(at: try p.decode(TaskPath.self, forKey: .at))
        case "linkClaudeSession":
            self = .linkClaudeSession(
                at: try p.decode(TaskPath.self, forKey: .at),
                sessionId: try p.decode(String.self, forKey: .sessionId)
            )
        case "bumpUnread":
            self = .bumpUnread(
                at: try p.decode(TaskPath.self, forKey: .at),
                by: try p.decode(Int.self, forKey: .by)
            )
        case "markRead":
            self = .markRead(at: try p.decode(TaskPath.self, forKey: .at))
        case "restartTask":
            self = .restartTask(at: try p.decode(TaskPath.self, forKey: .at))
        case "setTaskSpec":
            self = .setTaskSpec(
                at: try p.decode(TaskPath.self, forKey: .at),
                spec: try p.decode(ProcessSpec.self, forKey: .spec)
            )
        case "moveTask":
            self = .moveTask(
                from: try p.decode(TaskPath.self, forKey: .from),
                to: try p.decode(ProjectPath.self, forKey: .to)
            )

        // MARK: Available worktrees
        case "removeAvailableWorktree":
            self = .removeAvailableWorktree(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                id: try p.decode(UUID.self, forKey: .id)
            )
        case "addAvailableWorktree":
            self = .addAvailableWorktree(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                path: try p.decode(URL.self, forKey: .path),
                kind: try p.decode(WorkspaceKind.self, forKey: .kind)
            )

        // MARK: External convos
        case "discoverExternalConvo":
            self = .discoverExternalConvo(
                repoId: try p.decode(UUID.self, forKey: .repoId),
                sessionId: try p.decode(String.self, forKey: .sessionId),
                cwd: try p.decode(URL.self, forKey: .cwd)
            )
        case "dismissExternalConvo":
            self = .dismissExternalConvo(at: try p.decode(ExternalConvoPath.self, forKey: .at))
        case "adoptExternalConvo":
            self = .adoptExternalConvo(
                at: try p.decode(ExternalConvoPath.self, forKey: .at),
                into: try p.decode(ProjectPath.self, forKey: .into),
                name: try p.decode(String.self, forKey: .name)
            )

        // MARK: Selection
        case "selectTask":
            self = .selectTask(at: try p.decodeIfPresent(TaskPath.self, forKey: .at))

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
        case "updateSettings":
            self = .updateSettings(try p.decode(Settings.self, forKey: .settings))

        default:
            throw wireUnknownKind(kind, type: "Action")
        }
    }
}
