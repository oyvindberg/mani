import Foundation
import ManiCore

// The only place I/O happens. Owns the live TaskIO instances keyed by
// TaskPath, drives PersistenceStore, and dispatches actions back to the
// Store via the closure passed in.
//
// docs/architecture.md § "The effect runner".

actor EffectRunner {
    private let persistence: PersistenceStore
    private let host: ProcessHost
    private var ptys: [TaskPath: TaskIO] = [:]
    private var scrollbacks: [TaskPath: ScrollbackWriter] = [:]
    private var scrollbackSubscriptions: [TaskPath: IOSubscription] = [:]

    init(persistence: PersistenceStore, host: ProcessHost) {
        self.persistence = persistence
        self.host = host
    }

    private var scrollbackRoot: URL {
        persistence.rootDir.appendingPathComponent("tasks")
    }

    func pty(for path: TaskPath) -> TaskIO? {
        ptys[path]
    }

    // Lookup by task id alone — the remote v0.2 protocol identifies
    // tasks by UUID, not the full repo/project/task path. Linear scan
    // is fine because the dict typically holds ≤ a few dozen entries.
    func pty(taskId: UUID) -> TaskIO? {
        for (path, pty) in ptys where path.task == taskId {
            return pty
        }
        return nil
    }

    // Drive a size change through the attach PTY. The agent forwards
    // the RESIZE frame to the inner PTY via TIOCSWINSZ.
    func resize(path: TaskPath, rows: UInt16, cols: UInt16) async {
        ptys[path]?.resize(rows: rows, cols: cols)
    }

    // On graceful app quit, do NOT terminate the host's agents — the
    // whole point of detaching them is that processes outlive Mani.
    // Closing our attach client is enough; the agent keeps running.
    func terminateAll() {
        for pty in ptys.values {
            let captured = pty
            _Concurrency.Task.detached {
                if let agent = captured as? AgentClient { agent.close() }
            }
        }
    }

    // Bidirectional boot reconciliation. For every task we probe the
    // host's view of aliveness and reconcile the reducer's runtime:
    //   - .running  + agent alive (attach ok)  → wire pty (no event)
    //   - .running  + agent gone OR attach fail → dispatch .restartTask
    //                                              (auto-respawn — no
    //                                              .exited limbo state)
    //   - .exited   + agent alive (attach ok)  → dispatch .taskSpawned + wire
    //                                              (process outlived Mani)
    //   - .exited   + agent gone OR attach fail → leave alone
    //                                              (user-stopped task,
    //                                              don't auto-respawn)
    //   - .neverStarted + agent alive          → same as .exited + alive
    //                                              (legacy migration fix)
    //   - .neverStarted + agent gone           → leave alone (external
    //                                              claudes, brand-new
    //                                              tasks awaiting spawn)
    //   - .completed                           → leave alone (user intent)
    //
    // The .running auto-respawn replaces what used to be an .exited
    // marker + manual user Restart click. Premise: a task whose state
    // says it should be running but whose process is gone is a crash,
    // not a user intention — heal automatically. Crash loops are bounded
    // by .spawn's own catch dispatching .taskExited (no infinite loop).
    func reconcileRuntime(
        state: AppState,
        dispatch: @escaping (Action) async -> Void
    ) async {
        for repo in state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    let path = TaskPath(
                        repo: repo.id, project: project.id, task: task.id
                    )
                    switch task.runtime {
                    case .running:
                        let attached = await host.isAlive(taskId: task.id)
                            ? await attachAndWire(path: path, dispatch: dispatch)
                            : false
                        if !attached {
                            await dispatch(.restartTask(at: path))
                        }
                    case .exited, .neverStarted:
                        if await host.isAlive(taskId: task.id),
                           await attachAndWire(path: path, dispatch: dispatch) {
                            await dispatch(.taskSpawned(at: path, when: Date()))
                        }
                    case .completed:
                        break
                    }
                }
            }
        }
    }

    // Add per-task env overrides at spawn time. Currently: HISTFILE,
    // so each Mani-spawned zsh records its own shell history under
    // tasks/<task-id>/zsh_history instead of clobbering the user's
    // global ~/.zsh_history. We set it whenever the command is a
    // POSIX shell (zsh/bash/ksh); fish doesn't honor HISTFILE and
    // claude tasks immediately type their `claude` command into the
    // shell, so any history captured for those is harmless noise.
    // The env override is NOT persisted on the Task's spec — it's
    // re-applied on every spawn — so older tasks pick this up on
    // their next Restart without a migration.
    private func augmentEnvForTask(spec: ProcessSpec, taskId: UUID) -> ProcessSpec {
        let cmd = (spec.command as NSString).lastPathComponent
        let isShell = (cmd == "zsh" || cmd == "bash" || cmd == "ksh")
        guard isShell, spec.env["HISTFILE"] == nil else { return spec }
        let dir = scrollbackRoot.appendingPathComponent(taskId.uuidString)
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true
        )
        var env = spec.env
        env["HISTFILE"] = dir.appendingPathComponent("zsh_history").path
        return ProcessSpec(
            command: spec.command,
            args: spec.args,
            env: env,
            cwd: spec.cwd,
            initialInput: spec.initialInput
        )
    }

    // Open an attach handle to a live agent and wire its onExit /
    // scrollback subscription the same way .spawn does. Used by
    // boot reconciliation when we discover an existing agent and
    // need the pty to be immediately available to the UI. Returns
    // true on a successful attach + wire, false if attach threw
    // (stale socket file with no listener — caller decides whether
    // to respawn).
    private func attachAndWire(
        path: TaskPath,
        dispatch: @escaping (Action) async -> Void
    ) async -> Bool {
        if ptys[path] != nil { return true }
        do {
            let pty = try await host.attach(taskId: path.task)
            ptys[path] = pty
            let runner = self
            pty.onExit = { [weak pty] code in
                _Concurrency.Task {
                    let current = await runner.pty(for: path)
                    if let pty, pty === current {
                        // Auto-respawn on process death. The pty === current
                        // guard skips this when the user intentionally
                        // terminated (which sets ptys[path] = nil before
                        // closing) so user-driven stops aren't re-spawned.
                        await dispatch(.restartTask(at: path))
                    }
                }
            }
            let scrollbackDir = scrollbackRoot
                .appendingPathComponent(path.task.uuidString)
            let scrollbackPath = scrollbackDir
                .appendingPathComponent("scrollback.log").path
            // Pre-seed the pty's capture with the on-disk tail BEFORE
            // anything subscribes. The agent's preConnectBuffer only
            // holds bytes that arrived after the last disconnect (which
            // is empty for a clean detach and only seconds of bytes for
            // a crash), so without this the renderer sees a blank
            // screen on every reattach. Replay happens through the same
            // chunked-async path live bytes use — see
            // AgentClient.scheduleReplay for why synchronous feed
            // hangs libghostty on large buffers.
            if let tail = Self.readScrollbackTail(
                path: scrollbackPath, maxBytes: 512 * 1024
            ) {
                pty.seedCapturedOutput(tail)
            }
            // Don't rotate on recovery — the existing log belongs to
            // the same long-lived process we're reattaching to.
            let writer = ScrollbackWriter(
                path: scrollbackPath, capBytes: 32 * 1024 * 1024
            )
            // replayCaptured: false — the seed we just installed is
            // literally the tail of this same scrollback.log; replaying
            // it through the writer would re-append every byte to disk
            // on every recovery, doubling the log each boot.
            let sub = pty.addOutputHandler(replayCaptured: false) { data in
                writer.append(data)
            }
            scrollbacks[path] = writer
            scrollbackSubscriptions[path] = sub
            return true
        } catch {
            NSLog("[mani] attachAndWire failed for \(path.task): \(error)")
            return false
        }
    }

    private static func readScrollbackTail(
        path: String, maxBytes: Int
    ) -> Data? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        guard let size = try? fh.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? fh.seek(toOffset: start)
        return try? fh.readToEnd()
    }

    func run(_ effect: Effect, dispatch: @escaping (Action) async -> Void) async {
        switch effect {

        case let .persistEvents(events):
            for event in events {
                try? persistence.appendEvent(event)
            }

        case .writeSnapshot:
            break

        case let .spawn(path, spec):
            do {
                try await host.ensureReady()
                // Drop any prior attach client for this path before we
                // touch the agent on disk — its onExit (when the agent
                // socket goes away) must not race against the new pty
                // we're about to install.
                if let prev = ptys[path] {
                    if let agent = prev as? AgentClient { agent.close() }
                    ptys[path] = nil
                }
                // Always start from "no agent on disk" so spawn semantics
                // are unambiguous. If there's a live agent for this id,
                // terminate it and wait for the socket to disappear
                // before launching the replacement. This makes Restart
                // robust against the race where the old agent is still
                // tearing down when the new spawn starts.
                if await host.isAlive(taskId: path.task) {
                    try? await host.terminate(taskId: path.task)
                    let killBy = Date().addingTimeInterval(2.0)
                    while await host.isAlive(taskId: path.task) {
                        if Date() > killBy { break }
                        try? await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                    }
                }
                let augmentedSpec = augmentEnvForTask(spec: spec, taskId: path.task)
                try await host.spawn(taskId: path.task, spec: augmentedSpec)
                let pty = try await host.attach(taskId: path.task)
                ptys[path] = pty
                await dispatch(.taskSpawned(at: path, when: Date()))

                let runner = self
                pty.onExit = { [weak pty] code in
                    _Concurrency.Task {
                        let current = await runner.pty(for: path)
                        if let pty, pty === current {
                            // Auto-respawn — see attachAndWire's onExit for
                            // why the pty === current guard preserves
                            // user-terminate semantics.
                            await dispatch(.restartTask(at: path))
                        }
                    }
                }

                // Tier 1 scrollback: tee the same byte stream the renderer
                // uses into tasks/<task-id>/scrollback.log. On Restart,
                // rotate the existing log so old session bytes don't
                // bleed into the new session's history.
                let scrollbackDir = scrollbackRoot
                    .appendingPathComponent(path.task.uuidString)
                let scrollbackPath = scrollbackDir
                    .appendingPathComponent("scrollback.log").path
                if FileManager.default.fileExists(atPath: scrollbackPath) {
                    let stamp = Int(Date().timeIntervalSince1970)
                    let archived = scrollbackDir
                        .appendingPathComponent("scrollback-\(stamp).log").path
                    _ = try? FileManager.default.moveItem(
                        atPath: scrollbackPath, toPath: archived
                    )
                }
                let writer = ScrollbackWriter(
                    path: scrollbackPath, capBytes: 32 * 1024 * 1024
                )
                let sub = pty.addOutputHandler { data in writer.append(data) }
                scrollbacks[path] = writer
                scrollbackSubscriptions[path] = sub
            } catch {
                NSLog("[mani] host.spawn failed for \(path.task): \(error)")
                await dispatch(.taskExited(at: path, when: Date(), code: -1))
            }

        case let .terminate(at):
            if let pty = ptys[at] {
                if let agent = pty as? AgentClient { agent.close() }
                ptys[at] = nil
            }
            scrollbackSubscriptions[at] = nil
            scrollbacks[at] = nil
            let hostRef = host
            let taskId = at.task
            _Concurrency.Task.detached {
                try? await hostRef.terminate(taskId: taskId)
            }

        case let .userNotification(title, body):
            NotificationService.shared.post(title: title, body: body)

        case let .createGitWorktree(_, repoRoot, branch, path, baseRef):
            await Self.runGitWorktreeAdd(
                repoRoot: repoRoot,
                branch: branch,
                path: path,
                baseRef: baseRef
            )

        case let .fetchAndResetToDefault(at):
            await Self.runFetchAndResetToDefault(at: at)

        case let .removeGitWorktree(repoRoot, path, force):
            await Self.runRemoveGitWorktree(repoRoot: repoRoot, path: path, force: force)

        case let .deleteGitBranch(repoRoot, branch, force):
            await Self.runDeleteGitBranch(repoRoot: repoRoot, branch: branch, force: force)

        case let .ensureGitIgnoreLocal(repoRoot, pattern):
            await Self.runEnsureGitIgnoreLocal(repoRoot: repoRoot, pattern: pattern)

        case .watchClaudeProjects:
            break
        }
    }

    // git worktree remove <path>, then prune metadata. Logs and
    // returns cleanly if the path isn't a worktree or git is upset
    // about a dirty workspace (the UI gates --force separately).
    private static func runRemoveGitWorktree(
        repoRoot: URL, path: URL, force: Bool
    ) async {
        var args: [String] = ["worktree", "remove"]
        if force { args.append("--force") }
        args.append(path.path)
        let result = await runGit(args: args, cwd: repoRoot)
        if result.exit != 0 {
            NSLog("[mani] git worktree remove failed exit=\(result.exit) stderr=\(result.stderr)")
            return
        }
        _ = await runGit(args: ["worktree", "prune"], cwd: repoRoot)
    }

    // git branch -d / -D <branch>. -d refuses unmerged branches;
    // -D forces. Caller (the UI) is responsible for confirming
    // before passing force=true.
    private static func runDeleteGitBranch(
        repoRoot: URL, branch: String, force: Bool
    ) async {
        let flag = force ? "-D" : "-d"
        let result = await runGit(args: ["branch", flag, branch], cwd: repoRoot)
        if result.exit != 0 {
            NSLog("[mani] git branch \(flag) \(branch) failed exit=\(result.exit) stderr=\(result.stderr)")
        }
    }

    // Append `pattern` (one line) to `<repoRoot>/.git/info/exclude` if
    // it isn't already excluded. We use `git check-ignore` to test the
    // current state — that consults the full exclude chain
    // (.gitignore + .git/info/exclude + core.excludesFile), so we
    // won't double-add when the user already has `worktrees/` in a
    // committed .gitignore.
    private static func runEnsureGitIgnoreLocal(repoRoot: URL, pattern: String) async {
        // Probe target: strip the leading slash for check-ignore,
        // which expects a path-like string. e.g. "/worktrees/" → "worktrees/x".
        let probePath: String = {
            let stripped = pattern.drop(while: { $0 == "/" })
            return stripped + "probe"
        }()
        let check = await runGit(args: ["check-ignore", "-q", probePath], cwd: repoRoot)
        if check.exit == 0 {
            // Already ignored somewhere in the chain — nothing to do.
            return
        }
        let excludeURL = repoRoot
            .appendingPathComponent(".git")
            .appendingPathComponent("info")
            .appendingPathComponent("exclude")
        do {
            let existing: String
            if FileManager.default.fileExists(atPath: excludeURL.path),
               let data = try? Data(contentsOf: excludeURL),
               let s = String(data: data, encoding: .utf8) {
                existing = s
            } else {
                existing = ""
            }
            let lines = existing.split(separator: "\n", omittingEmptySubsequences: false)
            // Idempotency belt-and-suspenders: don't append if the
            // exact pattern is already on its own line in
            // info/exclude (covers the case where check-ignore says
            // "no" but the line is there in a non-matching form).
            if lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == pattern }) {
                return
            }
            let needsLeadingNewline = !existing.isEmpty && !existing.hasSuffix("\n")
            let appended = (needsLeadingNewline ? "\n" : "")
                + "# Added by Mani — managed worktrees namespace\n"
                + pattern + "\n"
            // Ensure .git/info/ exists (it should, but be defensive).
            try FileManager.default.createDirectory(
                at: excludeURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = (existing + appended).data(using: .utf8) {
                try data.write(to: excludeURL, options: .atomic)
            }
        } catch {
            NSLog("[mani] ensureGitIgnoreLocal failed: \(error.localizedDescription)")
        }
    }

    // git fetch then `git reset --hard origin/<default>` where
    // <default> is main if it exists on origin, else master. No-op
    // (with a log) if the dir isn't a git checkout or neither branch
    // is on origin — archiving a non-git workspace shouldn't error.
    private static func runFetchAndResetToDefault(at path: URL) async {
        let gitDir = path.appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir.path) else {
            NSLog("[mani] archive fetch+reset skipped: \(path.path) is not a git checkout")
            return
        }
        let fetch = await runGit(args: ["fetch", "--prune"], cwd: path)
        if fetch.exit != 0 {
            NSLog("[mani] archive fetch failed exit=\(fetch.exit) stderr=\(fetch.stderr)")
            return
        }
        let mainExists = await runGit(args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/main"], cwd: path)
        let masterExists = await runGit(args: ["show-ref", "--verify", "--quiet", "refs/remotes/origin/master"], cwd: path)
        let target: String?
        if mainExists.exit == 0 { target = "origin/main" }
        else if masterExists.exit == 0 { target = "origin/master" }
        else { target = nil }
        guard let target else {
            NSLog("[mani] archive reset skipped: neither origin/main nor origin/master exists at \(path.path)")
            return
        }
        let reset = await runGit(args: ["reset", "--hard", target], cwd: path)
        if reset.exit != 0 {
            NSLog("[mani] archive reset failed exit=\(reset.exit) stderr=\(reset.stderr)")
        }
    }

    private static func runGitWorktreeAdd(
        repoRoot: URL,
        branch: String,
        path: URL,
        baseRef: String?
    ) async {
        _ = await runGit(args: ["worktree", "prune"], cwd: repoRoot)

        // `git worktree add` creates the leaf directory but NOT
        // intermediate parents. For managed worktrees living under
        // `<repo>/worktrees/<slug>/`, the `worktrees/` parent may
        // not exist yet — without this mkdir the git invocation
        // fails with "could not create leading directories".
        let parent = path.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        } catch {
            NSLog("[mani] git worktree add: mkdir parent \(parent.path) failed: \(error.localizedDescription)")
            return
        }

        var addArgs = ["worktree", "add", path.path]
        if let baseRef {
            addArgs.append(contentsOf: ["-b", branch, baseRef])
        } else {
            addArgs.append(branch)
        }
        let result = await runGit(args: addArgs, cwd: repoRoot)
        if result.exit != 0 {
            NSLog("[mani] git worktree add failed exit=\(result.exit) stderr=\(result.stderr)")
            // Surface the failure to the user — otherwise the only
            // signal is that the dialog hangs and nothing appears
            // in the sidebar. Most common causes: baseRef doesn't
            // exist (origin/main vs origin/master), branch already
            // exists, or path is non-empty.
            let firstLine = result.stderr
                .split(separator: "\n").first
                .map { String($0) } ?? "git worktree add failed"
            NotificationService.shared.post(
                title: "Couldn't create worktree",
                body: firstLine
            )
            return
        }

        let gitmodules = path.appendingPathComponent(".gitmodules")
        if FileManager.default.fileExists(atPath: gitmodules.path) {
            _ = await runGit(
                args: ["submodule", "update", "--init", "--recursive"], cwd: path
            )
        }
    }

    private static func runGit(args: [String], cwd: URL) async -> (exit: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(exit: Int32, stdout: String, stderr: String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                task.currentDirectoryURL = cwd
                task.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    cont.resume(returning: (
                        task.terminationStatus,
                        String(data: outData, encoding: .utf8) ?? "",
                        String(data: errData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    cont.resume(returning: (-1, "", "\(error)"))
                }
            }
        }
    }

    func compact(_ state: AppState) async {
        try? persistence.compact(state)
    }

    func recover() throws -> AppState {
        try persistence.recover().state
    }
}
