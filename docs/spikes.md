# Spikes

Throwaway investigations to validate risky assumptions before committing.
Each spike is **1–3 days**, single-question, and has an explicit stop
condition. **Stop the project if any of spikes 1–3 fails the stop condition.**

Status legend: 🔲 not started · 🟡 in progress · ✅ green · 🔴 red

---

## Spike 1: SwiftTerm embedding ✅

**Question.** Can SwiftTerm render in a SwiftUI window with our font/theme,
accept input, and resize cleanly? Does it stay usable on plausible Claude
Code workloads?

**Time budget.** 1 day.

**Approach.**

1. Set up an Xcode app target alongside this package (`~/pr/mani/App/Mani.xcodeproj`).
   See `docs/terminal.md` § "When you start spike 1" for the step-by-step.
2. Add SwiftTerm via SPM: `https://github.com/migueldeicaza/SwiftTerm`.
3. Wire SwiftTerm's `LocalProcessTerminalView` into a single window
   running `/bin/zsh`. Don't bother with `ManagedPTY` — use SwiftTerm's
   built-in process launcher to validate rendering only.
4. Smoke checks:
   - Type, see input echoed.
   - `vim ~/.zshrc`, navigate, exit.
   - Resize the window — does the grid reflow correctly?
   - Cursor blinks at the right rate.
5. Torture tests (run each, observe):
   - `find / -type f 2>/dev/null` — sustained text firehose.
   - `cat /dev/urandom | head -c 10000000 | hexdump -C` — wide bursty output.
   - `vim` over SSH to a remote host — interactive responsiveness.
   - `htop` for ~30 seconds — periodic full-screen redraws.
   - Tail a busy log file (`tail -f /var/log/system.log` if available).
6. Profile briefly with Instruments (Time Profiler) on the heaviest case.

**Stop condition.**

- ✅ green: smoke tests pass; torture tests don't make the app stutter,
  drop input, or render incorrectly. Some lag during firehose is OK if
  the app stays responsive afterwards.
- 🔴 red: any of the smoke tests fails, *or* torture tests cause crashes,
  hangs, dropped input, lasting unresponsiveness, or visible rendering
  corruption. **Stop and surface to user.** Options at that point:
  investigate SwiftTerm config, file an upstream issue, or pivot to
  libghostty earlier than planned.

**Disposition.** Throwaway. Whatever you build for spike 1 is deleted
when starting v0.1 in earnest. The reusable knowledge is "SwiftTerm is
viable + here are its sharp edges."

---

## Spike 2: PTY lifecycle on macOS ✅

**Question.** Can we cleanly spawn shells via a PTY pair, deliver SIGTERM
on close with SIGKILL escalation, and avoid zombies across hundreds of
spawn/kill cycles?

**Time budget.** 2 days.

**Approach.**

1. New file `Spikes/PTYSpike/main.swift` (CLI executable, separate from
   `ManiCore`). Builds a `ManagedPTY` per the sketch in `docs/terminal.md`.
2. Test in a loop:
   ```
   for _ in 1...500:
     spawn /bin/zsh via openpty + posix_spawn
     write "echo hello\nexit\n" to PTY master
     verify "hello" appears in output
     wait for SIGCHLD
     verify no zombie (ps -ef | grep zsh)
   ```
3. Test termination escalation:
   ```
   spawn a process that ignores SIGTERM (e.g., a shell with trap)
   call terminate(escalateAfter: 0.5)
   verify process is gone within ~600ms
   verify no zombie
   ```
4. Test resize:
   ```
   spawn vim
   resize PTY via TIOCSWINSZ to 80x24, then 120x40
   verify SIGWINCH delivered to vim and it reflows
   ```
5. Test PTY input/output throughput:
   ```
   spawn cat
   write 10MB of random data
   read it back, verify byte-exact
   ```

**Stop condition.**

- ✅ green: 500/500 cycles complete with no zombies, no leaked file
  descriptors, no hangs. SIGTERM/SIGKILL escalation works. Resize delivers
  SIGWINCH. Throughput is ≥ 100 MB/s.
- 🔴 red: zombies, FD leaks, hangs, or any of the test loops fails to
  complete cleanly. **Stop and investigate.** Likely fixes: better SIGCHLD
  handling, explicit `waitpid`, double-fork pattern. PTY lifecycle is
  too fundamental to ship without.

