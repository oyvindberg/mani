# Mani

> A native macOS orchestrator for many concurrent coding sessions across
> many repos — Claude Code conversations, shells, diff views — with
> crash-resilient state and a keyboard-driven global overlay that turns
> "too many sessions running at once" from a chaos problem into a
> mastery problem.

Mani sits above your terminals and your Claude conversations. It knows
which Claude is in which repo, which one finished its turn and is
waiting for you, which one is mid-thought, and what to relaunch when
the laptop reboots.

---

## The problem this solves

You're driving five Claude sessions at once. Each is in a different
repo, on a different branch, doing different work. You go grab coffee.

- One finished its turn and is sitting at the prompt waiting for your
  next instruction — but you don't notice, because it's behind a
  Spaces tab three windows away.
- Another is mid-thought; you don't want to interrupt.
- The other three you've half-forgotten exist.

Then your laptop crashes. Now you reconstruct everything from shell
history, `ls ~/.claude/projects/`, and squinting at git status across
five worktrees.

Existing tools each cover a slice:

| Tool                              | What it does          | Why it isn't this        |
| --------------------------------- | --------------------- | ------------------------ |
| tmux / Zellij                     | Multiplexed terminals | Terminal-only, no Claude context |
| iTerm2 Window Arrangements        | Restores layout       | Restores windows, not running processes |
| Crystal / Conductor / Claude Squad | Claude orchestrators  | Worktree-per-task model; different shape |

Mani is the layer above all of that. Native macOS. Owns the hierarchy
end-to-end. Survives reboots.

---

## The workflow

### Repos, Projects, Tasks

```
Repo "atlas"                          ← a codebase + a color
└── Project "auth rewrite"            ← a unit of intent (rename, archive)
    └── Workspace: gitWorktree(feat/auth, /…/atlas-auth)
        ├── Task: claude  ← live Claude Code session (session abc12345…)
        ├── Task: shell   ← running zsh, has its own scrollback
        └── Task: diff    ← the workspace's git diff view
```

At the repo level you also see:

- **External convos** — Claude sessions Mani didn't spawn. Discovered
  via FSEvents on `~/.claude/projects/`. One click to adopt one into a
  project as a managed task.
- **Available worktrees** — directories left over from archived
  manual-worktree projects. Still on disk, still discoverable, ready
  to be the home of the next project.
- **Finished projects** — archived. Tasks still inside, still
  draggable into active projects when you need them again.

You can **drag tasks between projects** when their workspaces match.
A red ⊘ overlay says no when they don't.

### Standing by — the marquee feature

Press **⌘⇧M from any app, anywhere.** A frameless dark glass panel
appears with every Claude session Mani knows about, grouped by status:

```
╭─────────────────────────────────────────────╮
│                                             │
│  Standing by.                               │
│  three ready · one working · five idle      │
│                                             │
│  READY  3 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│   ●  atlas — auth rewrite             4m    │
│   ●  dlab — CI cache fix             12m    │
│   ●  typr — TUI refactor             30s    │
│                                             │
│  WORKING  1 ━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│   ◉  atlas — fix tests              running │
│                                             │
│  IDLE  5 ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━     │
│   ·  …                                      │
│                                             │
│   ↑↓ navigate   ↵ open   ⌥↵ next   esc      │
╰─────────────────────────────────────────────╯
```

- **READY** orbs breathe in repo color (Stop hook fired, or unread > 0
  and not currently thinking).
- **WORKING** orbs send concentric ripples outward — claude is actively
  streaming bytes.
- **IDLE** is a dim presence dot.

Arrow keys navigate. **Enter activates Mani and selects the
oldest-awaiting claude** in that row — the one that's been hanging
longest. ⌥↵ cycles through that row's other awaiting claudes without
dismissing the panel. Escape dismisses. Click outside dismisses.

This is the moment that makes the rest of it worth it: from any app,
in one keystroke, see who needs you, in one more keystroke, be there.

### Per-repo color as the eye anchor

Every repo gets a color. That color is the *only* saturation in the
entire UI. It:

- Forms a continuous **2pt spine** down the left edge of every sidebar
  row in the repo's group — header, project, task. The repo is a
  thread you can follow with your eye.
- Tints the per-claude orbs in the Standing by overlay.
- Lights the selected task row (5pt-wide tab + 24%-opacity tinted
  background + soft halo).
- Hangs as a top-of-window ambient gradient when any task in that repo
  is thinking. The whole window quietly breathes the color of whatever's
  currently working.

The eye learns the colors. At a glance you know which repo's session
is calling without reading a single character.

### Crash recovery, for real

State is event-sourced: an append-only `events.jsonl` plus periodic
`state.json` snapshots. On boot:

1. Load the last snapshot.
2. Replay the events.jsonl tail.
3. For every `.running` task, probe its agent socket. If the agent is
   gone, emit a synthetic `.taskExited`.
4. Restore the user's last selection if it still exists.

The UI shows what's actually true, not a lie left over from before the
crash.

### Live git status

