import Foundation
import Darwin
import ManiCore

// Spike 5 driver: fork a child that mutates the store at random, parent
// kills it after 1–200 ms, then validates that recovery produces a valid
// state. Goal per docs/spikes.md: 1000/1000 cycles green.

// Swift's Darwin module marks fork() unavailable. The C function still exists.
@_silgen_name("fork") func cfork() -> pid_t

let storeRoot = URL(fileURLWithPath: "/tmp/mani-crash-spike-store")

// MARK: - Deterministic RNG so a failing cycle is reproducible from its seed.

struct LCG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

// MARK: - Random action against current state.

func randomAction(state: AppState, rng: inout LCG) -> Action? {
    let r = Int(rng.next() % 100)

    if state.repos.isEmpty || r < 25 {
        let id = rng.next() % 100_000
        return .createRepo(
            name: "p\(id)",
            color: "#ff5500",
            rootDir: URL(fileURLWithPath: "/tmp/p\(id)")
        )
    }

    let repo = state.repos[Int(rng.next() % UInt64(state.repos.count))]

    if repo.projects.isEmpty || r < 45 {
        let id = rng.next() % 100_000
        return .createProject(
            repoId: repo.id,
            name: "p\(id)",
            workspace: Workspace(
                path: URL(fileURLWithPath: "/tmp/w\(id)"),
                kind: .folder,
                missing: false
            )
        )
    }

    let project = repo.projects[Int(rng.next() % UInt64(repo.projects.count))]
    let projectPath = ProjectPath(repo: repo.id, project: project.id)

    if project.tasks.isEmpty || r < 70 {
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/tmp"),
            initialInput: nil
        )
        return .createTask(at: projectPath, name: "t", kind: .shell, spec: spec, autoSelect: false)
    }

    let task = project.tasks[Int(rng.next() % UInt64(project.tasks.count))]
    let taskPath = TaskPath(repo: repo.id, project: project.id, task: task.id)

    if r < 78 { return .completeTask(at: taskPath) }
    if r < 84 { return .renameRepo(id: repo.id, name: "renamed-\(rng.next() % 1000)") }
    if r < 89 { return .markProjectWorkspaceMissing(at: projectPath) }
    if r < 94 { return .deleteProject(at: projectPath) }
    return .deleteRepo(id: repo.id)
}

// MARK: - Validation: invariants the recovered state must hold.

func validate(_ state: AppState) -> [String] {
    var errors: [String] = []
    if state.schemaVersion != 2 {
        errors.append("schemaVersion=\(state.schemaVersion) (want 2)")
    }
    var ids = Set<UUID>()
    for repo in state.repos {
        if !ids.insert(repo.id).inserted {
            errors.append("dup repo id \(repo.id)")
        }
        if !repo.createdAt.timeIntervalSince1970.isFinite {
            errors.append("repo \(repo.id) createdAt non-finite")
        }
        for project in repo.projects {
            if !ids.insert(project.id).inserted {
                errors.append("dup project id \(project.id)")
            }
            if !project.createdAt.timeIntervalSince1970.isFinite {
                errors.append("project \(project.id) createdAt non-finite")
            }
            for task in project.tasks {
                if !ids.insert(task.id).inserted {
                    errors.append("dup task id \(task.id)")
                }
                if !task.createdAt.timeIntervalSince1970.isFinite {
                    errors.append("task \(task.id) createdAt non-finite")
                }
            }
        }
    }
    return errors
}

// MARK: - Child worker.

func runChild(seed: UInt64, mutations: Int) -> Never {
    do {
        let store = try PersistenceStore(rootDir: storeRoot)
        var (state, _) = try store.recover()
        var rng = LCG(state: seed)

        // Occasional fresh compact at start of cycle.
        if !state.repos.isEmpty && (rng.next() % 4) == 0 {
            try store.compact(state)
        }

        for _ in 0..<mutations {
            guard let action = randomAction(state: state, rng: &rng) else { continue }
            let (events, _) = reduce(state, action)
            for event in events {
                try store.appendEvent(event)
                apply(&state, event)
            }
            // Occasional compact mid-stream — exposes the snapshot/truncate window.
            if (rng.next() % 30) == 0 {
                try store.compact(state)
            }
        }
        _exit(0)
    } catch {
        // Errors in the child are expected (kill -9 hits during write etc).
        // Don't crash; just exit nonzero. Use _exit so we skip atexit
        // handlers — they re-emit the parent's pre-fork stdout buffer.
        _exit(1)
    }
}

// MARK: - Driver.

let cycles = 1000
let mutationsPerCycle = 80
let maxSleepUs: UInt32 = 200_000  // 200 ms

var failures = 0
var bakRecoveries = 0
var newRecoveries = 0
var skippedTotal = 0
let totalStart = Date()

try? FileManager.default.removeItem(at: storeRoot)
try? FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)

setbuf(stdout, nil)  // unbuffered so fork() doesn't duplicate buffered output

print("Running \(cycles) crash cycles, \(mutationsPerCycle) mutations/cycle, kill at random in [1, \(maxSleepUs)] µs.")
print("")

for cycle in 1...cycles {
    let pid = cfork()
    if pid < 0 {
        print("fork() failed errno=\(errno)")
        exit(1)
    }
    if pid == 0 {
        runChild(seed: UInt64(cycle), mutations: mutationsPerCycle)
    }

    let sleepUs = UInt32.random(in: 1...maxSleepUs)
    usleep(sleepUs)
    kill(pid, SIGKILL)
    var status: Int32 = 0
    _ = waitpid(pid, &status, 0)

    do {
        let store = try PersistenceStore(rootDir: storeRoot)
        let (state, report) = try store.recover()
        let errs = validate(state)
        if !errs.isEmpty {
            failures += 1
            print("cycle \(cycle): \(errs)  source=\(report.snapshotSource) replayed=\(report.eventsReplayed)")
        }
        if report.snapshotSource.contains("bak") { bakRecoveries += 1 }
        if report.snapshotSource.contains("new") { newRecoveries += 1 }
        skippedTotal += report.eventsSkippedOnDecodeFailure
    } catch {
        failures += 1
        print("cycle \(cycle): recovery threw: \(error)")
    }

    if cycle % 100 == 0 {
        let elapsed = Date().timeIntervalSince(totalStart)
        print("\(cycle): \(failures) failures, \(String(format: "%.1f", elapsed))s, bak=\(bakRecoveries), new=\(newRecoveries), trailing-skip=\(skippedTotal)")
    }
}

let elapsed = Date().timeIntervalSince(totalStart)
print("")
print("─── Summary ───")
print("cycles:               \(cycles)")
print("failures:             \(failures)")
print("recovered from .bak:  \(bakRecoveries)")
print("recovered from .new:  \(newRecoveries)")
print("trailing-bad-line:    \(skippedTotal)")
print("elapsed:              \(String(format: "%.2f", elapsed))s")
exit(failures == 0 ? 0 : 1)
