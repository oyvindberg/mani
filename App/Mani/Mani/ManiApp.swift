import SwiftUI
import ManiCore
import Foundation

@main
struct ManiApp: App {
    @StateObject private var store: Store
    @StateObject private var watcher: ClaudeWatcher
    @StateObject private var hookListener: HookListenerService

    // Held so the pollers' Tasks aren't reaped. Started in the WindowGroup
    // .task once the store + initial state are ready.
    private let worktreeStatsPoller: WorktreeStatsPoller
    private let taskStatsPoller: TaskStatsPoller
    private let safekeepingStore: SafekeepingStore
    @StateObject private var sweeper: SafekeepingSweeper
    @StateObject private var archiveCache: SessionArchiveCache = SessionArchiveCache.shared
    @StateObject private var activityTracker = TaskActivityTracker()

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let storeRoot = appSupport.appendingPathComponent("Mani")
        let persistence = try! PersistenceStore(rootDir: storeRoot)
        // Recovery is event-sourced — state.json + replay of any tail
        // events. Per-task aliveness is recomputed against the agent
        // sockets at boot via EffectRunner.reconcileRuntime, so no
        // synthetic state mutation is needed here.
        let initialState = (try? persistence.recover().state) ?? .empty
        // ProcessHost — local tmux for now. SshTmuxHost will share
        // this protocol later. Hard-failing here would be hostile;
        // when tmux is missing we'd surface a "please brew install
        // tmux" empty state and stay alive for the user to install.
        // For the walking skeleton, fall back to a no-op host if
        // tmux is missing so the app still boots.
        let host: ProcessHost = LocalAgentHost.detect()
            ?? UnavailableProcessHost()
        let runner = EffectRunner(persistence: persistence, host: host)
        let store = Store(state: initialState, runner: runner)
        _store = StateObject(wrappedValue: store)

        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path
        _watcher = StateObject(wrappedValue: ClaudeWatcher(reposDir: claudeProjects))

        let socketPath = storeRoot.appendingPathComponent("hook.sock").path
        _hookListener = StateObject(wrappedValue: HookListenerService(socketPath: socketPath))

        worktreeStatsPoller = WorktreeStatsPoller(store: store)
        taskStatsPoller = TaskStatsPoller(store: store)

        let safekeeping = try! SafekeepingStore(appSupportRoot: storeRoot)
        self.safekeepingStore = safekeeping
        _sweeper = StateObject(wrappedValue: SafekeepingSweeper(
            store: store,
            archive: safekeeping,
            cache: SessionArchiveCache.shared
        ))

