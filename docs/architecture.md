# Architecture

## Mental model

Three concentric layers, each with stricter rules:

```
┌─────────────────────────────────────────────────────────┐
│ App (UI, AppKit/SwiftUI, macOS APIs, Sparkle, …)         │  swiftful, side-effecting
│   ┌─────────────────────────────────────────────────┐   │
│   │ EffectRunner (actor)                             │   │  the only place that does I/O
│   │   - posix_spawn, kill, git, fs, network         │   │
│   └─────────────────────────────────────────────────┘   │
│   ┌─────────────────────────────────────────────────┐   │
│   │ Store (@MainActor, @Published state)             │   │  the only stateful piece
│   │   dispatch(Action) → reduce → persist →           │   │
│   │   apply(events) → run(effects)                   │   │
│   └─────────────────────────────────────────────────┘   │
│     ┌───────────────────────────────────────────┐       │
│     │ ManiCore (this Swift Package)              │       │  PURE; Foundation-only
│     │   - data model (AppState, Project, …)      │       │
│     │   - reduce(state, action)                  │       │
│     │   - apply(&state, event)                   │       │
│     └───────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────────┘
```

`ManiCore` (this package) is a pure data-and-rules library. No I/O, no
AppKit, no SwiftUI, no FSEvents. Foundation only. Tests run from CLI in
under 10 seconds.

## Three types: Action, Event, Effect

```swift
// Sources/ManiCore/Action.swift
public enum Action {
    case createProject(name: String, color: String, rootDir: URL)
    // … see file for full list
}

// Sources/ManiCore/Event.swift
public enum Event: Codable, Equatable {
    case projectCreated(Project)
    // … see file for full list
}

// Sources/ManiCore/Effect.swift
public enum Effect {
    case persistEvents([Event])
    case spawn(at: JobPath, index: Int, ProcessSpec)
    case terminate(pid: Int32, escalateAfter: TimeInterval)
    // … see file for full list
}
```

**Why three not two:**

- `Action` is *intent*. May fail validation ("project doesn't exist"). Not
  durable. UI dispatches actions; system also produces actions in response
  to effect outcomes (e.g., `processStarted(pid: 12345)`).
- `Event` is *fact*. By the time it exists, validation has passed and the
  decision is committed. Events are the audit log; the on-disk
  `events.jsonl` is a stream of these.
- `Effect` is *I/O to do*. Side-effecting. May fail at the OS level. Should
  not be persisted — they're how we get *to* the next event, not what
  happened.

This separation lets `reduce` stay a pure function, lets the event log be
authoritative for replay, and isolates I/O risk into `EffectRunner`.

## The reducer

```swift
public func reduce(_ state: AppState, _ action: Action)
    -> (events: [Event], effects: [Effect])
```

Pure. Validates the action against current state. Produces the events that
will be applied and the effects that should be dispatched. **The reducer
itself emits the `.persistEvents([…])` effect** for any events it produces
— the store doesn't add it implicitly. This keeps "what gets persisted"
explicit and visible at the call site.

Implementation pattern:

```swift
case let .createProject(name, color, rootDir):
    let project = Project(
        id: UUID(), name: name, color: color, rootDir: rootDir,
        enabled: true, worktrees: [], createdAt: Date()
    )
    let event = Event.projectCreated(project)
    return ([event], [.persistEvents([event])])

case let .setProjectEnabled(id, enabled):
    guard let project = state.projects.first(where: { $0.id == id }) else {
        return ([], [])  // unknown project: silent no-op
    }
    let event = Event.projectEnabledChanged(id: id, enabled: enabled)
    var effects: [Effect] = [.persistEvents([event])]
    if !enabled {
        // cascade: collect terminate effects for every running pid in subtree
        for worktree in project.worktrees {
            for job in worktree.jobs {
                if let pid = job.primary.pid {
                    effects.append(.terminate(pid: pid, escalateAfter: 5))
                }
                // … same for auxiliary
            }
        }
    }
    return ([event], effects)
```

**Validation philosophy.** If an action is invalid (unknown ID, bad
transition), return `([], [])`. We do not throw errors out of `reduce`
because doing so makes the call site a try/catch swamp. Internal-only
"impossible" violations may use `assertionFailure` to surface bugs in
debug builds.

## The applier

```swift
public func apply(_ state: inout AppState, _ event: Event)
```

Pure mutation. Used by:
1. The live store, after persisting events from a reducer call.
2. The recovery code at startup, replaying events from `events.jsonl`.

**Same code path for both.** This is non-negotiable. If you find yourself
adding "if recovering then…" in `apply`, stop and rethink — the whole point
is that recovery is just replay.

## The store (lives in the app target, not `ManiCore`)

