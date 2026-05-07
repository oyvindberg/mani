# Git worktree failure modes (Spike 7)

How `Effect.createGitWorktree` should handle the realistic failure cases
of `git worktree add`. Captured by running `Spikes/GitWorktreeSpike/probe.sh`
against git 2.x on macOS.

For each case: real git stderr, exit code, and Mani's intended response.

---

## 1. Branch already checked out elsewhere

```
$ git -C repo worktree add /tmp/wt-feat-2 feat
Preparing worktree (checking out 'feat')
fatal: 'feat' is already used by worktree at '/tmp/wt-feat'
```

Exit code: **128**.

**Mani's response.** Surface the git stderr verbatim plus a one-line
plain-language summary: *"`feat` is already checked out at `/tmp/wt-feat`.
Pick a different branch, or open the existing worktree."* Offer two
buttons: "Open existing worktree" (if Mani knows about it) and "Pick a
different branch."

---

## 2. Base ref doesn't exist

```
$ git -C repo worktree add /tmp/wt-bad -b feat does-not-exist
fatal: invalid reference: does-not-exist
```

Exit code: **128**.

**Mani's response.** Validate the base ref *before* calling git via
`git rev-parse --verify <ref>` so we surface this as a form-validation
error in the new-worktree dialog rather than a post-hoc failure.
If the user fights us through it, surface git stderr verbatim.

---

## 3. Worktree directory deleted externally

```
$ rm -rf /tmp/wt-feat
$ git -C repo worktree list
/tmp/repo            90770e8 [main]
   # (the missing wt-feat is gone from the list — git auto-prunes when listing? sometimes.)

$ git -C repo worktree add /tmp/wt-feat feat
Preparing worktree (checking out 'feat')
HEAD is now at 90770e8 init
   # exit 0 — git happily recreates from stale metadata
```

But if metadata is stale and we try to `add --force` to the same path
*after* the directory has been recreated by an earlier `add`:

```
$ git -C repo worktree add --force /tmp/wt-feat feat
fatal: '/tmp/wt-feat' already exists
```

**Mani's response.** When Mani detects a worktree's `path` no longer
exists on disk (via `markWorktreeMissing`), the user-facing affordance is
*"Recreate worktree."* That action runs `git worktree prune` first (cleans
stale metadata) and then `git worktree add <path> <branch>`. The first add
after a `rm -rf` works without `--force`; don't use `--force` reflexively
because it has subtly different semantics (it fights existing dirs).

---

## 4. Dirty index in source repo

```
$ echo dirty > repo/README.md
$ git -C repo status --short
 M README.md
$ git -C repo worktree add /tmp/wt-from-dirty -b feat
Preparing worktree (new branch 'feat')
HEAD is now at 90770e8 init
```

Exit code: **0**.

**Mani's response.** No special handling — git creates the worktree from
HEAD; the dirty index in the source repo isn't propagated. This is
expected and correct.

---

## 5. Submodule-containing repo

```
$ git -C repo worktree add /tmp/wt-with-sub -b feat
Preparing worktree (new branch 'feat')
HEAD is now at cf6b53b add submodule
$ ls /tmp/wt-with-sub/sub
   # empty — submodule directory is *not* populated
```

Exit code: **0** (but the result is incomplete).

**Mani's response.** After `git worktree add`, if the resulting working
copy contains a `.gitmodules`, follow up with
`git submodule update --init --recursive` *inside the new worktree*.
Surface a "Initializing submodules…" status while it runs; treat its
failure non-fatally (worktree is usable, submodules just aren't checked
out).

---

## 6. Worktree against a bare repo

```
$ git init --bare -b main /tmp/bare
$ git -C bare worktree add /tmp/wt-from-bare main
Preparing worktree (checking out 'main')
HEAD is now at 5bc6c4b init
```

Exit code: **0**.

**Mani's response.** Works as expected. Bare repos are a legitimate
workflow ("clone once, multiple worktrees") and should be supported
without special handling. The `Project.rootDir` may point at a `.git`
bare dir; the `Worktree.path` points at the actual checkout.

---

## 7. Same path twice

```
$ git -C repo worktree add /tmp/wt-collide feat       # first time, OK
$ git -C repo worktree add /tmp/wt-collide -b other   # second time
fatal: '/tmp/wt-collide' already exists
```

Exit code: **128**.

**Mani's response.** Validate path doesn't exist on disk *before* calling
git, in the new-worktree dialog. If the user types a path that exists,
surface that as a form-validation error with two options: "Pick another
path" or "Use existing folder as a `.folder` worktree" (which doesn't
involve `git worktree add` at all).

---

## 8. Two Mani instances racing on the same path

Not directly tested. v0.1 is single-instance (NSApp single-instance
guard). If a future v0.2+ allows multi-instance, the same-path case
becomes case 7 plus the question of who wrote the `state.json` entry
first. Mitigation: a process-wide lockfile under
`~/Library/Application Support/Mani/.lock`.

---

## Implementation notes for `Effect.createGitWorktree`

Effect runner pseudocode:

1. **Pre-check** (in the reducer or at the dialog layer, *before* dispatch):
   - Validate base ref via `git rev-parse --verify`.
   - Validate target path doesn't exist.
   - Validate branch name isn't already in use by another worktree
     (`git worktree list --porcelain | grep "branch refs/heads/<name>"`).
2. **Dispatch** the effect.
3. **Effect runner**:
   - Run `git worktree prune` (cheap, makes the next add forgiving).
   - Run `git worktree add <path> <branch>` (or `-b new-branch base-ref`).
   - On non-zero exit: dispatch a `worktreeCreateFailed` action carrying
     git stderr verbatim. The store records this and surfaces it in the UI.
   - On zero exit: if a `.gitmodules` is present, run
     `git submodule update --init --recursive` inside the worktree.
   - On success: dispatch `processStarted`/etc. as needed for any
     auto-spawned task in the new worktree.

Surface git stderr verbatim in error dialogs — don't paraphrase. Pair it
with a one-sentence plain-language summary that names the recovery path.
