import SwiftUI
import ManiCore
import Foundation

@main
struct ManiApp: App {
    @StateObject private var store: Store
    @StateObject private var watcher: ClaudeWatcher
    @StateObject private var hookListener: HookListenerService

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .environmentObject(store)
                .environmentObject(watcher)
                .environmentObject(hookListener)
                .task {
                    NotificationService.shared.requestAuthorization()
                    Self.registerHookShimIfPossible()
                    watcher.onNewSession = { [weak store] detected in
                        guard let store else { return }
                        Task { @MainActor in
                            await Self.handleDiscoveredSession(detected, store: store)
                        }
                    }
                    watcher.start()
                    hookListener.start()
                    if store.state.projects.isEmpty {
                        await Self.seedDefaults(store: store)
                    } else {
                        await Self.respawnSafelisted(store: store)
                    }
                }
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
            color: "#ff5500",
            rootDir: home
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
            pid: nil
        )
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
        for project in store.state.projects {
            for worktree in project.worktrees {
                let wtPath = worktree.path.resolvingSymlinksInPath().path
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
