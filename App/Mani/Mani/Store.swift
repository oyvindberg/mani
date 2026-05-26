import SwiftUI
import ManiCore
import ManiServer

// docs/architecture.md § "The store".
//
// Two modes:
//
//   .local — owns the reducer/persistence/effects path. The
//     canonical-state runtime. ManiApp boots into this when no
//     MANI_SERVER_URL is set. Order is load-bearing: persist → apply →
//     publish → dispatch remaining effects. If we crash between
//     persist and apply, on restart the durable event replays through
//     `apply` and we end up where we were. The publish step
//     broadcasts each committed Event to the EventBus, which any
//     connected mani-server WebSocket client subscribes to.
//
//   .remote — no local runner, no reducer. State updates flow in
//     from a RemoteWSClient (helloAck snapshot + event frames).
//     dispatch and taskIO forward over WS. Activated when ManiApp.init
//     sees MANI_SERVER_URL — meant for "this is the client mac talking
//     to mani-server on the box that owns the agents."

@MainActor
final class Store: ObservableObject {
    enum Mode {
        case local(runner: EffectRunner, eventBus: EventBus)
        case remote(client: RemoteWSClient)
    }

    @Published private(set) var state: AppState
    let mode: Mode

    // Convenience accessors for local-mode-only call sites. Both nil
    // in remote mode — callers that need them (boot reconciliation,
    // snapshot compaction, terminateAll, embedded WS server) should
    // gate on these and skip when nil.
    var runner: EffectRunner? {
        if case .local(let r, _) = mode { return r } else { return nil }
    }
    var eventBus: EventBus? {
        if case .local(_, let b) = mode { return b } else { return nil }
    }

    init(state: AppState, mode: Mode) {
        self.state = state
        self.mode = mode

        if case .remote(let client) = mode {
            // Wire the WS client's state and event streams into our
            // @Published state + (no event bus locally — remote mode
            // doesn't republish; consumers go to the wire directly if
            // they need events).
            client.onStateUpdate = { [weak self] snapshot in
                _Concurrency.Task { @MainActor in self?.state = snapshot }
            }
        }
    }

    // PTY handle for a task. Local: looks up via EffectRunner. Remote:
    // returns a RemoteTaskIO that translates TaskIO calls into WS
    // frames. Either way the caller (renderer) doesn't have to know.
    func taskIO(for taskId: UUID) async -> TaskIO? {
        switch mode {
        case .local(let runner, _):
            return await runner.pty(taskId: taskId)
        case .remote(let client):
            return client.taskIO(for: taskId)
        }
    }

    func dispatch(_ action: Action) async {
        switch mode {
        case .remote(let client):
            await client.dispatch(action)
            return
        case .local(let runner, let eventBus):
            await dispatchLocal(action, runner: runner, eventBus: eventBus)
        }
    }

    private func dispatchLocal(
        _ action: Action,
        runner: EffectRunner,
        eventBus: EventBus
    ) async {
        let (events, effects) = reduce(state, action)

        // Step 1: durability boundary. Persist events before mutating in-memory state.
        for effect in effects {
            if case .persistEvents = effect {
                await runner.run(effect, dispatch: { _ in })
            }
        }

        // Step 2: apply
        for event in events { apply(&state, event) }

        // Step 2.5: broadcast to remote subscribers (mani-server WS).
        // Order matters: publish AFTER apply so a subscriber that races
        // a snapshot + event stream gets a consistent view (snapshot
        // already contains everything up to currentSeq at hello time;
        // the event with seq N+1 is applicable to that snapshot).
        for event in events {
            await eventBus.publish(event)
        }

        // Step 3: remaining effects, fire-and-forget on Tasks.
        for effect in effects {
            switch effect {
            case .persistEvents:
                continue
            case .writeSnapshot:
                let snapshot = state
                _Concurrency.Task { await runner.compact(snapshot) }
            case .spawn, .terminate, .createGitWorktree,
                 .fetchAndResetToDefault,
                 .removeGitWorktree, .deleteGitBranch,
                 .ensureGitIgnoreLocal,
                 .watchClaudeProjects, .userNotification:
                let runnerCapture = runner
                _Concurrency.Task { [weak self] in
                    await runnerCapture.run(effect) { action in
                        guard let self else { return }
                        await self.dispatch(action)
                    }
                }
            }
        }
    }
}
