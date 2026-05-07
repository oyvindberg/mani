# Coding rules

Project-specific conventions on top of standard Swift style. These come
from explicit user preferences plus architectural constraints; treat them
as load-bearing.

## 1. No default parameters

> The user's global rule: "Never use default parameters in Scala or any
> language."

Applies in Swift too. Concretely:

```swift
// ✗ no
public init(name: String, color: String = "#888888") { ... }

// ✓ yes — explicit at every call site
public init(name: String, color: String) { ... }
```

Why: defaults hide intent at call sites and bite during refactors.
Auto-synthesized memberwise initializers don't have defaults, so they're
fine — you only run into this when writing custom inits or function
declarations.

If an "optional with default" feels right, make the parameter `Optional`
and let the caller pass `nil` explicitly. That keeps the call site honest.

## 2. Compile-exhaustive switches over our enums

```swift
// ✗ no
switch action {
case .createProject: ...
default: return ([], [])
}

// ✓ yes — every unhandled case named explicitly
switch action {
case .createProject: ...
case .renameProject,
     .deleteProject,
     .createWorktree,
     // … list every other case
     .processExited:
    return ([], [])
}
```

Applies to: `Action`, `Event`, `Effect`, `JobStatus`, `JobKind`,
`WorktreeKind`, and any new enums in `ManiCore`.

Why: adding a new case must fail compilation everywhere it's not handled.
Catches a real bug class with no runtime cost.

`default:` is fine for non-`ManiCore` enums (e.g., AppKit/SwiftUI types
where exhaustive listing isn't valuable).

## 3. Default to no comments

Most code should have no comments. Names carry the meaning.

Add a one-line comment **only** when:
- The *why* is non-obvious to a reader who has the file in front of them.
- A subtle invariant or workaround needs to be preserved.
- A hidden constraint would otherwise surprise a future reader.

Don't add comments that:
- Restate what the code does (it's already there).
- Reference the current task ("added for the X feature").
- Explain who called it ("used by Y") — this rots fast.
- Are tutorial-style ("here we iterate over the projects…") — tutorial
  belongs in `docs/`, not in source.

The `Job.swift` comment about the rename is a fair exception: a
non-obvious decision about the name itself, useful to readers, won't rot.

## 4. Public access is explicit

`ManiCore` is a library. API used by the app target must be marked
`public`. Internal-only helpers stay un-marked (default `internal`).

Don't blanket-public everything to "make life easier" — that turns the
public surface into a swamp and costs at every refactor.

## 5. Test naming

```
test_<scenario>_<expectedOutcome>
```

Examples:
- `test_createProject_emitsEventAndPersistEffect`
- `test_setProjectEnabled_disabled_cascadesTerminations`
- `test_setProjectEnabled_unknownProject_isNoop`

Read as: "test that {scenario} → {outcome}." Avoid bare verbs
(`testCreateProject`); avoid bare descriptions
(`testProjectCreationWorks`). The full pattern makes intent explicit.

## 6. File-per-type for model code

`Sources/ManiCore/Model/Project.swift` — one type. Companion enums
declared in the same file are fine if they're trivially small and only
used by that type (e.g., `WorktreeKind` lives in `Worktree.swift`).

Don't dump multiple model types into one file. The diff cost is small;
the navigation cost of "which file holds X?" is real.

## 7. No comments inside enums

Don't annotate enum cases with `///` or `//` describing each case. The
case name is the documentation. If a case needs explanation, put it in
the corresponding doc file (`docs/architecture.md` etc.).

## 8. Long-running shell commands redirect to a file

> User's rule: "Always redirect command output to a file. Never use `|
> tail -15` or pipe-to-grep on long-running commands — the pipe blocks,
> output gets lost, and you can't check progress."

When shelling out from tooling/scripts/spikes:

```sh
# ✗ no
swift test | grep PASS

# ✓ yes
swift test 2>&1 > /tmp/mani-test.out
grep PASS /tmp/mani-test.out
```

For long-running shells from Swift code (`Process` / `posix_spawn`):
capture output to a file or stream into a managed buffer. Don't pipe
through ad-hoc `Pipe()` inside a sync wait.

## 9. Don't add features beyond v0.1 scope without asking

User rule, repeated here for prominence. The temptation is real. If you
think a feature is "easy to add" and "almost free," that's a signal to
stop and confirm.

Common scope-creep traps to avoid:
- Theming (forbidden by ADR-009 — terminal viewport stays neutral).
- Multiple windows.
- Plugin/extension system.
- Cloud sync, backup-to-cloud.
- Telemetry of any kind.
- A CLI alongside the GUI.

## 10. Don't commit unless asked

User controls commit cadence. Make changes, run tests, report; the user
commits.

If the user asks for a commit, follow the standard commit instructions in
`CLAUDE.md` (Co-Authored-By line, etc.).

## 11. Don't use `Foundation`'s deprecated `URL(fileURLWithPath:)` style sloppily

For new code, prefer:

```swift
URL(filePath: "/Users/oyvind/pr/mani", directoryHint: .isDirectory)
```

over the older `URL(fileURLWithPath:)` when on macOS 13+. We're on macOS
14+, so use the new APIs.

Existing tests use `URL(fileURLWithPath:)` — leave them, but don't add
new uses.

## 12. Errors at the boundary, asserts internally

- **At system boundaries** (file I/O, network, process spawn): errors are
  expected. Use `throws` and return them.
- **Internal to `ManiCore`**: invariants are *invariants*. If "this
  worktree must have a project" can be violated, that's a bug — use
  `assertionFailure` (debug crash + release no-op) or a `precondition`,
  not a thrown error.

Reducers don't throw. They return `([], [])` for invalid actions
(see `docs/architecture.md` § "Validation philosophy").

## 13. Sendable

Swift 6 strict concurrency may surface `Sendable` warnings. Prefer
`Sendable` conformance for value types in `ManiCore` — they're plain
data, conformance is free. For now we're on tools-version 5.10 which
doesn't enforce strict concurrency, so leave it implicit. If you bump to
Swift 6 mode, add explicit `Sendable` where the compiler asks.

## 14. Avoid `@MainActor` in `ManiCore`

`ManiCore` is pure data + functions; it has no UI affinity. If a type
needs `@MainActor`, it doesn't belong here — it belongs in the app target.

Reducer is a free function, not a method on an actor. The store is the
`@MainActor`-bound thing, and the store lives in the app target.

## 15. No third-party dependencies in `ManiCore`

`ManiCore` is Foundation-only. SwiftTerm, SwiftCrypto, async-libraries,
etc., live in the app target.

If you find yourself wanting `XYZ` in `ManiCore`, the answer is almost
always "implement it locally" or "move the code to the app target."

## 16. README discipline

Don't add a `README.md` at the repo root unless asked. The orientation
doc is `PLAN.md`; the user-facing entry is whatever the website /
distribution will be.
