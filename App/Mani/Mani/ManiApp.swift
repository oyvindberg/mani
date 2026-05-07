import SwiftUI
import ManiCore
import Foundation

@main
struct ManiApp: App {
    @StateObject private var store: Store

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
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 500)
                .environmentObject(store)
                .task {
                    if store.state.projects.isEmpty {
                        await Self.seedDefaults(store: store)
                    } else {
                        // Re-spawn the primary process for each task that was
                        // running before the crash. Walking-skeleton version:
                        // re-spawn /bin/zsh for every job whose primary command
                        // is on a tiny safelist. Proper restart UX comes later.
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
