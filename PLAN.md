# Mani — Master Plan

A macOS app for orchestrating multiple concurrent coding sessions (Claude Code
+ shells) across many projects and worktrees, with crash-resilient state.

> **If you are an agent picking up this work, read this whole file first, then
> drill into `docs/` as needed. The history of decisions matters; don't
> re-derive them.**

---

## Why this exists

The user runs ~10 concurrent projects with Claude Code, each with its own
terminal window/tab layout, working directory, and live conversation. A
machine crash wipes all the windows; manual restoration is tedious and lossy.
Existing tools each fall short:

- **Terminal multiplexers (tmux, Zellij)** — work, but the user dislikes
  terminal-only solutions for daily driving.
- **iTerm2 Window Arrangements** — restore layouts but not running processes.
- **Crystal, Conductor, Claude Squad, Claudia/opcode** — orchestration GUIs
  for Claude Code, but they target a different model
  (worktree-per-task parallelism). Worth knowing about; not what we're
  building.

**Mani's pitch:** native Mac app that owns the projects → worktrees → tasks
hierarchy, persists state continuously, and survives crashes by re-launching
shells/`claude` in the right cwds with the right session IDs.

---

## Mental model the product enforces

```
Project (color: #ff5500, name "atlas")
├── Worktree (.git "feat/auth-rewrite", path /…/atlas-auth)
│   ├── Task: claude    [linked to session abc123, idle, 3 unread]
│   ├── Task: tests     [shell, running]
│   └── Task: dev       [shell + aux dev-server, running]
└── Worktree (.folder, path /…/atlas-prod)
    └── Task: tail logs [shell, running]
```

- A **Project** is the user's mental top-level (e.g., "atlas"). Owns a color
  for cognitive grouping.
- A **Worktree** is either a real `git worktree` *or* a manually-created
  parallel folder. Both are valid; the user has both kinds.
- A **Task** (`Job` in code — see § Naming below) is the snapshot atom. It's
  a Claude session, a shell, or "shell + a few helper processes." Multiple
  tasks per worktree are normal.

Every level has an `enabled` flag — disabling cascades and SIGTERMs all
processes underneath, so the user has a panic switch at any level.

---

## What's built right now

A `ManiCore` Swift Package with the data model + reducer pattern + 4 passing
tests. All Foundation-only, no UI dependencies yet.

Files (paths relative to repo root):

```
Package.swift                              swift-tools 5.10, macOS 14+
Sources/ManiCore/
  Model/AppState.swift                     AppState, Settings
  Model/Project.swift                      Project
  Model/Worktree.swift                     Worktree, WorktreeKind (.git/.folder)
  Model/Job.swift                          Job, JobKind, JobStatus
  Model/ProcessSpec.swift                  ProcessSpec
  Paths.swift                              WorktreePath, JobPath
  Action.swift                             full Action enum (~14 cases)
  Event.swift                              full Event enum (~14 cases, Codable)
  Effect.swift                             full Effect enum (~9 cases)
  Reducer.swift                            reduce + apply; createProject and
                                           setProjectEnabled implemented;
                                           remaining cases are exhaustive no-ops
Tests/ManiCoreTests/ReducerTests.swift     4 tests, all green
```

Build: `swift build` (~6s). Tests: `swift test` (~7s, 4/4 pass).

What is **not** built:

- Reducer cases beyond `createProject` / `setProjectEnabled`.
- `apply` cases beyond the same two.
- The persistence layer (`PersistenceStore`) — no events.jsonl writer, no
  state.json compactor, no recovery code.
- `EffectRunner` — no actual process spawning, no FS writes.
- Any UI or app target. SwiftTerm not yet a dependency.
- Claude integration (watcher, hooks, shim binary).

---

## Naming

**Code name: Mani.** The user picked this knowing about a hard collision
with [alajmo/mani](https://github.com/alajmo/mani) (a CLI tool for managing
multiple git repos), several App Store apps, and the npm `mani` package.
See `docs/decisions.md` ADR-001 for context.

Implications you must keep in mind:

- The product is **Mani** (UI title, marketing, conversation language).
- The Swift module/library is **ManiCore**.
- The distribution binary name is **TBD** — must not be plain `mani` because
  Homebrew/npm/MacPorts already have something there. Likely `mani-app` or
  ".app only, no CLI." Decide before any public release.
- `Task` (the domain concept) is named **`Job`** in Swift code because of
  `_Concurrency.Task` ambiguity. Translate at the UI layer.

---

## Roadmap

### Phase 0: Spikes (~2 working weeks)

The architecture below assumes some risky building blocks work. Spikes
validate them with throwaway code before committing. **Stop if any of the
first three fails.**

See `docs/spikes.md` for the full list with stop conditions. Summary:

1. **SwiftTerm embedding in SwiftUI** — gates the whole product
2. **PTY lifecycle on macOS** — gates everything else
3. **Hook reachability** — gates Claude integration
4. JSONL parser stability across Claude versions
5. Atomic snapshot writes under crash injection
6. FSEvents on `~/.claude/projects` — race conditions
7. Git worktree adversarial cases
8. End-to-end smoke (combine 1–3)