        // Cmd-Q / quit menu: SIGTERM every live PTY before the app exits.
        // macOS gives ~1s before force-quit, so we don't block waiting for
        // reaps — _Concurrency.Task.detached fires-and-forgets the terminate() calls and
        // the kernel delivers SIGTERM regardless of whether Mani is still
        // alive when the syscall completes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            _Concurrency.Task { await runner.terminateAll() }
        }
    }

    var body: some Scene {
        // WindowGroup first so SwiftUI uses it as the default launch window.
        // Settings is a separate scene reached via Cmd-, only.
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                // Make the title bar background transparent so the
                // sidebar's vibrant material and the masthead's
                // repo-color rule extend up to the window's top
                // edge. Window dragging still works on any non-
                // interactive area of the toolbar; the traffic-light
                // buttons remain in their standard position.
                .toolbarBackground(.hidden, for: .windowToolbar)
                .environmentObject(store)
                .environmentObject(watcher)
                .environmentObject(hookListener)
                .environmentObject(sweeper)
                .environmentObject(archiveCache)
                .environmentObject(safekeepingStore)
                .environmentObject(activityTracker)
                .task {
                    NotificationService.shared.requestAuthorization()
                    Self.registerHookShimIfPossible()
                    watcher.onNewSession = { [weak store] detected in
                        guard let store else { return }
                        _Concurrency.Task { @MainActor in
                            await Self.handleDiscoveredSession(detected, store: store)
                        }
                    }
                    let tracker = activityTracker
                    watcher.onMessages = { [weak store, tracker] detected, delta in
                        guard let store else { return }
                        _Concurrency.Task { @MainActor in
                            tracker.recordActivity(sid: detected.sessionId)
                            await Self.handleSessionMessages(
                                detected, delta: delta, store: store
                            )
                        }
                    }
                    watcher.onActivity = { [tracker] sid in
                        _Concurrency.Task { @MainActor in
                            tracker.recordActivity(sid: sid)
                        }
                    }
                    hookListener.onSessionStart = { [weak store] payload in
                        guard let store else { return }
                        _Concurrency.Task { @MainActor in
                            await Self.handleSessionStart(payload, store: store)
                        }
                    }
                    hookListener.onStop = { [tracker] payload in
                        // Skip claude's internal stop-hook re-entries
                        // (stop_hook_active=true) — those are part of
                        // claude's own hook chain, not a user-visible
                        // "turn finished" signal.
                        guard !payload.stopHookActive else { return }
                        _Concurrency.Task { @MainActor in
                            tracker.markAwaitingInput(sid: payload.sessionId)
                        }
                    }
                    watcher.start()
                    hookListener.start()
                    // Boot reconciliation: drop any .running tasks whose
                    // agent socket is no longer connectable. The user
                    // restarts those manually via the Restart button.
                    // No auto-respawn — a process that died across a Mani
                    // restart should not silently come back; the user
                    // should see the .exited state and decide.
                    await store.runner.reconcileRuntime(
                        state: store.state,
                        dispatch: { action in await store.dispatch(action) }
                    )
                    // If the persisted selection points to a task that's
                    // no longer in state (e.g. dedupe removed it last
                    // session, or the user manually edited state.json),
                    // clear it so the empty-state shows instead of a
                    // broken breadcrumb.
                    if let sel = store.state.selectedTaskPath,
                       Self.taskExists(sel, in: store.state) == false {
                        await store.dispatch(.selectTask(at: nil))
                    }
                    // No auto-dedupe, no auto-prune. Tasks only leave
                    // state via an explicit user delete. The previous
                    // dedupe / prune passes were the main source of
                    // "I created a task and Mani ate it" — both ran at
                    // boot AND on a timer, comparing against external
                    // signals (claude JSONL presence, session-id
                    // uniqueness) that lag the reducer and produced
                    // false positives.
                    await Self.ensureDiffJobsForGitWorktrees(store: store)
                    await Self.migrateRenamedFlags(store: store)
                    await Self.discoverManagedWorktrees(store: store)
                    await Self.bootstrapSafekeepingFromDisk(
                        store: store,
                        cache: archiveCache,
                        archive: safekeepingStore
                    )
                    await sweeper.runOnce()
                    sweeper.start()
                    activityTracker.start()
                    worktreeStatsPoller.start()
                    taskStatsPoller.start()
                    Self.startSnapshotTimer(store: store)
                    // "Standing by." overlay — hand the controller
                    // live references and register the global
                    // ⌘⇧M hotkey. configure() is idempotent so
                    // calling it from .task is safe across
                    // window restoration.
                    StandingByPanelController.shared.configure(
                        store: store,
                        tracker: activityTracker
                    )
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            // Menu entry stays for discoverability. The shortcut
            // is registered globally via Carbon (GlobalHotkey),
            // so we deliberately omit .keyboardShortcut here to
            // avoid double-firing or competing reservations.
            CommandMenu("Standing by") {
                Button("Show / hide overlay  ⌘⇧M") {
                    StandingByPanelController.shared.toggle()
                }
            }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }

    // docs/architecture.md § "Recovery": after loading the snapshot, any pid is
    // suspect (its process died with the previous app instance) and any
    // .running task needs to drop to .stopped. Auto-restart is safelist-only —
    // we re-spawn shells in `respawnSafelisted`.
    // Walking-skeleton hook bundling: try the proper auxiliary-executable
    // location inside the .app first; if missing, fall back to the
    // SPM-built HookShim in the repo's .build/debug. Once we have a real
    // packaging step (CopyFiles build phase or notarized bundle), the
    // fallback can go away.
    private static func registerHookShimIfPossible() {
        let bundleAux = Bundle.main.url(forAuxiliaryExecutable: "HookShim")?.path
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Mani/
            .deletingLastPathComponent() // Mani/Mani/
            .deletingLastPathComponent() // App/Mani/
            .deletingLastPathComponent() // App/
        let devShim = repoRoot.appendingPathComponent(".build/debug/HookShim").path
        let candidates = [bundleAux, devShim].compactMap { $0 }
        guard let shimPath = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            NSLog("[mani] HookShim not found; hooks will not auto-register")
            return
        }
        HookRegistration.register(shimPath: shimPath)
    }

    // Boot: load each repo's sessions-index.json into the
    // SessionArchiveCache so the sidebar paints immediately with
    // last-known state. No JSONL parsing here — the index is a
    // pre-summarized JSON file maintained by SafekeepingSweeper. The
    // legacy ExternalSessionInfoCache is mirrored from the same
    // entries so PastSessionRow continues to work unchanged.
    //
    // We do NOT dispatch discoverExternalConvo for archived sessions:
    // those go through the "Archived projects" sidebar group instead,
    // which renders directly from the cache. Live external claude
    // sessions are still picked up by ClaudeWatcher.onNewSession.
    @MainActor
    private static func bootstrapSafekeepingFromDisk(
        store: Store,
        cache: SessionArchiveCache,
        archive: SafekeepingStore
    ) async {
        for repo in store.state.repos {
            cache.loadFromDisk(for: repo.id, store: archive)
        }
        cache.bootstrapComplete = true
        await reconcileJobsForArchivedSessions(store: store, cache: cache)
    }

    // For each cached session whose originating project is still in
    // the repo AND no Task currently tracks it, dispatch
    // discoverExternalConvo so PastSessionRow appears under that
    // project. The reducer is globally idempotent on sessionId so
    // re-firing is safe.
    //
    // Called from: bootstrap (once at launch) and SafekeepingSweeper
    // after each sweep — so a repo added at runtime picks up its
    // past conversations on the next tick instead of waiting for an
    // app restart.
    @MainActor
    static func reconcileJobsForArchivedSessions(
        store: Store, cache: SessionArchiveCache
    ) async {
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        for repo in store.state.repos {
            // Match against project workspaces (preferred) and fall back
            // to the repo's rootDir so a session whose cwd is in the
            // repo but not in any specific project still surfaces.
            let projectPaths = repo.projects.map {
                $0.workspace.path.resolvingSymlinksInPath().path
            }
            let repoRoot = repo.rootDir.resolvingSymlinksInPath().path
            for entry in cache.entries(for: repo.id) {
                let inProject = projectPaths.contains { wt in
                    if wt == homePath || wt == "/" { return false }
                    return entry.originatingCwd == wt
                        || entry.originatingCwd.hasPrefix(wt + "/")
                }
                let inRepoRoot = !(repoRoot == homePath || repoRoot == "/") &&
                    (entry.originatingCwd == repoRoot
                     || entry.originatingCwd.hasPrefix(repoRoot + "/"))
                guard inProject || inRepoRoot else { continue }
                if store.state.taskOwningClaudeSession(entry.sessionId) != nil {
                    continue
                }
                await store.dispatch(.discoverExternalConvo(
                    repoId: repo.id,
                    sessionId: entry.sessionId,
                    cwd: URL(fileURLWithPath: entry.originatingCwd)
                ))
            }
        }
    }

    // One-time migration: state.json files written before the `renamed`
    // flag existed default it to false. A name that diverges from the
    // auto-generated default pattern for its kind is almost certainly a
    // user rename — backfill the flag so the next dedupe sweep doesn't
    // throw it away. Idempotent: tasks whose `renamed` flag is already
    // true OR whose name matches the default pattern are skipped.
    @MainActor
    private static func migrateRenamedFlags(store: Store) async {
        for repo in store.state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    if task.renamed { continue }
                    if isDefaultJobName(task.name, kind: task.kind) { continue }
                    let path = TaskPath(
                        repo: repo.id, project: project.id, task: task.id
                    )
                    await store.dispatch(.renameTask(at: path, name: task.name))
                }
            }
        }
    }

    // Boot-time scan for managed worktrees that exist on disk but
    // aren't bound to an active project. For each .managed repo we
    // list `<repo>/<namespace>/*`, skip anything that's already
    // owned by an active project or already in availableWorktrees,
    // verify the dir has a `.git` entry (worktrees store .git as a
    // FILE pointing at the main repo's worktree metadata), look up
    // the worktree's branch via `git symbolic-ref`, then dispatch
    // addAvailableWorktree.
    //
    // Rationale: when a user adds a worktree out-of-band (CLI,
    // another tool) or when Mani.app is restarted with leftover
    // worktrees from a previous session, the sidebar should
    // surface them so the user can adopt or remove from one place.
    @MainActor
    private static func discoverManagedWorktrees(store: Store) async {
        for repo in store.state.repos {
            guard repo.worktreeMode == .managed else { continue }
            let nsDir = repo.managedWorktreesDir
            guard FileManager.default.fileExists(atPath: nsDir.path) else { continue }
            let entries: [URL]
            do {
                entries = try FileManager.default.contentsOfDirectory(
                    at: nsDir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                NSLog("[mani] discoverManagedWorktrees: list \(nsDir.path) failed: \(error)")
                continue
            }
            for entry in entries {
                let isDir = (try? entry.resourceValues(
                    forKeys: [.isDirectoryKey]
                ).isDirectory) == true
                guard isDir else { continue }
                let gitMarker = entry.appendingPathComponent(".git")
                guard FileManager.default.fileExists(atPath: gitMarker.path) else {
                    continue
                }
                let branch = readGitHeadBranch(at: entry) ?? entry.lastPathComponent
                let kind: WorkspaceKind = .gitWorktree(
                    branch: branch, baseRef: nil, managed: true
                )
                await store.dispatch(.addAvailableWorktree(
                    repoId: repo.id, path: entry, kind: kind
                ))
            }
        }
    }

    // `git -C <path> symbolic-ref --short HEAD`. nil if detached
    // (rare for managed worktrees) or git fails for any reason.
    private static func readGitHeadBranch(at path: URL) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = path
        task.arguments = ["symbolic-ref", "--short", "HEAD"]
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        } catch {
            return nil
        }
    }

    private static func isDefaultJobName(_ name: String, kind: TaskKind) -> Bool {
        switch kind {
        case .shell:    return name == "shell"
        case .diff:     return name == "diff"
        case .custom:   return false
        case let .claude(sid):
            if name == "claude" { return true }
            if let sid {
                let prefix = sid.prefix(6)
                return name == "claude (resumed \(prefix))"
                    || name == "claude (adopted \(prefix))"
            }
            return false
        }
    }

    // Every git-checkout project gets a permanent .diff Task (the Diff
    // Workspace is a fixture of the project, not something the user
    // spawns). The check is filesystem-based — Mani's WorkspaceKind .folder
    // vs .git only tracks whether Mani created the directory via `git
    // project add`; a .folder project may still be a git repo that the
    // user is working in. We test by stat'ing <path>/.git (a directory for
    // a normal clone, a file for a `git project`-style linked checkout).
    @MainActor
    private static func ensureDiffJobsForGitWorktrees(store: Store) async {
        for repo in store.state.repos {
            for project in repo.projects {
                guard isGitCheckout(at: project.workspace.path) else { continue }
                let hasDiff = project.tasks.contains { task in
                    if case .diff = task.kind { return true }
                    return false
                }
                if !hasDiff {
                    let path = ProjectPath(repo: repo.id, project: project.id)
                    await SidebarView.spawnDiff(at: path, cwd: project.workspace.path, store: store)
                }
            }
        }
    }

    // True iff `path` contains a `.git` entry (directory for a normal clone,
    // file pointing at a gitdir for a linked project). Used to gate the
    // Diff Workspace fixture regardless of the Mani WorkspaceKind label.
    static func isGitCheckout(at path: URL) -> Bool {
        let gitMarker = path.appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: gitMarker)
    }

    private static func startSnapshotTimer(store: Store) {
        _Concurrency.Task { @MainActor [weak store] in
            while !_Concurrency.Task.isCancelled {
                let interval = store?.state.settings.snapshotIntervalSeconds ?? 30
                try? await _Concurrency.Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard let store else { return }
                let snapshot = store.state
                await store.runner.compact(snapshot)
            }
        }
    }

    // Reconciliation happens dynamically via EffectRunner.reconcileRuntime
    // at boot — no per-launch state-mutation pass needed. The reducer's
    // .running runtime is recomputed against the agent's socket on disk;
    // any task whose agent is gone gets a synthetic .taskExited.

    private static func taskExists(_ path: TaskPath, in state: AppState) -> Bool {
        state.repos
            .first(where: { $0.id == path.repo })?
            .projects.first(where: { $0.id == path.project })?
            .tasks.first(where: { $0.id == path.task }) != nil
    }

    private static func seedDefaults(store: Store) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await store.dispatch(.createRepo(
            name: "scratch",
            color: "#ff5500",
            rootDir: home
        ))
        guard let repo = store.state.repos.first,
              let project = repo.projects.first
        else { return }
        let path = ProjectPath(repo: repo.id, project: project.id)
        let spec = ProcessSpec(
            command: "/bin/zsh",
            args: ["-l"],
            env: [:],
            cwd: home,
            initialInput: nil
        )
        await store.dispatch(.createTask(
            at: path,
            name: "shell",
            kind: .shell,
            spec: spec,
            autoSelect: true
        ))
    }

    // Map a freshly-detected Claude session to a Mani project by cwd. If
    // a project's path is a prefix of the session cwd, we treat the session
    // as belonging there and dispatch discoverExternalConvo (which is a no-op
    // if a task already tracks this session id, so re-firing is safe).
    private static func handleDiscoveredSession(
        _ detected: ClaudeWatcher.DetectedSession,
        store: Store
    ) async {
        guard let cwd = detected.cwd else { return }
        let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        // Skip auto-discovery when the matched project's path is too broad
        // (the user's $HOME, "/", or similar). Any claude run anywhere on
        // the machine would otherwise produce a discovered task — that's the
        // bug where dozens of "external claude" rows appear in the sidebar.
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let tooBroad: Set<String> = [homePath, "/"]
        for repo in store.state.repos {
            for project in repo.projects {
                let wtPath = project.workspace.path.resolvingSymlinksInPath().path
                if tooBroad.contains(wtPath) { continue }
                guard cwdURL.path == wtPath || cwdURL.path.hasPrefix(wtPath + "/") else {
                    continue
                }
                let path = ProjectPath(repo: repo.id, project: project.id)

                // Prefer linking into an existing claude(nil) task in this
                // project (created by NewTaskSheet's "Claude" option) — the
                // user spawned this session via Mani and wants the session
                // attached to the existing slot, not a duplicate.
                if let unlinked = project.tasks.first(where: { task in
                    if case .claude(let sid) = task.kind, sid == nil { return true }
                    return false
                }) {
                    let taskPath = TaskPath(
                        repo: repo.id, project: project.id, task: unlinked.id
                    )
                    await store.dispatch(.linkClaudeSession(
                        at: taskPath, sessionId: detected.sessionId
                    ))
                } else {
                    await store.dispatch(.discoverExternalConvo(
                        repoId: repo.id,
                        sessionId: detected.sessionId,
                        cwd: URL(fileURLWithPath: cwd)
                    ))
                }
                return
            }
        }
    }

    // Routing is a pure function in ManiCore (testable from the unit-test
    // target). We just feed it the current state + the home path to exclude
    // and dispatch whatever action it returns. See ADR-016.
    @MainActor
    private static func handleSessionStart(
        _ payload: SessionStartPayload,
        store: Store
    ) async {
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        guard let action = routeSessionStart(
            payload: payload, state: store.state, homePathToExclude: homePath
        ) else { return }
        await store.dispatch(action)
    }

    // Bump the unread badge on the task linked to this session whenever the
    // watcher sees new message lines on disk. ContentView clears it via
    // markRead when the user selects the task.
    private static func handleSessionMessages(
        _ detected: ClaudeWatcher.DetectedSession,
        delta: Int,
        store: Store
    ) async {
        if let last = detected.lastMessageAt {
            ExternalSessionInfoCache.shared.touch(
                sid: detected.sessionId,
                lastMessageAt: last,
                messageCount: detected.messageCount
            )
        }
        for repo in store.state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    if case let .claude(sid) = task.kind, sid == detected.sessionId {
                        let path = TaskPath(
                            repo: repo.id, project: project.id, task: task.id
                        )
                        await store.dispatch(.bumpUnread(at: path, by: delta))
                        return
                    }
                }
            }
        }
        // No Task tracks this session id. Treat the message arrival
        // as a fresh discovery opportunity — covers the case where
        // the session's onNewSession fired against an empty repo
        // list (claude was already running when the user added the
        // repo, or FSEvents missed the initial create). The
        // discoverExternalConvo reducer is globally idempotent so
        // re-firing is safe.
        await handleDiscoveredSession(detected, store: store)
    }

    // Walk all .claude(sid) tasks and delete any whose <sid>.jsonl is
    // missing under ~/.claude/projects/<slug>/. Covers:
    //   - External claude tasks whose transcript was pruned by claude's
    //     retention (and we can no longer adopt them).
    //   - Mani-spawned claude tasks whose `claude --resume <sid>` failed
    //     with "No conversation found" — these leave a live zsh prompt
    //     attached to a useless Task, so the pid==nil guard from earlier
    //     versions wasn't enough.
    //
    // Safety rules:
    //   - Only consider tasks older than 5 s. Claude takes ~1 s to write
    //     its first event; we don't want to prune a task in the
    // Note: pruneStaleClaudeJobs and dedupeClaudeJobs were removed.
    // They auto-deleted tasks from state based on external signals
    // (claude JSONL file presence, session-id uniqueness) that lag the
    // reducer and produced false positives — the "Mani ate my task"
    // bug. Removal of tasks is now exclusively via an explicit
    // deleteTask action driven by the user. If duplicates or orphans
    // accumulate, address them via UI affordances, not silent culling.

}