```swift
@MainActor
final class Store: ObservableObject {
    @Published private(set) var state: AppState
    private let runner: EffectRunner

    func dispatch(_ action: Action) async {
        let (events, effects) = reduce(state, action)

        // Step 1: durability boundary. Events are persisted before in-memory
        // state mutates, so a crash here is recoverable.
        if let persist = effects.first(where: { if case .persistEvents = $0 { true } else { false } }) {
            await runner.run(persist)
        }

        // Step 2: apply events to in-memory state. UI updates here.
        for event in events { apply(&state, event) }

        // Step 3: dispatch remaining effects async.
        for effect in effects {
            if case .persistEvents = effect { continue }
            Task { await runner.run(effect) { [weak self] action in
                await self?.dispatch(action)
            } }
        }
    }
}
```

Order is load-bearing: persist → apply → dispatch. If we crash between
steps 1 and 2, on restart the event will replay through `apply` and we
end up where we were. If we crash between 2 and 3, the event is durable
but the side effect didn't happen — recovery code reconciles by
zeroing out PIDs and marking running tasks `stopped`.

## The effect runner (lives in the app target)

```swift
actor EffectRunner {
    let processManager: ProcessManager
    let store: PersistenceStore     // events.jsonl, state.json, archive
    let notifier: SystemNotifier

    func run(_ effect: Effect, dispatch: @escaping (Action) async -> Void = { _ in }) async {
        switch effect {
        case .persistEvents(let events):
            try? await store.appendEvents(events)
        case .writeSnapshot:
            try? await store.compact()
        case .spawn(let path, let idx, let spec):
            do {
                let pid = try await processManager.spawn(spec)
                await dispatch(.processStarted(at: path, index: idx, pid: pid))
            } catch {
                await dispatch(.processExited(at: path, index: idx, code: -1))
            }
        case .terminate(let pid, let escalate):
            await processManager.terminate(pid: pid, escalateAfter: escalate)
        // …
        }
    }
}
```

Rules:
- Only `EffectRunner` calls `posix_spawn`, `git`, FS APIs, network APIs.
- Effects dispatch new actions back to the store via the closure parameter.
  This is how the loop closes: `Action.spawn → Effect.spawn → process
  starts → Action.processStarted → Event.processStarted → state updates`.
- Effects must be retry-tolerant where it matters. `persistEvents` retries
  on transient I/O failures; `spawn` does not retry (a failed spawn becomes
  a `processExited` action).

## Recovery

```swift
func bootstrap() async throws -> Store {
    var state = (try? PersistenceStore.readState()) ?? AppState.empty
    let pendingEvents = try PersistenceStore.readEventLog()
    for e in pendingEvents { apply(&state, e) }

    // Reconcile reality vs state: any task with a pid is suspect — the
    // process is dead because we just started up.
    state = reconcileAfterCrash(state)

    let store = Store(state: state, runner: EffectRunner(...))
    await store.dispatch(.compactRequested)  // fresh snapshot, truncate event log
    return store
}
```

The reconciliation pass:
- Every `ProcessSpec.pid` → `nil`.
- Every `Job.status == .running` → `.stopped`.
- Verify `Worktree.path` still exists. If not, mark the worktree
  `missing` (model field — TBD; v0.1 may model this as a flag on
  `Worktree` or as a separate set of paths).

Auto-restart is **safelist-only**. Re-running arbitrary commands at startup
is a footgun. The safelist is:
- `/usr/local/bin/claude`, `/opt/homebrew/bin/claude`, etc. (resolve via
  `PATH`)
- A bare shell from `Job.kind == .shell` with no captured user command
  beyond the shell itself

If a task's primary command isn't on the safelist, surface a "Restart?"
button instead of auto-running.

## Testability

The reducer is pure — testing is `(state, action) → expectedEvents,
expectedEffects`. No mocks, no async. See `Tests/ManiCoreTests/ReducerTests.swift`
for the pattern.

Recommended additions when you grow the reducer:

- **Property-based tests** over action streams. For each action stream,
  assert: applying the resulting events to fresh state and to the running
  state produces the same result. (Idempotence of replay.)
- **Round-trip tests for events.** `event → encode → decode → apply` should
  match `event → apply`. Catches `Codable` regressions.
- **Effect ordering tests.** Where order matters (e.g., `persistEvents`
  before `terminate`), assert the order in the test.

## File layout in `ManiCore`

```
Sources/ManiCore/
  Model/                  # data only, all Codable
  Paths.swift             # WorktreePath, JobPath
  Action.swift            # one enum
  Event.swift             # one enum, Codable
  Effect.swift            # one enum
  Reducer.swift           # reduce + apply
```

Don't add an `extensions/` directory or scatter helpers. Don't add a
namespace prefix; the module name `ManiCore` is enough.
