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

    if state.projects.isEmpty || r < 25 {
        let id = rng.next() % 100_000
        return .createProject(
            name: "p\(id)",
            color: "#ff5500",
            rootDir: URL(fileURLWithPath: "/tmp/p\(id)")
        )
    }

    let project = state.projects[Int(rng.next() % UInt64(state.projects.count))]

    if project.worktrees.isEmpty || r < 45 {
        let id = rng.next() % 100_000
        return .createWorktree(
            projectId: project.id,
            name: "w\(id)",
            kind: .folder,
            path: URL(fileURLWithPath: "/tmp/w\(id)")
        )
    }

    let worktree = project.worktrees[Int(rng.next() % UInt64(project.worktrees.count))]
    let wtPath = WorktreePath(project: project.id, worktree: worktree.id)

    if worktree.jobs.isEmpty || r < 70 {
        let spec = ProcessSpec(
            command: "/bin/zsh", args: [], env: [:],
            cwd: URL(fileURLWithPath: "/tmp"), pid: nil,
            initialInput: nil, restartPolicy: .never)
        return .createJob(
            at: wtPath, name: "j", kind: .shell,
            primary: spec, auxiliary: []
        )
    }

    let job = worktree.jobs[Int(rng.next() % UInt64(worktree.jobs.count))]
    let jobPath = JobPath(project: project.id, worktree: worktree.id, job: job.id)

    if r < 78 { return .completeJob(at: jobPath) }
    if r < 84 { return .renameProject(id: project.id, name: "renamed-\(rng.next() % 1000)") }
    if r < 89 { return .markWorktreeMissing(at: wtPath) }
    if r < 94 { return .deleteWorktree(at: wtPath) }
    return .deleteProject(id: project.id)
}

// MARK: - Validation: invariants the recovered state must hold.

func validate(_ state: AppState) -> [String] {
    var errors: [String] = []
    if state.schemaVersion != 1 {
        errors.append("schemaVersion=\(state.schemaVersion) (want 1)")
    }
    var ids = Set<UUID>()
    for project in state.projects {
        if !ids.insert(project.id).inserted {
            errors.append("dup project id \(project.id)")
        }
        if !project.createdAt.timeIntervalSince1970.isFinite {
            errors.append("project \(project.id) createdAt non-finite")
        }
        for worktree in project.worktrees {
            if !ids.insert(worktree.id).inserted {
                errors.append("dup worktree id \(worktree.id)")
            }
            if !worktree.createdAt.timeIntervalSince1970.isFinite {
                errors.append("worktree \(worktree.id) createdAt non-finite")
            }
            for job in worktree.jobs {
                if !ids.insert(job.id).inserted {
                    errors.append("dup job id \(job.id)")
                }
                if !job.createdAt.timeIntervalSince1970.isFinite {
                    errors.append("job \(job.id) createdAt non-finite")
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
        if !state.projects.isEmpty && (rng.next() % 4) == 0 {
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
