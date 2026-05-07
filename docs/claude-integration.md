# Claude integration

Mani's value over a generic terminal multiplexer is its awareness of Claude
Code sessions: linking a Task to a session ID, surfacing "awaiting input"
status, and resuming via `claude --resume <id>` after a crash.

Two channels feed this awareness, and both must be implemented.

## Channel 1: Filesystem watcher

Claude Code stores transcripts in `~/.claude/projects/<slug>/<session-uuid>.jsonl`,
where `<slug>` is the cwd with `/` replaced by `-` (e.g.,
`/Users/oyvind/pr/atlas` → `-Users-oyvind-pr-atlas`).

Each session is one file. Each line is a JSON object. New session = new
file in the slug dir; new message = file appended.

### Implementation outline

```swift
actor ClaudeWatcher {
    private let projectsDir: URL                              // ~/.claude/projects
    private var dirSource: DispatchSourceFileSystemObject?
    private var slugSources: [String: DispatchSourceFileSystemObject] = [:]
    private var fileTails: [URL: TailReader] = [:]
    private var dispatch: ((Action) async -> Void)!

    func start(dispatch: @escaping (Action) async -> Void) {
        self.dispatch = dispatch
        scanExisting()                                        // hydrate
        watchDir(projectsDir)                                 // for new slugs
    }

    private func scanExisting() {
        // For each slug dir, for each .jsonl, attach a TailReader.
    }

    private func watchSlugDir(_ url: URL) {
        // FSEvents: when a new .jsonl appears, attach a TailReader.
    }

    private func attachTail(_ fileURL: URL) {
        // Open at end-of-file, track inode/dev for rename detection,
        // call back with new lines as they arrive.
    }
}
```

Use `DispatchSource.makeFileSystemObjectSource(fileDescriptor:eventMask:queue:)`
for directory and file watches. For files, watch `[.write, .extend, .rename,
.delete]`.

### Critical detail: partial writes

JSONL writes are not atomic. A tail reader will sometimes see half a line
when the file watch fires. **Buffer until you see `\n`**, then attempt to
decode. Discard lines that fail to decode (log a warning) — do not throw.

### Mapping watcher events to tasks

When a new session JSONL appears in slug `s`:

1. Decode `s` back to a cwd URL.
2. Find tasks whose `primary.cwd` matches *and* `kind == .claude` *and*
   `kind.sessionId == nil`.
3. Of those, pick the most recently created.
4. If found: dispatch `.linkClaudeSession(at: jobPath, sessionId: ...)`.
5. If none found: this is a Claude session the user started outside Mani.
   Don't auto-create a task; we can surface it in a "detected sessions"
   panel later.

### Per-session updates

While tailing, extract these fields per line and dispatch updates:

