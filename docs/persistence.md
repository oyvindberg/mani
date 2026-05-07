# Persistence

Goal: survive a hard crash with **zero work lost beyond the last in-flight
event**, and reconstruct the project/worktree/task tree exactly.

The store is `~/Library/Application Support/Mani/`. Nothing about Mani goes
into user repos.

## Layout

```
~/Library/Application Support/Mani/
├── state.json                  current full snapshot
├── state.json.bak              previous snapshot (used if state.json corrupt)
├── events.jsonl                events since the last snapshot
├── tasks/
│   └── <task-id>/
│       ├── meta.json           task-local data not in state.json
│       ├── scrollback.log      live PTY output, ring-buffer capped
│       └── archive/
│           └── 2026-05-07T10-15-23Z/
│               ├── meta.json
│               └── scrollback.log.zst
├── notifications.jsonl         append-only stream for the UI
└── logs/
    └── mani.log                app diagnostics (rotating)
```

## Three concurrent tiers

### Tier 1 — continuous (scrollback)

Each task's PTY output is tee'd to `tasks/<id>/scrollback.log`. The writer
is a buffered `FileHandle` that flushes every **250ms or 64KB**, whichever
comes first. On task completion or app quit, force-flush.

The log is **ring-buffered to a configurable cap** (default 32 MB per task,
in `Settings.scrollbackCapBytes`). When the cap is reached, the oldest
chunk is rotated out — implement either as in-place truncation with a
header offset, or as N rotated files (`scrollback.0`, `scrollback.1`, …).
Either works; pick the simpler one to reason about under crash.

### Tier 2 — incremental (events)

`events.jsonl` is append-only. One JSON object per line:

```jsonl
{"t":"2026-05-07T14:22:11.412Z","kind":"projectCreated","payload":{...}}
{"t":"2026-05-07T14:22:14.880Z","kind":"processStarted","payload":{"taskId":"...","pid":48211}}
{"t":"2026-05-07T14:22:30.001Z","kind":"claudeSessionLinked","payload":{"taskId":"...","sessionId":"..."}}
```

Writes are durable: append → `fsync(fd)` → return. This is the **durability
boundary** the store relies on. Don't batch fsyncs; per-event durability
is the contract.

Performance: at the rates a single-user dev tool produces events (a few
per second at peak), per-event fsync on an SSD is fine. If profiling shows
otherwise, batch within a single dispatch call (one fsync after a multi-event
mutation), but never across mutations.

### Tier 3 — periodic (snapshot)

Every **30 seconds** *or* on a significant event (project added, task
completed, app entering background), write the whole `AppState` to disk:

```
1. encode AppState → state.json.new
2. fsync(state.json.new)
3. rename state.json → state.json.bak
4. rename state.json.new → state.json
5. truncate events.jsonl to zero length
```

Steps 3–5 must be sequential, but each individual `rename` is atomic on
APFS/HFS+. If we crash:
- Between 1–3: state.json unchanged. Recovery reads it.
- Between 3–4: state.json missing, state.json.bak is current. Recovery
  reads .bak and renames it back.
- Between 4–5: state.json is current, events.jsonl has stale events.
  Recovery reads state.json and replays events newer than its mtime
  (which gives an empty replay because the snapshot already contains them,
  but it's a no-op).

Don't truncate events.jsonl until *after* state.json is fully renamed.

## Recovery flow on launch

```
1. Try state.json. If JSON parse succeeds, that's the base state.
   If not, fall back to state.json.bak.
   If both corrupt: AppState.empty + log a recovery error to surface in UI.

2. Read events.jsonl. For each event with timestamp > state.json mtime:
   apply(&state, event)

3. Reconcile:
   - For every Job.primary and Job.auxiliary, set pid = nil
   - For every Job with status == .running, set status = .stopped
   - For every Worktree, check FileManager.fileExists(atPath: path):
     if not, mark missing (TBD: model field)

4. Dispatch a fresh full snapshot (Tier 3). This makes the rest of the
   session start from a clean baseline; the next crash recovers from
   here, not from the pre-recovery state.

5. Surface "needs restart?" affordances for each stopped task whose
   primary command is on the safelist.
```

## Task lifecycle and archive

When a task completes (via `completeJob` action, `processExited` with
status zero, or a Claude SessionEnd hook):

1. `Job.status` → `.completed` (or `.failed` if non-zero exit).
2. Force-flush scrollback writer for that task.
3. Move `tasks/<id>/scrollback.log` → `tasks/<id>/archive/<timestamp>/scrollback.log`.
4. Compress with zstd (or gzip if zstd unavailable): `.zst` extension.
5. Write `tasks/<id>/archive/<timestamp>/meta.json` with the final task state.
6. After the configured retention window (default **7 days**), the task
   drops out of `state.json` entirely; the `tasks/<id>/archive/` directory
   stays until manually purged.

Retention behavior is bookkeeping; not load-bearing for v0.1. A simple
"on launch, prune archives older than N days" pass is fine.

## Notification log

`notifications.jsonl` is an append-only event stream for the UI:

```jsonl
{"t":"...","kind":"awaitingInput","taskId":"...","message":"Claude is waiting for your input"}
{"t":"...","kind":"completed","taskId":"...","message":"Tests passed"}
```

Distinct from `events.jsonl` because:
- It's a UI feed, not state machinery.
- It can be truncated more aggressively (UI cares about last N).
- Dismissals don't need to be in the audit log.

## Schema versioning

`AppState.schemaVersion: Int` is on the model and serialized first. On
load, if the file's `schemaVersion` doesn't match the current code:

1. Run a migration function: `migrate(jsonObject, fromVersion, toVersion)`.
2. Save the migrated state immediately as a new snapshot before applying.
3. Bump the version constant in code and add a migration step.

This gets you a forward-only migration path. Backward compat is not a
goal for a single-user app. Don't add backward-compat shims.

Migration tests: round-trip an old-version JSON sample through migrate
and assert the resulting `AppState` is structurally what you'd expect.
Keep one sample JSON per historical version checked in under
`Tests/ManiCoreTests/Fixtures/`.

## Concurrency

All writes go through a single serial queue / actor: `PersistenceStore`.
This is the simplest correct model. Don't try to parallelize event writes
across multiple files or queues — it doesn't help (the disk is the
bottleneck) and creates ordering bugs.

Reads (for recovery, archive lookup) can be concurrent.

## Crash testing (spike 5)

Before shipping the persistence layer, run this:

```
loop 1000 times:
  fork()
  child:
    perform N random mutations through dispatch()
    exit(0)
  parent:
    sleep random ms in [1, 200]
    kill -9 child
    re-launch the app
    verify state.json + events.jsonl recover into a valid state
```

A "valid state" means: parses cleanly, all referenced UUIDs resolve, no
orphaned worktrees or jobs, schemaVersion matches, no NaN dates.

Do not ship persistence without this passing 1000/1000 cycles.

## What lives in `Settings`

```swift
public struct Settings: Codable, Equatable {
    public var scrollbackCapBytes: Int           // default: 32 MB
    public var snapshotIntervalSeconds: Int      // default: 30
}
```

Add to this as needed. Do not let it sprawl — anything beyond a handful of
knobs probably wants its own sub-struct (e.g., `Settings.persistence`,
`Settings.terminal`).
