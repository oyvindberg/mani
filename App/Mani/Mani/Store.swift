import SwiftUI
import ManiCore
import ManiServer

// docs/architecture.md § "The store".
//
// Order is load-bearing: persist → apply → publish → dispatch remaining
// effects. If we crash between persist and apply, on restart the
// durable event replays through `apply` and we end up where we were.
// The publish step broadcasts each committed Event to the EventBus,
// which any connected mani-server WebSocket client subscribes to.

@MainActor
final class Store: ObservableObject {
    @Published private(set) var state: AppState
    let runner: EffectRunner
    // Owned here so Store is the single fan-out point for committed
    // events. The mani-server Server subscribes to this bus; the local
    // UI continues to read @Published state directly (no protocol
    // round-trip for the in-proc case).
    let eventBus: EventBus

    init(state: AppState, runner: EffectRunner) {
        self.state = state
        self.runner = runner
        self.eventBus = EventBus()
    }

    func dispatch(_ action: Action) async {
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
                let runner = self.runner
                _Concurrency.Task { [weak self] in
                    await runner.run(effect) { action in
                        guard let self else { return }
                        await self.dispatch(action)
                    }
                }
            }
        }
    }
}
