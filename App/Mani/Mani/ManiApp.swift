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
                if cwdURL.path == wtPath || cwdURL.path.hasPrefix(wtPath + "/") {
                    let path = WorktreePath(project: project.id, worktree: worktree.id)
                    await store.dispatch(.discoverClaudeSession(
                        at: path,
                        sessionId: detected.sessionId,
                        cwd: URL(fileURLWithPath: cwd)
                    ))
                    return
                }
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