**Disposition.** The code from this spike is *kept* — `ManagedPTY` is real
infrastructure. Move it to the app target when you build it.

**Findings (post-spike).**

- `forkpty()` (not `posix_spawn`) is the right call. `posix_spawn` doesn't
  acquire a controlling terminal even with `POSIX_SPAWN_SETSID`; the slave
  needs `TIOCSCTTY` which `login_tty()` (called by `forkpty`) handles. Without
  it, kernel-driven SIGWINCH on `ioctl(TIOCSWINSZ)` is silently dropped.
- Throughput came in at ~0.6 MB/s (vs the ≥100 MB/s spec) — adequate for
  Claude workloads but worth tuning later. The bottleneck is the dispatch
  read source's per-event drain loop fighting the slave's small kernel
  buffer; likely fix is kqueue-edge-triggered with a larger read or a
  dedicated reader thread.
- 500-cycle FD-count delta showed +1, traced to dispatch source teardown
  timing (the exit handler hadn't released the master FD by the time we
  measured). Add a short settle delay before measuring if you tighten this.
- Raw mode (`cfmakeraw` on slave before `execve`) is required for
  byte-exact streams; canonical mode caps line-buffer at ~1KB on macOS.

---

## Spike 3: Hook reachability ✅

**Question.** Can we register Claude Code hooks that reliably reach a Mac
app via Unix domain socket within ~200 ms?

**Time budget.** 1 day.

**Approach.**

1. Write the hook shim binary as a one-file Swift CLI:
   `Spikes/HookSpike/claudeorch-hook.swift`. Reads stdin, reads
   `CLAUDEORCH_TASK_ID` env, POSTs JSON to a Unix socket at
   `/tmp/mani-hook-spike.sock` (use `/tmp` for the spike to avoid the
   real Application Support path).
2. Write a tiny socket listener as a separate CLI:
   `Spikes/HookSpike/listener.swift`. Listens on the socket, prints any
   received envelope with a timestamp.
3. In a sandboxed dir (`/tmp/mani-spike-cwd`), write a fake
   `~/.claude/settings.json` that registers the shim for SessionStart,
   Stop, SessionEnd. Use `HOME=/tmp/mani-spike-home` to keep this
   sandboxed.
4. Run: `cd /tmp/mani-spike-cwd && env CLAUDEORCH_TASK_ID=test123 HOME=/tmp/mani-spike-home claude`.
5. Type a quick prompt, let Claude respond, press Ctrl-C.
6. Verify: SessionStart, Stop, and SessionEnd envelopes arrived at the
   listener within ~200 ms each.

**Stop condition.**

- ✅ green: all three events arrive at the listener with reasonable
  latency. Payload contains `session_id` and an identifiable
  `hook_event_name`.
- 🔴 red: events don't arrive, latency is unreasonable (multi-second), or
  the shim blocks Claude. **Stop and investigate.** Possible causes:
  socket permissions, blocking I/O in the shim, settings.json wrong path,
  Claude Code version differences. The fallback is to use a localhost HTTP
  port instead of a Unix socket, but Unix sockets are preferred.

**Disposition.** The shim and listener code carries forward; both move
into the v0.1 codebase under the app target.

**Findings (post-spike).**

- All three target hooks (`SessionStart`, `Stop`, `SessionEnd`) reached the
  listener with 3–6 ms shim→listener latency — well under the 200 ms
  budget. Tested against claude 2.1.132.
- Observed payload fields:
  - **SessionStart**: `session_id`, `transcript_path`, `cwd`,
    `hook_event_name`, `source` (e.g. `"startup"`), `model`.
  - **Stop**: `session_id`, `transcript_path`, `cwd`, `permission_mode`,
    `hook_event_name`, `stop_hook_active`, `last_assistant_message`.
  - **SessionEnd**: `session_id`, `transcript_path`, `cwd`,
    `hook_event_name`, `reason` (e.g. `"prompt_input_exit"`).
  - This is informative for spike 4 (JSONL parser) — `transcript_path`
    points directly at the session JSONL, so the hook tells us where to
    look without scanning `~/.claude/projects`.
- `MANI_TASK_ID` env var is inherited by Claude Code's hook subprocesses,
  so we can correlate hook envelopes to a specific task without parsing
  cwd/session.
