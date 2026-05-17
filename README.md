# Mani

A native macOS app for orchestrating many concurrent coding sessions across
many repos, with crash-resilient state.

## The problem

You're running half a dozen Claude Code sessions and twice that many shells,
spread across different repos, branches, and worktrees. Each has its own
cwd, its own terminal window, its own session id. When the laptop crashes,
sleeps weirdly, or you reboot for an update, restoring the layout — the
right shells in the right directories, the right `claude --resume <sid>`
attachments — is tedious and lossy.

Existing tools each fall short:

- **Terminal multiplexers (tmux, Zellij)** — work, but terminal-only.
- **iTerm2 Window Arrangements** — restore windows, not running processes.
- **Crystal, Conductor, Claude Squad, Claudia/opcode** — orchestration GUIs
  for Claude Code, but target worktree-per-task parallelism. Different
  shape from what we want.

## What Mani is

A Mac app that owns the **repo → project → task** hierarchy, persists every
state change to disk continuously, and survives crashes by respawning the
right shells in the right cwds and re-attaching the right Claude sessions
by id.

## Mental model

```
Repo (atlas, color #ff5500)
├── Project "auth rewrite"             — a thing you want to do to this repo
│   └── Workspace: gitWorktree(feat/auth, /…/atlas-auth)
│       ├── Task: claude (session abc12345…, idle, 3 unread)
│       ├── Task: shell  (running)
│       └── Task: diff   (the workspace diff view)
├── Project "tail prod logs"
│   └── Workspace: folder(/var/log/atlas)
│       └── Task: shell
├── Finished projects (2)              — archived; workspaces kept, agents stopped
└── External convos (3)                — Claude sessions Mani didn't spawn;
                                         discovered on disk, adoptable
```

- **Repo**: a top-level codebase. Owns a color used everywhere as identity.
- **Project**: a unit of user intent within a repo (a feature, an
  investigation, a thing being shipped). Renameable, archivable.
- **Workspace**: a directory on disk. Either a real `git worktree` or a
  plain folder. Embedded 1:1 inside its Project. Missing-path detection
  built in.
- **Task**: the live process atom — a Claude session, a shell, a diff
  workspace, or a custom command. Multiple tasks per project are normal.
- **ExternalConvo**: a Claude session Mani didn't spawn but found on disk
  via FSEvents on `~/.claude/projects`. Sits as a sibling of Projects
  under the Repo (or at repo level if its cwd matches no project). Can be
  adopted, which spawns `claude --resume <sid>` against the matching
  project.

Every level has an `enabled` flag. Disabling cascades down and SIGTERMs
the underlying processes, so there's a panic switch at every rung.

## Architecture in one paragraph

State is an immutable Swift value tree (`AppState` in `ManiCore`). Reducer
is pure: `reduce(state, action) -> (events, effects)`. Events go through
`apply(&state, event)` and to a `events.jsonl` log; effects are queued and
executed by `EffectRunner` (process spawn, fs writes, git ops, terminate).
Snapshots (`state.json`) compact the log periodically. On boot, the app
loads the last snapshot, replays the log tail, then reconciles any
`.running` task against its agent socket on disk. Anything whose agent is
gone gets a synthetic `.taskExited` event, so the user sees stale state
truthfully instead of a lie. See `docs/architecture.md` and
`docs/persistence.md`.

## Status

In active development. v0.1 shipped end-to-end (full data model + sidebar +
terminal + Claude integration + persistence + crash recovery), v0.2 waves 1
and 2 are done. See `PLAN.md` for the full state of play.

Not yet:

- Code signing, notarization, Sparkle auto-update. Local dev builds only.
- Multi-window.
- Search inside the terminal viewport (Cmd-F currently searches scrollback
  via an overlay, not in the live grid).
- Compression of the on-disk session safekeeping store beyond the 32 MB
  ring cap.

## Build & run

Requirements: macOS 14+, Xcode 15+ with macOS SDK 15.x, Swift 5.10+.

The pure-Swift core library — Foundation only, unit-tested:

```sh
swift build       # clean ~6s
swift test        # 67 tests, ~7s
```

The macOS app target — depends on AppKit, SwiftUI, libghostty-spm:

```sh
open App/Mani/Mani.xcodeproj
# or:
xcodebuild -project App/Mani/Mani.xcodeproj -scheme Mani build
```

## Repo layout

```
PLAN.md                 master plan, roadmap, what's shipped vs pending
CLAUDE.md               agent-facing context — read first if you're an agent
docs/                   architecture, persistence, terminal, decisions log
Sources/ManiCore/       pure-Swift library: model, reducer, events, effects
Tests/ManiCoreTests/    XCTest, deterministic, no I/O
App/Mani/Mani/          the Mac app (AppKit + SwiftUI shell over ManiCore)
Spikes/                 throwaway code for risky building blocks
```

## Further reading

- `PLAN.md` — vision, roadmap, scope rules
- `CLAUDE.md` — hard rules + coding conventions for this repo
- `docs/architecture.md` — reducer/effect/persistence loop
- `docs/decisions.md` — ADRs; read before re-litigating any choice
- `docs/spikes.md` — risk-ordered validation experiments
- `docs/terminal.md` — libghostty integration + PTY lifecycle
- `docs/claude-integration.md` — session linking, hooks, FSEvents watcher

## Name

Code name. Collides with [alajmo/mani](https://github.com/alajmo/mani) (a
CLI tool for managing multiple git repos), the npm `mani` package, and
several App Store apps. Distribution name will not be plain `mani`. See
ADR-001 in `docs/decisions.md`.
