import SwiftUI
import ManiCore

// docs/architecture.md § "The store".
//
// Order is load-bearing: persist → apply → dispatch remaining effects.
// If we crash between persist and apply, on restart the durable event
// replays through `apply` and we end up where we were.

@MainActor
final class Store: ObservableObject {
    @Published private(set) var state: AppState
    let runner: EffectRunner

    init(state: AppState, runner: EffectRunner) {
        self.state = state
        self.runner = runner
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