- `last_message_at` (parsed from the line's timestamp)
- `message_count` (running total since session start)
- token usage if present (`usage.input_tokens`, `usage.output_tokens` —
  these may live in different shapes per Claude version)

Throttle updates to one per second per session — we don't need real-time
counter updates.

## Channel 2: Hooks

Claude Code's `~/.claude/settings.json` (and per-cwd `.claude/settings.json`)
supports hooks: shell commands run on specific events. We use them for
sub-second latency on idle/start/end events.

### Events we care about

| Hook | Why we need it |
|------|----------------|
| `SessionStart` | Capture session_id at the moment of session creation, not when we eventually see the JSONL. Enables instant linkage. |
| `Stop` | Claude finished its turn and is awaiting user input. Drives "idle" status and the badge. |
| `Notification` | Permission prompts, errors. Surface as user notification. |
| `SessionEnd` | Mark task `.completed`. |

Other hooks (`PreToolUse`, `PostToolUse`, `UserPromptSubmit`, `PreCompact`,
`SubagentStop`) are interesting later — for activity logs or stats — not
for v0.1.

### The shim binary

The app ships `claudeorch-hook` inside the `.app` bundle. It's a tiny CLI
binary (~50 lines of Swift) that:

1. Reads the hook payload from stdin.
2. Reads `CLAUDEORCH_TASK_ID` from env (set by the app when spawning
   `claude` for a task). If unset, the hook fired for a Claude session not
   spawned by us — still process it, but mark the task ID as nil.
3. POSTs `{ payload, task_id }` to a Unix domain socket at
   `~/Library/Application Support/Mani/hook.sock`.
4. Exits 0 unconditionally. Do not let any failure path block Claude.

```swift
// pseudocode for the shim
let payload = FileHandle.standardInput.readToEnd()
let taskId = ProcessInfo.processInfo.environment["CLAUDEORCH_TASK_ID"]

let envelope: [String: Any] = [
    "task_id": taskId as Any,
    "payload": (try? JSONSerialization.jsonObject(with: payload)) as Any
]
let body = try JSONSerialization.data(withJSONObject: envelope)

// Try to POST to Unix socket; on any failure, write to fallback file and exit 0.
do {
    try sendToSocket(body, path: "~/Library/Application Support/Mani/hook.sock")
} catch {
    try? appendFallback(body)
}
exit(0)
```

A fallback file (`hook-misses.jsonl` next to the socket) lets us recover
events that arrived while the app wasn't running. On launch, the app reads
and processes any accumulated misses, then truncates the file.

### Spawn shape

When the app spawns `claude` for a task:

```swift
let env = [
    "CLAUDEORCH_TASK_ID": jobId.uuidString,
    // … inherited environment minus TERM (terminal sets it)
]
processManager.spawn(ProcessSpec(
    command: "claude",
    args: ["--resume", existingSessionId].compactMap { $0 } ?? [],
    env: env, cwd: worktreePath, pid: nil
))
```

If the user has just-renamed a Claude session or otherwise has a session ID
to attach, pass `--resume <id>` as the spawn args. Otherwise `claude` starts
fresh and the SessionStart hook will tell us the new ID.

### The settings.json merge

The user's `~/.claude/settings.json` may already contain hooks. **Merge,
don't overwrite.** Algorithm:

```
1. Read existing JSON (or {} if missing).
2. For each event we register, ensure hooks[<event>] exists as an array.
3. Append our entry to that array, marked with a unique source field:
     {
       "type": "command",
       "command": "/Applications/Mani.app/Contents/MacOS/claudeorch-hook",
       "_mani": true
     }
4. Skip if a `_mani: true` entry already exists for that event.
5. Write back atomically (temp file + rename).
```

On uninstall: remove all entries with `_mani: true`. Leave the user's own
hooks intact.

The `_mani` field is non-standard but harmless — Claude Code ignores
unknown JSON fields.

### Hook payload schema

Claude's hook payloads include at minimum:
- `hook_event_name` (e.g., "Stop", "SessionStart")
- `session_id` (UUID-like string)
- `cwd` (filesystem path)
- `transcript_path` (path to the JSONL)

Plus event-specific fields. Decode defensively: `decodeIfPresent` for
everything beyond `hook_event_name` and `session_id`. Log unknown event
types — don't crash on them.

**Claude's hook payload format is not a stable public API.** Pin a snapshot
of the schema in code, write decoders that tolerate missing or extra
fields, and add a one-line CHANGELOG entry whenever the schema visibly
shifts. Over time, this becomes its own small compatibility surface.

## Why both channels

Each catches what the other misses:

| Scenario | Watcher | Hooks |
|----------|---------|-------|
| Spawned-by-Mani Claude session starts | sees JSONL appear (~hundreds of ms) | sees SessionStart (sub-second) |
| User runs `claude` from a regular terminal | sees JSONL appear | hook fires only if our settings.json registration is present |
| Claude finishes a turn, awaits input | sees no new lines for a while (heuristic) | Stop hook fires immediately |
| Claude session ends | sees final JSONL line, file stops growing | SessionEnd fires |
| User deletes a session (rare) | sees file removal | nothing |

For v0.1, both channels are required to get the full UX. **If timeline
forces a cut, the watcher alone is acceptable** — you lose sub-second idle
detection but keep linkage and historical view. Hooks become v0.2.

## Sharp edges

1. **Race: same event on both channels.** A SessionStart hook may fire
   before the watcher sees the file, or vice versa. Linking code must be
   idempotent: if `Job.kind.sessionId` is already set to the same ID,
   the second event is a no-op.
2. **Nested Claude sessions.** If a user runs `claude` inside a Mani-spawned
   `claude` (subagent? interactive shell?), the env var leaks. The hook
   shim can detect this by checking the parent process — but for v0.1, just
   accept that the env var wins and the inner session links to the outer
   task. Document it as a known limitation.
3. **JSONL rotation.** Claude Code may move/rotate session files. A
   tail reader watching by inode survives renames; one watching by path
   doesn't. Use FD + inode tracking.
4. **The shim must work without the app running.** If a user runs `claude`
   while Mani is closed, the shim's POST to the socket fails — fallback
   file. On launch, drain it.
5. **The shim path is the .app bundle path.** Keep it stable. If the user
   moves Mani.app, the hooks break until next merge. Detect this on
   launch by re-merging settings.json with the current app bundle path.

## Testing approach

- **Unit-test the slug encoding** both directions. Tricky cases: paths with
  `-` already in them, paths with non-ASCII, paths shorter than expected.
- **Integration-test the watcher** by writing a fake JSONL file in a temp
  dir under a fake `projects` root, then triggering the watcher and
  asserting the right actions get dispatched.
- **Round-trip the hook envelope** — serialize, send through shim, receive,
  decode, assert.
- **Simulate hook payloads** from real Claude Code runs you have on disk.
  Pin sample payloads under `Tests/ManiCoreTests/Fixtures/hookPayloads/`.
- **Crash test** by killing the shim mid-POST and confirming the fallback
  file gets written and drained on next launch.