Each project header shows a compact mini-bar of `+N -M` line diff
relative to `origin/main` (or `origin/master`), plus `↑N` if ahead.
The detail-pane masthead expands this: branch name, behind count,
dirty marker, red ⚠ conflicts marker for mid-merge / mid-rebase states.
A 5-minute background `git fetch --prune` keeps the behind count
honest without your hands on it.

### Claude integration via hooks

Mani writes `SessionStart`, `Stop`, and `Notification` hooks into
`~/.claude/settings.json` (merging, not overwriting). A bundled shim
binary connects to a Unix socket inside Mani when Claude fires a hook:

- `SessionStart` → routes the new session id to a matching managed
  task (or surfaces it as an external convo).
- `Stop` → marks the task as **awaiting input**. The Standing by
  overlay picks this up the moment claude returns control.

---

## Getting started

### Requirements

- macOS 14 (Sonoma) or newer.
- **Full Xcode 15+** (with the macOS 15 SDK) — not just the Command
  Line Tools. The macOS app target lives in `App/Mani/Mani.xcodeproj`
  and is not part of `Package.swift`, so `xcodebuild` (and therefore
  Xcode.app) is required to build the GUI. Install from the App Store
  or via `brew install --cask xcodes` + `xcodes install --latest`.
- After installing Xcode, point the active developer dir at it:
  ```sh
  sudo xcode-select -s /Applications/Xcode.app
  xcode-select -p   # should print /Applications/Xcode.app/Contents/Developer
  ```
- `git` on PATH.
- *(optional but recommended)* The `claude` CLI from Anthropic — needed
  to spawn Claude Code tasks. Mani runs plain shells without it.

### Build & run

```sh
git clone https://github.com/oyvindberg/mani.git
cd mani
open App/Mani/Mani.xcodeproj
```

Hit ⌘R in Xcode. The app launches.

Command line build, if you prefer:

```sh
cd App/Mani
xcodebuild -project Mani.xcodeproj -scheme Mani -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/Mani-*/Build/Products/Debug/Mani.app
```

If `xcodebuild` errors with *"tool 'xcodebuild' requires Xcode, but
active developer directory '/Library/Developer/CommandLineTools' is a
command line tools instance"*, run the `xcode-select -s` step above.

#### First-time Xcode setup

A freshly installed Xcode needs a few extra one-time steps. If
`xcodebuild` complains, run these in order:

```sh
# 1. Accept the Xcode license (interactive sudo).
sudo xcodebuild -license accept

# 2. Install first-launch system components (CoreSimulator etc.).
xcodebuild -runFirstLaunch

# 3. Install the Metal toolchain (~700 MB; needed by SwiftTerm's
#    Metal shaders, the terminal renderer).
xcodebuild -downloadComponent MetalToolchain
```

#### Notes on third-party dependencies

- **libghostty-spm**: pinned in
  `App/Mani/Mani.xcodeproj/.../Package.resolved`. Upstream has
  occasionally deleted old release artifacts (e.g. the original
  `1.0.1777879537` is gone — 404). If SPM resolution fails with
  *"failed downloading … GhosttyKit.xcframework.zip:
  badResponseStatusCode(404)"*, bump the pin in `Package.resolved`
  and `project.pbxproj` to the latest 1.x release listed at
  https://github.com/Lakr233/libghostty-spm/releases.
- **Shallow-bundle workaround**: libghostty-spm ships its macOS
  framework with iOS-style shallow layout, which Xcode 26+ rejects
  during app validation. The Mani target has a *"Fix libghostty
  bundle layout"* Run Script build phase that restructures it into
  the deep `Versions/A/...` layout after embed and re-signs. This is
  why the Mani target also sets `ENABLE_USER_SCRIPT_SANDBOXING = NO`
  — the script needs to write inside `Mani.app/Contents/Frameworks/`.

### First-launch walkthrough

1. Mani opens to an empty state: *"No repos yet · ⇧⌘P to add one."*
2. Hit **⇧⌘P**. Give a repo a name, pick its root directory, and pick
   a distinctive color. A starter project (`wip`) is created
   automatically — rename it to what you're actually doing.
3. Hit **⇧⌘N** to add another project to the current repo, or **⌘T**
   to add a task (shell or claude) to the current project.
4. Hit **⌘⇧M** from anywhere — Mani in background, browser foreground,
   Slack open, whatever — to summon the Standing by overlay.

Try this: open two terminals across two repos, kick off `claude` in
each, give them work that'll take a minute. While they run, switch to
Safari. When they finish, the next time you hit ⌘⇧M, you'll see them
glowing in the overlay.

### Where state lives

```
~/Library/Application Support/Mani/
├── events.jsonl          ← append-only event log (durable)
├── state.json            ← latest snapshot (compaction)
├── tasks/<task-uuid>/    ← per-task scrollback log
├── agents/<uuid>.sock    ← AF_UNIX sockets to live agent processes
└── safekeep/<repoId>/    ← compressed past Claude transcripts
```

