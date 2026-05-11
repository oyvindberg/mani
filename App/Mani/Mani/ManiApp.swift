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
    private let jobStatsPoller: JobStatsPoller
    private let safekeepingStore: SafekeepingStore
    @StateObject private var sweeper: SafekeepingSweeper
    @StateObject private var archiveCache: SessionArchiveCache = SessionArchiveCache.shared
    @StateObject private var activityTracker = JobActivityTracker()

    init() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let storeRoot = appSupport.appendingPathComponent("Mani")
        let persistence = try! PersistenceStore(rootDir: storeRoot)
        let recovered = (try? persistence.recover().state) ?? .empty
        let initialState = Self.reconcileAfterCrash(recovered)
        let runner = EffectRunner(persistence: persistence)
        let store = Store(state: initialState, runner: runner)
        _store = StateObject(wrappedValue: store)

        let claudeProjects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .path
        _watcher = StateObject(wrappedValue: ClaudeWatcher(projectsDir: claudeProjects))

        let socketPath = storeRoot.appendingPathComponent("hook.sock").path
        _hookListener = StateObject(wrappedValue: HookListenerService(socketPath: socketPath))

        worktreeStatsPoller = WorktreeStatsPoller(store: store)
        jobStatsPoller = JobStatsPoller(store: store)

        let safekeeping = try! SafekeepingStore(appSupportRoot: storeRoot)
        self.safekeepingStore = safekeeping
        _sweeper = StateObject(wrappedValue: SafekeepingSweeper(
            store: store,
            archive: safekeeping,
            cache: SessionArchiveCache.shared
        ))

        // Cmd-Q / quit menu: SIGTERM every live PTY before the app exits.
        // macOS gives ~1s before force-quit, so we don't block waiting for
        // reaps — Task.detached fires-and-forgets the terminate() calls and
        // the kernel delivers SIGTERM regardless of whether Mani is still
        // alive when the syscall completes.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { _ in
            Task { await runner.terminateAll() }
        }
    }

    var body: some Scene {
        // WindowGroup first so SwiftUI uses it as the default launch window.
        // Settings is a separate scene reached via Cmd-, only.
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
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
                        Task { @MainActor in
                            await Self.handleDiscoveredSession(detected, store: store)
                        }
                    }
                    let tracker = activityTracker
                    watcher.onMessages = { [weak store, tracker] detected, delta in
                        guard let store else { return }
                        Task { @MainActor in
                            tracker.recordActivity(sid: detected.sessionId)
                            await Self.handleSessionMessages(
                                detected, delta: delta, store: store
                            )
                        }
                    }
                    hookListener.onSessionStart = { [weak store] payload in
                        guard let store else { return }
                        Task { @MainActor in
                            await Self.handleSessionStart(payload, store: store)
                        }
                    }
                    watcher.start()
                    hookListener.start()
                    // No auto-seed: first launch shows an empty-state CTA.
                    // Auto-seeding a worktree at $HOME made every Claude
                    // session in the user's home tree get auto-discovered.
                    if !store.state.projects.isEmpty {
                        await Self.respawnSafelisted(store: store)
                    }
                    await Self.dedupeClaudeJobs(store: store)
                    await Self.ensureDiffJobsForGitWorktrees(store: store)
                    await Self.migrateRenamedFlags(store: store)
                    await Self.bootstrapSafekeepingFromDisk(
                        store: store,
                        cache: archiveCache,
                        archive: safekeepingStore
                    )
                    // Immediate (synchronous wrt boot) sweep so the cache
                    // covers anything not yet safekept. The reconcile
                    // step inside runOnce dispatches discoverClaudeSession
                    // for matched entries, bringing newly-recognized
                    // sessions into the sidebar before the first prune
                    // tick can run.
                    await sweeper.runOnce()
                    // Prune AFTER both the bootstrap reconcile AND the
                    // immediate sweep — those add back any jobs we lost
                    // in a previous bad-prune cycle, then prune kills
                    // only the truly orphaned ones.
                    await Self.pruneStaleClaudeJobs(store: store)
                    sweeper.start()
                    activityTracker.start()
                    worktreeStatsPoller.start()
                    jobStatsPoller.start()
                    Self.startSnapshotTimer(store: store)
                    Self.startStaleClaudePruneTimer(store: store)
                }
        }
        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }

    // docs/architecture.md § "Recovery": after loading the snapshot, any pid is
    // suspect (its process died with the previous app instance) and any
    // .running job needs to drop to .stopped. Auto-restart is safelist-only —
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

    // Boot: load each project's sessions-index.json into the
    // SessionArchiveCache so the sidebar paints immediately with
    // last-known state. No JSONL parsing here — the index is a
    // pre-summarized JSON file maintained by SafekeepingSweeper. The
    // legacy ExternalSessionInfoCache is mirrored from the same
    // entries so PastSessionRow continues to work unchanged.
    //
    // We do NOT dispatch discoverClaudeSession for archived sessions:
    // those go through the "Archived worktrees" sidebar group instead,
    // which renders directly from the cache. Live external claude
    // sessions are still picked up by ClaudeWatcher.onNewSession.
    @MainActor
    private static func bootstrapSafekeepingFromDisk(
        store: Store,
        cache: SessionArchiveCache,
        archive: SafekeepingStore
    ) async {
        for project in store.state.projects {
            cache.loadFromDisk(for: project.id, store: archive)
        }
        cache.bootstrapComplete = true
        await reconcileJobsForArchivedSessions(store: store, cache: cache)
    }

    // For each cached session whose originating worktree is still in
    // the project AND no Job currently tracks it, dispatch
    // discoverClaudeSession so PastSessionRow appears under that
    // worktree. The reducer is globally idempotent on sessionId so
    // re-firing is safe.
    //
    // Called from: bootstrap (once at launch) and SafekeepingSweeper
    // after each sweep — so a project added at runtime picks up its
    // past conversations on the next tick instead of waiting for an
    // app restart.
    @MainActor
    static func reconcileJobsForArchivedSessions(
        store: Store, cache: SessionArchiveCache
    ) async {
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        for project in store.state.projects {
            let pairs = project.worktrees.map {
                ($0.id, $0.path.resolvingSymlinksInPath().path)
            }
            for entry in cache.entries(for: project.id) {
                guard let (worktreeId, _) = pairs.first(where: { id, wt in
                    if wt == homePath || wt == "/" { return false }
                    return entry.originatingCwd == wt
                        || entry.originatingCwd.hasPrefix(wt + "/")
                }) else { continue }
                if store.state.jobOwningClaudeSession(entry.sessionId) != nil {
                    continue
                }
                await store.dispatch(.discoverClaudeSession(
                    at: WorktreePath(project: project.id, worktree: worktreeId),
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
    // throw it away. Idempotent: jobs whose `renamed` flag is already
    // true OR whose name matches the default pattern are skipped.
    @MainActor
    private static func migrateRenamedFlags(store: Store) async {
        for project in store.state.projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    if job.renamed { continue }
                    if isDefaultJobName(job.name, kind: job.kind) { continue }
                    let path = JobPath(
                        project: project.id, worktree: worktree.id, job: job.id
                    )
                    await store.dispatch(.renameJob(at: path, name: job.name))
                }
            }
        }
    }

    private static func isDefaultJobName(_ name: String, kind: JobKind) -> Bool {
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

    // Every git-checkout worktree gets a permanent .diff Job (the Diff
    // Workspace is a fixture of the worktree, not something the user
    // spawns). The check is filesystem-based — Mani's WorktreeKind .folder
    // vs .git only tracks whether Mani created the directory via `git
    // worktree add`; a .folder worktree may still be a git repo that the
    // user is working in. We test by stat'ing <path>/.git (a directory for
    // a normal clone, a file for a `git worktree`-style linked checkout).
    @MainActor
    private static func ensureDiffJobsForGitWorktrees(store: Store) async {
        for project in store.state.projects {
            for worktree in project.worktrees {
                guard isGitCheckout(at: worktree.path) else { continue }
                let hasDiff = worktree.jobs.contains { job in
                    if case .diff = job.kind { return true }
                    return false
                }
                if !hasDiff {
                    let path = WorktreePath(project: project.id, worktree: worktree.id)
                    await SidebarView.spawnDiff(at: path, cwd: worktree.path, store: store)
                }
            }
        }
    }

    // True iff `path` contains a `.git` entry (directory for a normal clone,
    // file pointing at a gitdir for a linked worktree). Used to gate the
    // Diff Workspace fixture regardless of the Mani WorktreeKind label.
    static func isGitCheckout(at path: URL) -> Bool {
        let gitMarker = path.appendingPathComponent(".git").path
        return FileManager.default.fileExists(atPath: gitMarker)
    }

    // Periodically re-run pruneStaleClaudeJobs so an adopted/resumed
    // claude that immediately exits ("No conversation found", crash,
    // process killed externally) is cleaned up without requiring a
    // relaunch. 30s feels right — short enough that dead Jobs don't
    // linger noticeably, long enough not to thrash dispatch.
    private static func startStaleClaudePruneTimer(store: Store) {
        Task { @MainActor [weak store] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let store else { return }
                await Self.pruneStaleClaudeJobs(store: store)
            }
        }
    }

    private static func startSnapshotTimer(store: Store) {
        Task { @MainActor [weak store] in
            while !Task.isCancelled {
                let interval = store?.state.settings.snapshotIntervalSeconds ?? 30
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
                guard let store else { return }
                let snapshot = store.state
                await store.runner.compact(snapshot)
            }
        }
    }

    private static func reconcileAfterCrash(_ state: AppState) -> AppState {
        var s = state
        for pi in s.projects.indices {
            for wi in s.projects[pi].worktrees.indices {
                for ji in s.projects[pi].worktrees[wi].jobs.indices {
                    s.projects[pi].worktrees[wi].jobs[ji].primary.pid = nil
                    for ai in s.projects[pi].worktrees[wi].jobs[ji].auxiliary.indices {
                        s.projects[pi].worktrees[wi].jobs[ji].auxiliary[ai].pid = nil
                    }
                    if s.projects[pi].worktrees[wi].jobs[ji].status == .running {
                        s.projects[pi].worktrees[wi].jobs[ji].status = .stopped
                    }
                }
            }
        }
        return s
    }

    private static func seedDefaults(store: Store) async {
        let home = FileManager.default.homeDirectoryForCurrentUser
        await store.dispatch(.createProject(
            name: "scratch",
            color: "#ff5500"
        ))
        guard let project = store.state.projects.first else { return }
        await store.dispatch(.createWorktree(
            projectId: project.id,
            name: "main",
            kind: .folder,
            path: home
        ))
        guard let worktree = store.state.projects.first?.worktrees.first else { return }
        let path = WorktreePath(project: project.id, worktree: worktree.id)
        let spec = ProcessSpec(
            command: "/bin/zsh",
            args: ["-l"],
            env: [:],
            cwd: home,
            pid: nil,
            initialInput: nil, restartPolicy: .never)
        await store.dispatch(.createJob(
            at: path,
            name: "shell",
            kind: .shell,
            primary: spec,
            auxiliary: []
        ))
    }

    // Map a freshly-detected Claude session to a Mani worktree by cwd. If
    // a worktree's path is a prefix of the session cwd, we treat the session
    // as belonging there and dispatch discoverClaudeSession (which is a no-op
    // if a job already tracks this session id, so re-firing is safe).
    private static func handleDiscoveredSession(
        _ detected: ClaudeWatcher.DetectedSession,
        store: Store
    ) async {
        guard let cwd = detected.cwd else { return }
        let cwdURL = URL(fileURLWithPath: cwd).resolvingSymlinksInPath()
        // Skip auto-discovery when the matched worktree's path is too broad
        // (the user's $HOME, "/", or similar). Any claude run anywhere on
        // the machine would otherwise produce a discovered job — that's the
        // bug where dozens of "external claude" rows appear in the sidebar.
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let tooBroad: Set<String> = [homePath, "/"]
        for project in store.state.projects {
            for worktree in project.worktrees {
                let wtPath = worktree.path.resolvingSymlinksInPath().path
                if tooBroad.contains(wtPath) { continue }
                guard cwdURL.path == wtPath || cwdURL.path.hasPrefix(wtPath + "/") else {
                    continue
                }
                let path = WorktreePath(project: project.id, worktree: worktree.id)

                // Prefer linking into an existing claude(nil) job in this
                // worktree (created by NewTaskSheet's "Claude" option) — the
                // user spawned this session via Mani and wants the session
                // attached to the existing slot, not a duplicate.
                if let unlinked = worktree.jobs.first(where: { job in
                    if case .claude(let sid) = job.kind, sid == nil { return true }
                    return false
                }) {
                    let jobPath = JobPath(
                        project: project.id, worktree: worktree.id, job: unlinked.id
                    )
                    await store.dispatch(.linkClaudeSession(
                        at: jobPath, sessionId: detected.sessionId
                    ))
                } else {
                    await store.dispatch(.discoverClaudeSession(
                        at: path,
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

    // Bump the unread badge on the job linked to this session whenever the
    // watcher sees new message lines on disk. ContentView clears it via
    // markRead when the user selects the job.
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
        for project in store.state.projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    if case let .claude(sid) = job.kind, sid == detected.sessionId {
                        let path = JobPath(
                            project: project.id, worktree: worktree.id, job: job.id
                        )
                        await store.dispatch(.bumpUnread(at: path, by: delta))
                        return
                    }
                }
            }
        }
        // No Job tracks this session id. Treat the message arrival
        // as a fresh discovery opportunity — covers the case where
        // the session's onNewSession fired against an empty project
        // list (claude was already running when the user added the
        // project, or FSEvents missed the initial create). The
        // discoverClaudeSession reducer is globally idempotent so
        // re-firing is safe.
        await handleDiscoveredSession(detected, store: store)
    }

    // Walk all .claude(sid) jobs and delete any whose <sid>.jsonl is
    // missing under ~/.claude/projects/<slug>/. Covers:
    //   - External claude jobs whose transcript was pruned by claude's
    //     retention (and we can no longer adopt them).
    //   - Mani-spawned claude jobs whose `claude --resume <sid>` failed
    //     with "No conversation found" — these leave a live zsh prompt
    //     attached to a useless Job, so the pid==nil guard from earlier
    //     versions wasn't enough.
    //
    // Safety rules:
    //   - Only consider jobs older than 5 s. Claude takes ~1 s to write
    //     its first event; we don't want to prune a task in the
    //     post-spawn window before the JSONL appears.
    //   - Only `.claude(sid)` with sid != nil. Unlinked `.claude(nil)`
    //     slots stay (they're waiting for a hook/watcher link).
    //   - Renamed jobs are pruned too: the rename refers to a session
    //     that no longer exists, so it's stale clutter regardless.
    @MainActor
    private static func pruneStaleClaudeJobs(store: Store) async {
        // Build a set of every session id that's recognized by either
        // claude itself OR our safekeep cache:
        //   - Flat <sid>.jsonl files anywhere under ~/.claude/projects.
        //   - Entries in claude's own per-slug sessions-index.json
        //     (newer format — flat JSONLs migrated to per-session
        //     subdirs but the index still lists them).
        //   - Entries in our own safekeep cache (we've seen them at
        //     least once, so they're not stale from our POV).
        // Old behavior used the per-worktree-slug path and kept
        // false-positive deleting valid jobs whose transcript lived
        // under a sibling slug.
        let projectsRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        var liveSids: Set<String> = []
        if let slugs = try? FileManager.default.contentsOfDirectory(
            at: projectsRoot, includingPropertiesForKeys: nil
        ) {
            for slugDir in slugs {
                guard let files = try? FileManager.default.contentsOfDirectory(
                    at: slugDir, includingPropertiesForKeys: nil
                ) else { continue }
                for file in files where file.pathExtension == "jsonl" {
                    liveSids.insert(file.deletingPathExtension().lastPathComponent)
                }
                let claudeIndexURL = slugDir
                    .appendingPathComponent("sessions-index.json", isDirectory: false)
                if let data = try? Data(contentsOf: claudeIndexURL),
                   let parsed = ClaudeOwnSessionsIndex.parse(data: data) {
                    for record in parsed.entries {
                        liveSids.insert(record.sessionId)
                    }
                }
            }
        }
        for entries in SessionArchiveCache.shared.entriesByProject.values {
            for entry in entries {
                liveSids.insert(entry.sessionId)
            }
        }

        let now = Date()
        var toRemove: [JobPath] = []
        for project in store.state.projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    guard case let .claude(sid) = job.kind, let sid else { continue }
                    guard now.timeIntervalSince(job.createdAt) > 5 else { continue }
                    if !liveSids.contains(sid) {
                        toRemove.append(JobPath(
                            project: project.id, worktree: worktree.id, job: job.id
                        ))
                    }
                }
            }
        }
        guard !toRemove.isEmpty else { return }
        NSLog("[mani] pruning \(toRemove.count) claude jobs with missing transcripts")
        for path in toRemove {
            await store.dispatch(.deleteJob(at: path))
        }
    }

    // Claude's slug convention for ~/.claude/projects/<slug>: leading dash
    // followed by the absolute path with `/` replaced by `-`. Mirrors
    // ClaudeHistoryScanner.sessions(forCwd:).
    private static func claudeSlug(for worktreePath: URL) -> String {
        let path = worktreePath.path
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        return "-" + trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "-")
    }

    // One-time cleanup on launch: persisted state from older Mani builds
    // (before the reducer enforced sid uniqueness, ADR-016) can contain
    // multiple claude jobs with the same session id. Walk the state, keep
    // the "best" job per sid (live pid > most unread > most recent), and
    // delete the rest via the standard deleteJob action so the deletion
    // is durable on disk.
    private static func dedupeClaudeJobs(store: Store) async {
        let toRemove = store.state.duplicateClaudeJobsToRemove()
        guard !toRemove.isEmpty else { return }
        NSLog("[mani] deduping \(toRemove.count) duplicate claude jobs")
        for path in toRemove {
            await store.dispatch(.deleteJob(at: path))
        }
    }

    private static func respawnSafelisted(store: Store) async {
        for project in store.state.projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    guard job.primary.command == "/bin/zsh",
                          job.primary.pid == nil
                    else { continue }
                    let path = JobPath(project: project.id, worktree: worktree.id, job: job.id)
                    // Re-spawn by emitting the same effect manually via the runner.
                    // We don't go through the reducer because we don't want a new
                    // jobCreated event — the job already exists; we're just
                    // resuming its process.
                    await store.runner.run(
                        .spawn(at: path, index: 0, job.primary),
                        dispatch: { action in await store.dispatch(action) }
                    )
                }
            }
        }
    }
}