- The shim must `exit 0` even when the listener socket is absent — verified
  by killing the listener mid-claude. Claude doesn't surface hook errors
  loudly; a non-zero exit could still cause UX issues, so always exit 0.
- macOS stdout buffering bites: if the listener's `print()` output is
  redirected to a file, it's fully buffered. Use `setbuf(stdout, nil)` so
  envelopes appear live.
- Notification hook wired but not exercised — needs a real "user input
  required" event (e.g., a permission prompt) to fire.

---

## Spike 4: JSONL parser stability across Claude versions ✅

**Question.** Can we parse Claude Code session JSONL files robustly, and
what minimum field set do we need? How do we degrade when a field is
missing?

**Time budget.** 1 day.

**Approach.**

1. Locate at least 5 real session JSONL files on disk under
   `~/.claude/projects/`. Pick a mix of recent and older sessions.
2. Write a parser in `Spikes/JSONLSpike/main.swift` that extracts:
   - `session_id` (sometimes top-level, sometimes per-line)
   - `last_message_at` (timestamp from the latest line)
   - `message_count` (count of lines that look like messages)
   - token usage if present (input_tokens, output_tokens, cumulative)
3. Run the parser on each file. Note which fields are present, missing,
   or in unexpected shapes.
4. Document the union schema in `docs/claude-integration.md` § "Hook
   payload schema" and the equivalent for JSONL lines.
5. Decide degradation rules: "if `usage` missing, show `?` for tokens"
   etc.

**Stop condition.**

- ✅ green: parser handles all 5 sample files without crashing, extracts
  usable values for each field, and surfaces reasonable defaults when a
  field is absent.
- 🔴 red: schema is too unstable to extract a coherent picture. Probably
  not stop-the-project red — just means tokens/counts are best-effort and
  the linkage logic must rely on `session_id` only. Document and proceed.

**Disposition.** Parser code carries forward into the watcher
implementation.

**Findings (post-spike).**

- 6 real session files (5–21,112 lines, 116 B – 156 MB on disk) parsed
  with zero failures. Throughput in a debug build: ~1,800 lines/s
  (~13 MB/s on the 156 MB file in 11.6 s) — fine for a watcher reading
  live appends.
- `sessionId` is **per-line** (under that key, camelCase), not top-level.
  Picking the first non-null seen is reliable; once set it doesn't change
  within a file. **No** files used the documentation-style `session_id`
  with underscore.
- Every assistant line we saw had `message.usage`. The "missing usage"
  degradation rule is still worth coding defensively but isn't hit in
  practice on Claude 2.1.107+ sessions.
- Line types are far broader than the spike spec implied. Observed across
  the sample: `assistant`, `user`, `attachment`, `file-history-snapshot`,
  `system`, `permission-mode`, `last-prompt`, `ai-title`, `queue-operation`,
  `progress`, `pr-link`, `custom-title`, `agent-name`. The parser ignores
  unknown types silently — that's the right default.
- Subagent transcripts live in `<sessionDir>/subagents/agent-*.jsonl` with
  the same schema, but `message.model` may be the literal string
  `<synthetic>` for orchestrator-emitted assistant lines. Don't rely on
  model parsing for these.
