import Foundation
import ManiCore

// The only place I/O happens. Owns the live ManagedPTY instances keyed by
// JobPath, drives PersistenceStore, and dispatches actions back to the
// Store via the closure passed in.
//
// docs/architecture.md § "The effect runner".

actor EffectRunner {
    private let persistence: PersistenceStore
    private var ptys: [JobPath: ManagedPTY] = [:]

    init(persistence: PersistenceStore) {
        self.persistence = persistence
    }

    func pty(for path: JobPath) -> ManagedPTY? {
        ptys[path]
    }

    func run(_ effect: Effect, dispatch: @escaping (Action) async -> Void) async {
        switch effect {

        case let .persistEvents(events):
            for event in events {
                try? persistence.appendEvent(event)
            }

        case .writeSnapshot:
            // The runner doesn't know AppState; the Store hands it to us
            // explicitly via `compact(_:)`. Treating .writeSnapshot as a
            // no-op here keeps the effect→runner protocol clean.
            break

        case let .spawn(path, index, spec):
            do {
                var env = ProcessInfo.processInfo.environment
                for (k, v) in spec.env { env[k] = v }
                env["TERM"] = "xterm-256color"
                let pty = try ManagedPTY(
                    executable: spec.command,
                    args: spec.args,
                    env: env,
                    rawMode: false
                )
                ptys[path] = pty
                pty.onExit = { code in
                    Task { await dispatch(.processExited(at: path, index: index, code: code)) }
                }
                await dispatch(.processStarted(at: path, index: index, pid: pty.pid))
            } catch {
                await dispatch(.processExited(at: path, index: index, code: -1))
            }

        case let .terminate(pid, escalate):
            // Find the PTY by pid. ManagedPTY.terminate blocks until the child
            // has been reaped, so wrap in Task.detached to avoid wedging the actor.
            for pty in ptys.values where pty.pid == pid {
                let captured = pty
                Task.detached { captured.terminate(escalateAfter: escalate) }
                break
            }

        case let .userNotification(title, body):
            NotificationService.shared.post(title: title, body: body)

        case .createGitWorktree, .archive, .watchClaudeProjects:
            // Not implemented yet; documented in docs/architecture.md.
            break
        }
    }

    func compact(_ state: AppState) async {
        try? persistence.compact(state)
    }

    func recover() throws -> AppState {
        try persistence.recover().state
    }
}
