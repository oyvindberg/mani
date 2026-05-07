# CLAUDE.md

You are working on **Mani**, a macOS app for orchestrating multiple concurrent
coding sessions (Claude Code + shells) across multiple projects and worktrees,
with crash-resilient state persistence.

## Before doing non-trivial work

**Read [PLAN.md](PLAN.md) first.** It's the orientation doc. The detailed
design lives in `docs/`. The plan and decisions encode many tradeoffs; do not
re-litigate without reading the rationale.

## Stack

- Swift 5.10+ toolchain (Swift 6 OK), macOS 14+ target
- Swift Package now (`ManiCore` library); Xcode app target added when starting spike 1
- SwiftTerm as the terminal renderer (libghostty deferred to v0.2+)
- Pure-Swift, Foundation-only inside `ManiCore`. AppKit/SwiftUI lives outside it.

## Verify locally

```sh
swift build       # ~6s clean
swift test        # ~7s clean, 4 tests
```

If you change the public API of `ManiCore`, update tests in the same change.

## Hard rules (do not violate without asking the user)

1. **No default parameters anywhere.** User's global rule. Every initializer
   and function takes its arguments explicitly. Auto-synthesized memberwise
   inits are fine because they have no defaults.
2. **Switches over our enums must be compile-exhaustive.** Never use
   `default:` for `Action`, `Event`, `Effect`, `JobStatus`, `JobKind`,
   `WorktreeKind`. List every unhandled case by name. Adding a new case must
   fail compilation until every consumer handles it.
3. **`Job` is the type name for what we call "task" in UI and conversation.**
   Renamed because Swift's `_Concurrency.Task` would create constant
   ambiguity. Don't rename it back.
4. **Don't theme the terminal viewport.** Per-project color goes in chrome
   only (sidebar border, band above content, breadcrumb). The terminal grid
   stays neutral so vim/tmux/colored CLI output isn't broken.
5. **Don't commit unless the user explicitly asks.** The user controls the
   commit cadence and message style.
6. **Don't expand v0.1 scope without asking.** See [PLAN.md](PLAN.md) §
   "v0.1 scope" for what's in and out. The temptation to add things is real;
   resist.

## Coding conventions

- Public API on `ManiCore` types is explicit (`public` keyword). If a type or
  function is internal-only, leave the access modifier off.
- Default to no comments. Add a one-line comment only when the *why* is
  non-obvious to a reader who has the file in front of them.
- Test names: `test_<scenario>_<expectedOutcome>`. Run them locally, do not
  rely on CI.
- File-per-type for model code. Reducer/Apply functions live in
  `Reducer.swift`. Don't grow that file past ~300 lines without splitting.
- Long-running shell commands in tooling redirect to a file
  (`cmd 2>&1 > /tmp/foo.out`); never pipe them to `tail` or `grep`. User rule.

## Where things live

```
Sources/ManiCore/
  Model/                  # AppState, Project, Worktree, Job, ProcessSpec
  Paths.swift             # WorktreePath, JobPath
  Action.swift            # user/system intents
  Event.swift             # durable facts (persisted to events.jsonl)
  Effect.swift            # side effects (process spawn, fs writes, …)
  Reducer.swift           # reduce(state, action) → (events, effects)
                          # apply(&state, event)
Tests/ManiCoreTests/      # XCTest, pure data-in-data-out
```

Anything that needs AppKit, SwiftUI, FSEvents, or process I/O does *not* go
in `ManiCore`. Add a new target (e.g. `ManiApp`) for those.

## When in doubt

- The architectural choices are written down. If a choice you're considering
  contradicts `docs/decisions.md`, surface that to the user before acting.
- The spike list (`docs/spikes.md`) is ordered by risk. Don't skip ahead.
- "Trust but verify" — the user reviews diffs. Make changes small and
  reviewable.