`rm -rf` the whole directory to factory-reset. Mani boots empty next
launch; agent helpers exit when their socket vanishes.

### Pure-Swift core (no Xcode)

`ManiCore` is Foundation-only, no AppKit dependency. Useful for hacking
on the model/reducer in isolation:

```sh
swift build       # ~6s clean
swift test        # 74 tests, ~50ms
```

---

## Keyboard shortcuts

| Where             | Key       | Action                                |
| ----------------- | --------- | ------------------------------------- |
| Anywhere          | ⌘⇧M      | Toggle Standing by overlay            |
| Anywhere          | ⇧⌘P      | New repo…                             |
| In Mani           | ⇧⌘N      | New project…                          |
| In Mani           | ⌘T       | New task…                             |
| In Mani           | ⌘F       | Search scrollback                     |
| Standing by       | ↑ / ↓     | Navigate                              |
| Standing by       | 1–9       | Jump to nth entry                     |
| Standing by       | ↵         | Open + activate Mani                  |
| Standing by       | ⌥↵       | Open without dismissing (cycle)       |
| Standing by       | esc       | Dismiss                               |
| Terminal pane     | fn+↑ / ↓  | Scroll terminal scrollback            |

---

## Architecture in one paragraph

`ManiCore` is a pure Foundation library: an immutable `AppState` value
tree, a `reduce(state, action) -> ([Event], [Effect])` reducer, and an
`apply(&state, event)` mutator. Events go to `events.jsonl`; effects
are queued for `EffectRunner` (process spawn, terminate, git ops,
persist). Per-task processes run inside a `mani-agent` helper bound to
an AF_UNIX socket — the agent owns the PTY, captures output, replays
it to the app on reattach. The terminal viewport is libghostty (via
`libghostty-spm`). Claude integration is one-way notification: Mani
registers hooks in `~/.claude/settings.json` pointing at a shim that
posts to a Unix socket; that's how the "awaiting input" state gets
driven.

Read [docs/architecture.md](docs/architecture.md) for the long version.

---

## Status

**Pre-release.** Builds locally from Xcode. No code signing, no
notarization, no auto-update, no Homebrew tap, no .app distribution yet.
Anyone willing to clone and build can run it, and the core invariants
(crash recovery, event-sourced state, hook routing) are solid enough
for daily driving.

What's there: full data model, sidebar hierarchy, terminal viewport via
libghostty, Claude session linking via hooks, FSEvents watcher on
`~/.claude/projects`, drag-drop tasks between projects, per-repo color
identity throughout, Standing by global overlay, live git status,
project archive with workspace preservation, crash recovery.

What's not yet:

- Code signing, notarization, distribution.
- A `mani` CLI.
- Multi-window.
- Search inside the live terminal grid (Cmd-F currently searches the
  on-disk scrollback log via an overlay).
- Restoring long on-disk scrollback on reattach. A libghostty rendering
  quirk made the synchronous pre-feed unsafe; we rely on the agent's
  in-memory replay buffer for reattach context.

The product name **Mani** is a code name — documented namespace
collisions with [alajmo/mani](https://github.com/alajmo/mani) (CLI repo
manager), the npm `mani` package, and several App Store apps. The
distribution name will not be plain `mani`. See ADR-001 in
[docs/decisions.md](docs/decisions.md).

---

## Repo layout

```
PLAN.md                 master plan + roadmap + scope rules
CLAUDE.md               agent-facing context for in-repo work
docs/                   architecture, persistence, terminal, ADRs
Sources/ManiCore/       Foundation-only library: model, reducer,
                        events, effects. No AppKit dependency.
Tests/ManiCoreTests/    XCTest, no I/O, deterministic, fast.
App/Mani/Mani/          the macOS app (AppKit + SwiftUI shell over
                        ManiCore). Where the UI, libghostty, and
                        agent socket plumbing live.
Spikes/                 throwaway code for risky building blocks.
```

## Further reading

- [PLAN.md](PLAN.md) — overall vision, roadmap, scope rules.
- [CLAUDE.md](CLAUDE.md) — hard rules + coding conventions for this
  repo (read first if you're an agent working in this codebase).
- [docs/architecture.md](docs/architecture.md) — the reducer / effect /
  persistence loop.
- [docs/decisions.md](docs/decisions.md) — ADR log; read before
  re-litigating any choice.
- [docs/claude-integration.md](docs/claude-integration.md) — session
  linking, hooks, FSEvents watcher.
- [docs/terminal.md](docs/terminal.md) — libghostty integration + PTY
  lifecycle.
- [docs/persistence.md](docs/persistence.md) — events.jsonl + snapshot
  rotation + crash recovery.

## Contributing

This is a personal project, published for inspection and the occasional
contribution. If you find a bug or want to suggest something, open an
issue. PRs welcome but please open an issue first for anything beyond
a small fix — there are strong opinions in `CLAUDE.md` and `docs/decisions.md`
worth understanding before re-shaping things.

## License

Not yet chosen. The repository is published for inspection and
hands-on use. No warranty; no recommended production deployment.
