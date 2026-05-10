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

v0.1 shipped end-to-end and v0.2's first wave (libghostty + theming +
claude reflow workaround) is in. All eight spikes are green.

Layout:

```
Package.swift                              swift-tools 5.10, macOS 14+
Sources/ManiCore/                          Foundation-only library
  Model/                                   AppState, Project, Worktree, Job,
                                           ProcessSpec (with initialInput),
                                           JobKind/Status, Settings
  Paths.swift                              WorktreePath, JobPath
  Action.swift, Event.swift, Effect.swift  three-type pipeline
  Reducer.swift                            reduce + apply, all cases
  PersistenceStore.swift                   events.jsonl + state.json + recovery
Tests/ManiCoreTests/                       29 tests, green

App/Mani/Mani.xcodeproj                    macOS app target
App/Mani/Mani/
  ManiApp.swift                            @main, Store wiring, settings recover
  Store.swift                              Store + resetForNewClaudeTask
  ContentView.swift                        NavigationSplitView, sidebar, panes
  NewItemSheets.swift                      project / worktree / claude sheets
  EffectRunner.swift                       process spawn, scrollback, git
  ManagedPTY.swift                         forkpty + execve + signal sources
  ClaudeTaskSpec.swift                     factory for claude job specs
  LibGhosttyRenderer.swift                 libghostty backend behind protocol
  TerminalRenderer.swift                   protocol (renderer-agnostic)
  ScrollbackWriter.swift                   ring-buffer per-task log
  ClaudeWatcher.swift                      FSEvents on ~/.claude/projects
  HookListenerService.swift                AF_UNIX socket server
  HookRegistration.swift                   merges shim into ~/.claude/settings.json
  ClaudeHistoryScanner.swift               session enumerator for Resume sheet
  NotificationService.swift                UNUserNotificationCenter
  SettingsView.swift                       General + Terminal tabs
  ColorHex.swift, ColorPalette.swift       project color picker
```

Build: `swift build` (~2s) and `xcodebuild -project App/Mani/Mani.xcodeproj
-scheme Mani` for the app. Tests: `swift test` (29/29 green).

What is **not** built (deferred or punted):

- Auxiliary process **restart policies** (model has `auxiliary: []`; sheet
  builds aux specs; no policy yet — see § "v0.2 backlog").
- App-target tests for `EffectRunner`, `ClaudeTaskSpec`, the post-spawn
  write delay, and the persistence-wipe flow.
- Font picker in Settings (theme picker is in).
- Search, hyperlinks, image protocols inside the terminal viewport.
- Scrollback compression beyond the 32 MB ring cap.
- Multiple windows.
- Code signing, notarization, Sparkle auto-update.
- Per-cwd `.claude/settings.json` hook scope (rejected per ADR-013).

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

**Shipped:**
- Full data model
- Folder *and* git worktrees
- Tasks: shell + claude (claude via zsh + injected `claude\r`; see ADR-015)
- TerminalRenderer protocol + libghostty backend (originally SwiftTerm; swapped
  in v0.2-wave-1 per ADR-002)
- Reducer + EffectRunner + persistence (state.json + events.jsonl + scrollback.log)
- Sidebar tree with project → worktree → task hierarchy and enable/disable
  kill switches at every level
- Crash recovery + selective auto-respawn (`respawnSafelisted`)
- Claude watcher (FSEvents on `~/.claude/projects`)
- Hook plumbing (in-process AF_UNIX listener, merged `settings.json` shim)
- Session linking (cwd + recency for bare watcher; SessionStart hook for
  spawned tasks)
- macOS user notifications + sidebar badges (unread counts)
- **Per-project visual identity**: 3px sidebar border + color band above
  content + tinted breadcrumb. No theming inside the terminal viewport.
- Settings UI (general + terminal tabs; theme picker)

**Explicitly not in v0.1 (per later ADRs):**
- Tabs per worktree — dropped, sidebar is the only navigation (ADR-014).

### Phase 2: v0.2 backlog

Wave 1 done:
- libghostty renderer (ADR-002 swap)
- Theming via Ghostty theme catalog
- Claude resize/reflow workaround via zsh + post-spawn keystroke injection
  (ADR-015), with `Store.resetForNewClaudeTask()` to keep persisted specs
  from haunting the UI

Wave 2 (in progress / planned):
1. Process hygiene: deterministic PTY teardown on quit, kill-before-restart,
   removing the now-redundant ManagedPTY double-fork
2. Auxiliary processes with restart policies
3. Font picker in Settings (theme picker is in)
4. App-target tests covering EffectRunner spawn flow, ClaudeTaskSpec,
   resetForNewClaudeTask
5. Per-restart scrollback rotation (one log per session, archived on restart)
6. Search and hyperlinks inside the terminal viewport
7. Scrollback compression / rotation beyond the 32 MB ring cap
8. Inline image protocols (Sixel / iTerm2 / Kitty) — TBD which to support
9. claude `--resume` session-id reconciliation when claude allocates a new id

Out of scope for v0.2:
- Multiple windows
- Code signing / notarization / Sparkle auto-update

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

See § "Phase 2: v0.2 backlog" above for the canonical list. The order
favors process-hygiene fixes (because they affect dogfooding stability)
before user-facing features.

**Top of stack:**

1. Revert the `ManagedPTY` double-fork (commit `8b9e12b`). Originally
   added trying to fix claude resize; the resize fix is now zsh+keystroke
   injection (ADR-015), and the double-fork's only remaining effect is
   leaving orphan intermediate processes when Mani is killed.
2. Deterministic PTY teardown on Mani quit. Currently spawned PTYs become
   orphans. Wire an `applicationWillTerminate` hook through to
   `EffectRunner` so it kills every live PTY first.
3. Restart button must SIGTERM/wait the live pid before respawning;
   currently it spawns a second process on top of the first.
4. Hide / disable command + args fields in `NewTaskSheet` when kind=Claude
   (the factory ignores them; the form lies to the user).

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