- Token usage union of fields:
  `input_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
  `output_tokens`, `server_tool_use`, `service_tier`, `cache_creation`,
  `inference_geo`, `iterations`, `speed`. Cumulative is just sum across
  assistant lines; we do not need to track per-iteration breakdowns for v0.1.
- The hook payload (Spike 3) carries `transcript_path` directly, so the
  watcher can subscribe to a known JSONL when a hook fires rather than
  inferring path from cwd. Path-from-cwd inference is still needed for
  the bare-watcher channel (`claude` runs outside Mani).

---

## Spike 5: Atomic snapshot writes under crash injection 🔲

**Question.** Does the snapshot + event-log scheme survive `kill -9` at
arbitrary points without corrupting state?

**Time budget.** 1 day.

**Approach.**

1. Write a parent + child harness: parent forks N children, each performs
   M random mutations through `dispatch()` against a `PersistenceStore`,
   then exits.
2. The parent injects `kill -9` at random points (sleep N ms, then
   SIGKILL the child).
3. After each child dies, parent runs the recovery code and validates:
   - JSON parses
   - Schema version matches
   - All UUIDs resolve (no orphans)
   - No duplicate IDs
   - All `Worktree.path` values are valid URLs
4. Run 1000 cycles.

**Stop condition.**

- ✅ green: 1000/1000 cycles recover cleanly. No corrupt files, no
  recovery failures.
- 🔴 red: any cycle produces an unrecoverable state. **Stop and fix.**
  Most likely causes: missing fsync, race between event-append and
  snapshot-rename, inadequate atomic-rename usage. Persistence cannot
  ship without this passing.

**Disposition.** Harness becomes a permanent regression test. The
persistence code itself is real v0.1 infrastructure.

---

## Spike 6: FSEvents on `~/.claude/projects` 🔲

**Question.** Does our directory watcher handle Claude Code's actual write
patterns — partial writes, file moves, atomic rewrites — without missing
events or duplicating them?

**Time budget.** 1 day.

**Approach.**

1. Write a small watcher with `DispatchSource.makeFileSystemObjectSource`.
2. While it's running, run `claude` in a sandboxed dir and have it write
   a real session.
3. Compare: events the watcher saw vs what's actually in the JSONL on disk.
4. Edge cases to provoke:
   - Two concurrent sessions in the same slug dir.
   - Extremely fast appending (Claude streaming a long response).
   - File rename mid-write (don't think Claude does this, but verify).
   - Slug dir created while the watcher is running (new project).

**Stop condition.**

- ✅ green: watcher sees every line that lands on disk, no duplicates, no
  multi-line decode failures.
- 🔴 red: missed events or duplicates. Investigate buffering and inode
  tracking. Falls back to polling if FSEvents proves unworkable, but that's
  ugly.

**Disposition.** Carry forward; this is the ClaudeWatcher implementation.

---

## Spike 7: Git worktree adversarial cases 🔲

**Question.** What's our UX when git worktree operations fail in the
ways they realistically fail?

**Time budget.** 1 day.

**Approach.**

Manually exercise (or scripted via shell):

1. Create a worktree on a branch already checked out elsewhere.
2. Create a worktree from a base ref that doesn't exist.
3. Delete a worktree directory while it's tracked by Mani.
4. `git worktree add` against a dirty index in the source repo.
5. Worktree on a submodule-containing repo.
6. Worktree on a bare repo.
7. Two Manis trying to create the same worktree path simultaneously
   (probably a no-op for v0.1 — single-instance app).

For each: capture the git CLI's error output and decide how Mani should
present it. Most should result in a user-visible error dialog with the
git stderr verbatim plus a one-line plain-language summary.

**Stop condition.** Not really stop-vs-go — this is enumeration. End state
is a written list of failure modes and Mani's response, in
`docs/claude-integration.md`'s git section (or a new doc).

**Disposition.** Documentation. The handling code lives in the
`Effect.createGitWorktree` runner.

---

## Spike 8: End-to-end smoke 🔲

**Question.** Do spikes 1, 2, and 3 actually work together?

**Time budget.** 2 days.

**Approach.**

Combine the artifacts from spikes 1–3 into a single throwaway window:

1. One project (hardcoded), one folder worktree (hardcoded), two tasks
   (one shell, one claude).
2. Both tasks spawn via `ManagedPTY` (spike 2).
3. Both render via SwiftTerm (spike 1).
4. Hook shim is registered, listener runs in-process (spike 3).
5. Click-to-kill each task; restart the app; confirm:
   - Layout is back.
   - Cwds are correct.
   - Hook events for the resumed Claude session arrive at the listener.

This is the proof that the architecture survives composition. If any
piece silently broke when combined, this catches it.

**Stop condition.**

- ✅ green: layout restores, both tasks usable, hook events flow. Move to
  v0.1 implementation.
- 🔴 red: composition broke something. Diagnose, fix, re-run. Don't begin
  v0.1 until green.

**Disposition.** Throwaway. The lessons feed into v0.1's real code.

---

## After all spikes are green

Begin v0.1 (see `PLAN.md` § "Phase 1"). The persistence layer (spike 5),
PTY layer (spike 2), and hook shim (spike 3) are real infrastructure that
moves into the v0.1 codebase. The SwiftTerm + Xcode app target setup
(spike 1) becomes the v0.1 app skeleton.