### Phase 1: v0.1 (~6–8 working weeks post-spikes)

The user explicitly opted into a larger v0.1 than initially proposed: full
Claude integration is *in*, not deferred.

**In scope:**
- Full data model (already done, model layer)
- Folder *and* git worktrees
- Tasks: shell + claude
- SwiftTerm renderer behind `TerminalRenderer` protocol
- Reducer + EffectRunner + persistence (state.json + events.jsonl + scrollback.log)
- Sidebar tree (Project → Worktree → Task), enable/disable kill switches
- Tabs per worktree
- Crash recovery
- Claude watcher (FSEvents on `~/.claude/projects`)
- Hook plumbing (shim binary, merged settings.json, Unix socket)
- Session linking (cwd + recency for bare watcher; SessionStart hook for spawned tasks)
- macOS user notifications + sidebar badges
- **Per-project visual identity**: 3px sidebar border + 6-8px color band above content + tinted breadcrumb. *No theming inside the terminal viewport.*

**Out of scope (deferred to v0.2+):**
- Auxiliary processes (model has `auxiliary: []` reserved; just primary for v0.1)
- Settings UI (config via plist)
- Multiple windows
- Search, hyperlinks, image protocols
- Scrollback archive/compression beyond a ring-buffer cap
- Code signing / notarization (run unsigned via `xattr -dr com.apple.quarantine`)
- libghostty renderer

**Cut point if timeline is tight:** drop hooks (keep watcher only). Loses
sub-second idle detection; saves ~3–4 days. Hooks become v0.2.

### Phase 2: v0.2+ (post-dogfooding, in rough order)

1. Git worktree creation UX polish (edge cases)
2. Auxiliary processes with restart policies
3. libghostty renderer behind the same `TerminalRenderer` protocol
4. Theming, fonts, settings UI
5. Search and hyperlinks
6. Code signing + notarization + auto-update (Sparkle)

---

## Architecture summary (read `docs/architecture.md` for depth)

Three-type pipeline:

- **`Action`** — what the user/system *wants*. May fail validation.
- **`Event`** — what *happened*. Durable, replayable, the audit log.
- **`Effect`** — I/O to dispatch (spawn, kill, fs writes). May fail and retry.

```
Action ──▶ reduce(state, action) ──▶ ([Event], [Effect])
                                           │
                          ┌────────────────┘
                          ▼
                    persistEvents (durable, fsync)
                          │
                          ▼
                  apply(&state, event)  ◀── same function used at
                          │                  recovery (replay events)
                          ▼
                    UI updates
                          │
                  remaining Effects  ──▶  EffectRunner (actor)
                                                │
                                                ▼
                                          posix_spawn, git, fs, …
                                                │
                                                ▼
                                          dispatch new Action
```

Why three types not two:
- Pure `(state, action) → state` mixes intents and facts; you can't replay
  pure intents because they may have failed validation.
- Pure `(state, event) → state` doesn't have a good place to express
  "spawn a process" without making the state machine impure.
- Splitting them gives you: testable reducer, durable event log, replayable
  recovery, and an isolated I/O boundary.

## Persistence summary (`docs/persistence.md` for depth)

Three tiers running concurrently:

1. **Continuous**: scrollback per task → `tasks/<id>/scrollback.log`
   (append, ring-buffer capped, flushed every 250ms or 64KB).
2. **Events**: every state change → `events.jsonl` (append, fsync per write).
3. **Periodic**: full `AppState` → `state.json` every 30s or on significant
   event, atomic-rename, then truncate `events.jsonl`.

On launch: read `state.json` → replay any newer events from `events.jsonl`
→ reconcile (zero out PIDs because the processes are dead, mark
`running` tasks as `stopped`). Auto-restart only safelisted commands
(`claude`, shells with no captured user command).

Storage root: `~/Library/Application Support/Mani/`. Nothing in user repos.

## Claude integration summary (`docs/claude-integration.md` for depth)

Two channels feed Claude state:

- **FSEvents watcher** on `~/.claude/projects/` — comprehensive but ~hundreds
  of ms latency. Catches manual `claude` runs and file-tail updates.
- **Hooks** via `~/.claude/settings.json` — sub-second, fire on
  `SessionStart`/`Stop`/`Notification`/`SessionEnd`. The app ships a tiny
  `claudeorch-hook` shim binary inside the `.app`; the hook calls it; it
  POSTs to a Unix socket the app listens on.

Both must coexist. Both must handle "this session is already known"
gracefully — events for the same session may arrive on either channel first.

Sharp edges:
- The user's existing `~/.claude/settings.json` may have hooks. **Merge,
  don't overwrite.** Splice in entries with a unique marker; on uninstall,
  splice out.
- Claude's hook payload schema is not a public API. Decode optional fields
  defensively; log unknowns.
- Per-cwd `.claude/settings.json` exists too — possibly worth using for
  project-scoped hooks later.
- The shim must exit 0 on any failure path. **Hooks blocking Claude is
  worse than missing one.**

## UI summary (`docs/ui.md` for depth)

