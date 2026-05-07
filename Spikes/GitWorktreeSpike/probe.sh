#!/usr/bin/env bash
# Spike 7: enumerate git-worktree failure modes and capture git's actual stderr.
# Output is consumed into docs/git-worktree-failures.md.

set -u
SANDBOX=/tmp/mani-git-spike
rm -rf "$SANDBOX"
mkdir -p "$SANDBOX"
cd "$SANDBOX"

dump() {
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "$1"
    echo "════════════════════════════════════════════════════════════"
}

# Helper: init a tiny non-bare repo at $SANDBOX/repo with one commit on main.
init_repo() {
    rm -rf "$SANDBOX/repo"
    mkdir "$SANDBOX/repo"
    cd "$SANDBOX/repo"
    git init -q -b main
    git config user.email spike@example.com
    git config user.name "Spike"
    echo hello > README.md
    git add README.md
    git commit -q -m "init"
    cd "$SANDBOX"
}

# 1. Branch already checked out elsewhere.
init_repo
dump "1. Branch already checked out elsewhere"
git -C repo branch feat 2>&1
git -C repo worktree add "$SANDBOX/wt-feat" feat 2>&1   # OK, first time
echo "--- second add of 'feat' from primary repo (still checked out in wt-feat) ---"
git -C repo worktree add "$SANDBOX/wt-feat-2" feat 2>&1
echo "exit=$?"

# 2. Base ref doesn't exist.
init_repo
dump "2. Base ref doesn't exist"
git -C repo worktree add "$SANDBOX/wt-bad" -b feat does-not-exist 2>&1
echo "exit=$?"

# 3. Worktree directory deleted externally.
init_repo
dump "3. Worktree directory deleted externally"
git -C repo branch feat 2>&1
git -C repo worktree add "$SANDBOX/wt-feat" feat 2>&1
rm -rf "$SANDBOX/wt-feat"
echo "--- after rm -rf, worktree list still records it: ---"
git -C repo worktree list 2>&1
echo "--- recreating same path ---"
git -C repo worktree add "$SANDBOX/wt-feat" feat 2>&1
echo "exit=$?"
echo "--- with --force ---"
git -C repo worktree add --force "$SANDBOX/wt-feat" feat 2>&1
echo "exit=$?"
echo "--- prune approach ---"
git -C repo worktree prune 2>&1
git -C repo worktree add "$SANDBOX/wt-feat" feat 2>&1
echo "exit=$?"

# 4. Dirty index in source repo.
init_repo
dump "4. git worktree add against a dirty index"
echo dirty > "$SANDBOX/repo/README.md"
git -C repo status --short 2>&1
git -C repo worktree add "$SANDBOX/wt-from-dirty" -b feat 2>&1
echo "exit=$?"

# 5. Submodule-containing repo.
init_repo
dump "5. Worktree on a repo with a submodule"
# Make a submodule source.
mkdir -p "$SANDBOX/sub-source"
cd "$SANDBOX/sub-source"
git init -q -b main
git config user.email spike@example.com
git config user.name "Spike"
echo sub > sub.txt
git add sub.txt
git commit -q -m "sub"
cd "$SANDBOX"
git -C repo -c protocol.file.allow=always submodule add "$SANDBOX/sub-source" sub 2>&1
git -C repo commit -q -m "add submodule"
git -C repo worktree add "$SANDBOX/wt-with-sub" -b feat 2>&1
echo "exit=$?"
echo "--- does the new worktree have the submodule populated? ---"
ls -la "$SANDBOX/wt-with-sub/sub" 2>&1
echo "--- (would need 'git submodule update --init' inside worktree) ---"

# 6. Worktree against a bare repo.
init_repo
dump "6. Worktree against a bare repo"
rm -rf "$SANDBOX/bare"
git init --bare -q -b main "$SANDBOX/bare"
echo "--- pushing one commit so the bare repo has 'main' ---"
git -C repo push -q "$SANDBOX/bare" main 2>&1
git -C bare worktree add "$SANDBOX/wt-from-bare" main 2>&1
echo "exit=$?"

# 7. Same-path collision (single-instance, but exercise add-twice from same Mani).
init_repo
dump "7. Same path twice (collision)"
git -C repo branch feat 2>&1
git -C repo worktree add "$SANDBOX/wt-collide" feat 2>&1
echo "--- second add to same path ---"
git -C repo worktree add "$SANDBOX/wt-collide" -b other 2>&1
echo "exit=$?"

dump "DONE"
