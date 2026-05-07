# Decisions log (ADRs)

Architectural decisions, lightweight. Each one captures context, the
decision, and why. Read this before re-litigating any choice.

Format: ADR-NNN, status, decision, rationale.

---

## ADR-001 — Code name: Mani

**Status.** Accepted.

**Context.** Need a project name. Initial proposals: Floke (Norwegian for
"tangle/knot"), Sjonglør ("juggler"), Mani (Norse mythology, "many",
"manic"), and others. User has Norwegian preference and asked for
"cheeky."

**Decision.** **Mani**, despite documented namespace collisions:
- [alajmo/mani](https://github.com/alajmo/mani) — a CLI tool for
  managing multiple git repos. Adjacent product space.
- npm `mani` — a JS search library. Package name unavailable.
- 5+ App Store apps named "Mani" (mostly finance/wellness).
- VS Code marketplace has a "mani Project Manager" extension.

**Rationale.** User preference. The product is a Mac GUI, not a CLI, which
differentiates from alajmo/mani. The cheek is real (Mani = many = manic
chaos that the app tames). Risks accepted, mitigations below.

**Implications.**
- Distribution **binary** name must not be plain `mani` (Homebrew/MacPorts
  collide). Likely `mani-app` or distribute as `.app` only with no CLI.
  See ADR-011.
- Bundle identifier should be distinctive: e.g.,
  `no.<userhandle>.mani`. Avoid `com.mani.*`.
- Domain: `mani.app` is taken. Realistic: `getmani.app`, `usemani.com`,
  `mani.no` (Norwegian TLD, on-theme).
- This is a **code name**. Final naming may shift before public release.
  Don't lock in domains/cert/store IDs prematurely.

---

## ADR-002 — SwiftTerm before libghostty

**Status.** Accepted for v0.1.

**Context.** Three viable terminal-core options for a Mac native app:
SwiftTerm (pure Swift, no FFI), libghostty (Zig core, embeddable C API),
or alacritty_terminal (Rust crate, render-it-yourself).

**Decision.** SwiftTerm in v0.1. libghostty added in v0.2+ behind the
same `TerminalRenderer` protocol.

**Rationale.**
- Terminal isn't the product; orchestration is. SwiftTerm gets us there
  faster: no Zig toolchain, no FFI, no upstream-rebase tax. Pure Swift
  drop-in to AppKit/SwiftUI.
- libghostty's public API isn't stable yet (per Mitchell). Pinning is
  feasible but ongoing work.
- Performance ceiling lower than GPU-accelerated alternatives, but
  adequate for Claude Code workloads (mostly text).
- Protocol seam (`TerminalRenderer`) keeps the swap reversible.

**Implications.**
- Spike 1 must validate SwiftTerm's actual performance on plausible
  workloads. If it fails, escalate before pivoting.
- v0.1 inherits SwiftTerm's capability set: ANSI/256/truecolor, mouse,
  partial OSC 8, no Sixel/Kitty graphics.
- Don't put SwiftTerm-specific types in `ManiCore`. The library stays
  Foundation-only.

---

## ADR-003 — `Job` is the type name; "Task" is the user-facing name

**Status.** Accepted.

**Context.** The domain concept is a "task" (Claude session, shell, or
shell + helpers). Swift has `_Concurrency.Task` in the standard library,
auto-imported. Defining `struct Task` in our module would create
constant ambiguity at call sites for `Task { await ... }`.

**Decision.** Type is `Job` in code. UI labels and conversation say
"task." A note in `Sources/ManiCore/Model/Job.swift` records this.

**Rationale.**
- `_Concurrency.Task { }` qualification at every async-block site is
  unergonomic and error-prone.
- The translation cost is bounded — only UI/view code maps `Job` ↔ "Task,"
  and that's a small layer.
- Alternative names (`Activity`, `Stream`, `Workstream`, `MTask`) all have
  worse tradeoffs.

**Implications.**
- `JobPath`, `JobKind`, `JobStatus` follow.
- In tests and documentation, refer to "Job" when discussing code,
  "task" when discussing product behavior.
- **Do not rename Job back to Task.** The conflict will resurface.

---

## ADR-004 — Both `.git` worktrees and `.folder` worktrees

**Status.** Accepted.

**Context.** User has both real `git worktree` setups *and* manually-created
"parallel folder hierarchies" for some projects. Both need to be first-class.

**Decision.** `WorktreeKind = .git(branch, baseRef?) | .folder`. Both flow
through the same `Worktree` struct.

**Rationale.** Matches the user's actual workflow. Distinguishing means
the UI can offer git-specific operations (merge status, branch switch)
only when meaningful, while still supporting non-git use.

**Implications.**
- `Effect.createGitWorktree` exists; for `.folder`, create the directory
  directly (no git plumbing).
- "Missing worktree" detection runs for both kinds.
- Branch info on `.git` worktrees: surface in the sidebar.

---

## ADR-005 — Both filesystem watcher AND hooks for Claude integration

**Status.** Accepted.

**Context.** Need to know when Claude sessions start, go idle, end.
Available channels: tail-watch the JSONL files in `~/.claude/projects/`,
or register Claude Code hooks via `settings.json`.

**Decision.** Implement both.

**Rationale.**
- Watcher: comprehensive, sees everything written to disk, including
  manual `claude` invocations outside Mani.
- Hooks: sub-second latency on session-state changes; needed for
  responsive idle/notification UX.
- Each catches what the other misses (see `docs/claude-integration.md`
  § "Why both").

**Implications.**
- Idempotency required: same state change may arrive on either channel
  first.
- v0.1 scope grows by ~3–4 days for hooks. Cut-down option: watcher
  only. Loses sub-second responsiveness; keeps linkage and history.

---

## ADR-006 — App-owned data; nothing in user repos

**Status.** Accepted.

**Context.** Where to put state, scrollback, archives, settings.

**Decision.** `~/Library/Application Support/Mani/` owns all Mani state.
No `.mani` files in user repos. No global config beyond what's in
Application Support.

**Rationale.**
- Avoids polluting user repos with Mani-specific files.
- Simpler permissions and backup story.
- One place to wipe / migrate / inspect.

**Implications.**
- Project metadata is not portable across machines without explicit
  export. Acceptable for a local single-user tool.
- Worktree paths in state are absolute — moving the repo breaks them
  until the user updates the worktree.
- Per-cwd `.claude/settings.json` is one *small* exception we may use for
  Claude hooks scoped to a worktree (TBD with user, ADR-013 if/when).

---

## ADR-007 — Compile-exhaustive switches, no `default:` for our enums

**Status.** Accepted.

**Context.** Reducer/apply/UI code switches over `Action`, `Event`,
`Effect`, etc. Using `default:` silently absorbs new cases.

**Decision.** Never use `default:` on our enums in switches. Unhandled
cases must be listed by name (`case A, B, C: return ([], [])`).

**Rationale.**
- Adding a new case is a real bug source if existing call sites silently
  ignore it.
- Compile-exhaustiveness gives us a free, accurate "where do I need to
  handle this?" check.
- The cost is small — listing cases by name in a stub block.

**Implications.**
- All Action/Event/Effect handlers must be updated when a new case is
  added.
- This includes test code (less critical there but consistent).
- Apply this convention to other internal enums too (JobStatus,
  JobKind, WorktreeKind).

---

## ADR-008 — macOS 14 minimum

**Status.** Accepted.

**Context.** Platform target choice. User on macOS 15 (Sequoia). SwiftTerm
supports back to 12.

**Decision.** macOS 14 (Sonoma) minimum.

**Rationale.**
- User isn't constrained.
- Modern SwiftUI APIs (Observation framework on 17, scene phases, etc.)
  are nicer.
- No compelling reason to support older.

**Implications.**
- Free use of `Observable`, modern SwiftUI navigation, etc.
- May need to bump if a key dependency requires newer.

---

## ADR-009 — Per-project color in chrome only, never in the terminal viewport

**Status.** Accepted.

**Context.** User wants strong, consistent visual project identity for
cognitive grouping across many concurrent projects.

**Decision.** Color appears as: 3 px sidebar left border, 6–8 px band
above content, project-tinted breadcrumb. Terminal viewport is neutral.

**Rationale.**
- Tinting the terminal background or text breaks vim/tmux/colored CLI
  output. That's user-hostile, not theming.
- Chrome-level color is enough peripheral-vision anchor for the user's
  stated goal.
- Keeps "theming" (a v0.2+ concern) cleanly separable.

**Implications.**
- Color picker offers 8–12 hand-picked swatches plus hex input. **No
  auto-assignment** — user picks deliberately.
- Status indication uses both color AND a glyph (• ⏸ ⏹ ✓ ✗) for
  accessibility.

---

## ADR-010 — Action / Event / Effect (three types, not two)

**Status.** Accepted.

**Context.** Standard reducer patterns use `(State, Action) → State` and
sometimes a side-effects channel. With persistence and crash recovery,
we need a clean separation between "what was wanted" and "what
happened."

**Decision.** Three types:
- `Action` — intent (UI dispatch, system response). May be invalid.
- `Event` — fact (durable, persisted, replayable).
- `Effect` — I/O (process spawn, fs writes, retries).

`reduce(state, action) → ([Event], [Effect])`.
`apply(&state, event) → ()`.

**Rationale.**
- Pure reducer: testable, no async.
- Durable event log: persistence is straightforward, recovery is just
  replay through `apply`.
- Effects isolated: I/O failures don't leak into state machinery.
- The cost (verbosity) pays off the first time you crash mid-spawn.

**Implications.**
- More types and more code than a two-stage reducer.
- The same `apply` runs in live operation and in recovery. Don't add
  `if recovering` branches in `apply`.

---

## ADR-011 — Distribution name TBD, defer commitment

**Status.** Open, decision deferred.

**Context.** Code name "Mani" collides with packaged tools on Homebrew,
MacPorts, npm. Need a binary name that doesn't.

**Decision.** Defer. For v0.1, run unsigned, locally-built `.app`. No CLI
shipped. Pick a distribution name (and probably a final product name)
before any public release.

**Rationale.** Premature commitment to e.g. `mani-app` would cost
nothing to defer and might end up wrong if we rename the product
entirely.

**Implications.**
- Internally, refer to the product as Mani. Don't burn cycles on
  branding work yet.
- Bundle identifier still needs to be distinctive — see ADR-001. Pick
  something forward-compatible (e.g., a domain you control) so it
  survives a rename.

---

## ADR-012 — SwiftPM library now; Xcode app target later

**Status.** Accepted.

**Context.** Mac app needs an Xcode app target eventually (bundle,
Info.plist, code signing, capabilities). Model code is pure Swift with
no UI.

**Decision.** Start with `ManiCore` Swift Package only. Add Xcode app
target (`Mani.xcodeproj`) when starting spike 1.

**Rationale.**
- Model layer is testable from CLI immediately.
- Xcode setup (project file, schemes, signing) is real complexity, not
  needed yet.
- Two-target structure (`ManiCore` library + `ManiApp` app target)
  enforces the architectural boundary by build dependency.

**Implications.**
- AppKit, SwiftUI, FSEvents, Process, etc. live outside `ManiCore`.
- Adding the app target later: open `Package.swift` in Xcode, then
  File → New → Project → macOS App, save it inside `~/pr/mani/App/`,
  and add `ManiCore` as a local package dependency.

---

## ADR-013 (provisional) — Hook scope: global vs per-cwd

**Status.** Open. Not yet decided.

**Context.** Claude Code reads hooks from both `~/.claude/settings.json`
(global) and per-cwd `.claude/settings.json` (project-local). Either or
both can register Mani's shim.

**Decision (proposed).** Global for v0.1: simpler, single registration
covers all sessions. Per-cwd as a v0.2 option for users who want Mani
hooks scoped to specific projects.

**Rationale.** Per-cwd has cleaner semantics but requires writing into
each user repo (violates ADR-006 in spirit). Global is single-source.

**Open questions.**
- Does writing into `~/.claude/settings.json` raise concerns if the user
  has hand-tuned hooks there? (Mitigation: merge, don't overwrite —
  see `docs/claude-integration.md`.)
- Does the user want per-cwd as the default for some workflow?

**Action.** Confirm with user before implementing.

---

## ADR-014 — No tab strip; the sidebar is the only navigation

**Status.** Accepted (supersedes the earlier provisional "tabs scoped to
worktree" proposal).

**Context.** The original v0.1 plan assumed a per-worktree tab strip
above the terminal viewport (showing the worktree's tasks as tabs).
After implementing it the user pushed back: with the sidebar already
showing the full Project → Worktree → Task tree, the tab strip is
duplicate navigation.

**Decision.** No tab strip. The sidebar list is the single source of
navigation. Selecting a job in the sidebar swaps the terminal pane in
the detail column.

**Rationale.**
- One nav surface, one selection model. Easier to reason about.
- The sidebar already groups jobs under their worktree, so worktree
  context is visually present.
- Skipping tabs cuts UI work and removes a small divergence between
  "sidebar selection" and "tab selection" that we'd have to keep in sync.

**Implications.**
- Don't add tabs unless the user revisits this decision.
- Cmd-Shift-]/[ for "next/prev task" (if added) cycles through the
  flattened task list shown in the sidebar, not a tab strip.