```
┌─────────────────────┬────────────────────────────────────────────┐
│ ◤ atlas             │ ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓│  ← project band
│   ◤ feat/auth-rew   ├────────────────────────────────────────────┤
│     • claude        │ atlas › feat/auth-rewrite › claude         │  ← breadcrumb
│     • tests         ├────────────────────────────────────────────┤
│     • dev server    │                                            │
│ ◤ dispatch          │           [terminal viewport]              │
│   ◤ main            │                                            │
│     • claude        │                                            │
└─────────────────────┴────────────────────────────────────────────┘
```

- Sidebar tree shows full hierarchy. Each row gets a 3px left border in
  its project's color (cascades visually — worktrees and tasks under a
  project all show the same stripe).
- Project band: 6–8px solid stripe at the top of the main pane.
- Breadcrumb: `<project> › <worktree> › <task>` in the project's color.
- Notifications appear as sidebar badges (count) and macOS user notifications.

The user is colorblind-aware and chooses colors manually — provide a swatch
grid of 8–12 hand-picked colors plus a free-form hex input. **Do not
auto-assign colors.**

---

## Open questions for the user before starting v0.1

These were not pinned in the planning conversation. Surface them when relevant.

1. **New-task / new-worktree UX**: Cmd-T for new task in current worktree?
   Cmd-Shift-N for new worktree? What's the friction the user wants?
2. **Window/tab keyboard navigation**: Cmd-1..9 for projects? Cmd-Shift-]/[
   for tasks? Other muscle memory expectations?
3. **Color palette**: which 8–12 colors for the swatch grid? Need accessible
   options on dark and light. Maybe sample from common design systems.
4. **Hooks scope**: global `~/.claude/settings.json` or per-cwd
   `.claude/settings.json` for v0.1? Global is simpler; per-cwd is cleaner.
5. **Distribution binary name**: confirm `mani-app` or alternative.

---

## Hand-off checklist for the next agent

When you sit down:

1. Read `CLAUDE.md` (you've probably auto-loaded it; re-read it).
2. Read this file (PLAN.md).
3. Skim `docs/decisions.md` to know what's settled.
4. Skim `docs/spikes.md` to know what's next.
5. Run `swift build && swift test` to confirm the baseline is green on
   your machine.
6. Pick a task from § "What's next" below or ask the user.
7. **Don't expand scope. Don't commit. Don't rename Job back to Task.**

---

## What's next, prioritized

**Most urgent (gating risk):**

1. **Spike 1 — SwiftTerm embedding.** Needs an Xcode app target. Steps:
   - Open `Package.swift` in Xcode (or create an Xcode project alongside
     that depends on the local package).
   - Add the SwiftTerm SPM dependency: `https://github.com/migueldeicaza/SwiftTerm`
   - Build a minimal SwiftUI window with a `TerminalView` that runs `/bin/zsh`
     and accepts input.
   - Torture-test: `find / -type f 2>/dev/null`, `cat /dev/urandom | head -c 10000000`,
     `vim` over SSH. Make sure rendering doesn't melt.
   - Stop condition: if SwiftTerm can't keep up with normal Claude Code
     workloads, escalate to the user before continuing. The whole stack
     pivots if this fails.

**Useful while spike 1 is gated:**

2. Flesh out the remaining reducer cases with tests:
   - `createWorktree`, `deleteWorktree`, `setWorktreeEnabled`,
     `markWorktreeMissing`
   - `createJob`, `setJobEnabled`, `completeJob`, `linkClaudeSession`
   - `processStarted`, `processExited` (pid bookkeeping)
   - `renameProject`, `deleteProject`
3. Implement `apply` for the same cases.
4. Add property-based or randomized tests over (action stream → state)
   to catch reducer bugs.

**Pre-spike-2 prep:**

5. Sketch `ManagedPTY` (the PTY wrapper described in `docs/terminal.md`)
   as a header / interface, no implementation yet. Lets us start the
   `EffectRunner` skeleton in parallel with spike 1.

**Do NOT do yet:**

- Add SwiftTerm to `Package.swift`. It's a UI dependency; goes in the app
  target, not in `ManiCore`.
- Build the persistence layer. Architecture is settled but premature; better
  to have one or two more reducer cases working first to know the shape of
  what we're persisting.
- Add a CLI or executable target. Mani is a Mac app, not a CLI.

---

## Pointers

- **`docs/architecture.md`** — full reducer/effect runner pattern, with
  rationale and code shapes.
- **`docs/persistence.md`** — file layout, snapshot tiers, recovery flow.
- **`docs/claude-integration.md`** — watcher, hooks, shim binary, session
  linkage, sharp edges.
- **`docs/terminal.md`** — `TerminalRenderer` protocol, `ManagedPTY`,
  capability negotiation.
- **`docs/ui.md`** — sidebar, tabs, color treatment, notification surfacing.
- **`docs/spikes.md`** — full spike list with questions and stop conditions.
- **`docs/decisions.md`** — ADR log. Read before re-litigating any choice.
- **`docs/coding-rules.md`** — conventions, with rationale.
