import Foundation
import CoreServices
import Darwin

// Spike 6: FSEvents on a sandboxed ~/.claude/projects directory.
// Goal per docs/spikes.md: validate that an FSEventStream sees every line
// claude writes, with no duplicates and no decode failures.
//
// The watcher tails JSONL files: tracks each file's last-seen size,
// reads new bytes on each event, and counts newline-terminated lines.
// After driving claude, we compare watcher's per-file line count to
// what's actually on disk.

let spikeHome = "/tmp/mani-watcher-spike-home"
let projectsDir = "\(spikeHome)/.claude/projects"

// MARK: - File-tail tracker

struct FileTail {
    var size: UInt64
    var lineCount: Int
}

final class TailTracker {
    var files: [String: FileTail] = [:]
    var totalCallbacks = 0
    var unparseableLines = 0
    let lock = NSLock()

    func note(path: String) {
        lock.lock()
        defer { lock.unlock() }
        totalCallbacks += 1

        let prev = files[path] ?? FileTail(size: 0, lineCount: 0)

        // Quick fast-path: if size hasn't grown since last visit, skip.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let statSize = (attrs[.size] as? NSNumber)?.uint64Value,
           statSize <= prev.size {
            return
        }

        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        do {
            try fh.seek(toOffset: prev.size)
        } catch { return }
        let data = (try? fh.readToEnd()) ?? Data()
        if data.isEmpty { return }

        var newlines = 0
        var startIdx = data.startIndex
        let decoder = JSONDecoder()
        while startIdx < data.endIndex {
            guard let nlIdx = data[startIdx...].firstIndex(of: 0x0A) else { break }
            let line = data[startIdx..<nlIdx]
            newlines += 1
            if !line.isEmpty,
               (try? decoder.decode([String: AnyDecodable].self, from: line)) == nil {
                unparseableLines += 1
            }
            startIdx = data.index(after: nlIdx)
        }

        // Anchor new prev on bytes-actually-read, not the stat from before the read —
        // otherwise a concurrent writer can extend the file during readToEnd and the
        // next callback re-reads the overlap, double-counting lines.
        let bytesRead = UInt64(data.count)
        files[path] = FileTail(
            size: prev.size + bytesRead,
            lineCount: prev.lineCount + newlines
        )
    }
}

struct AnyDecodable: Decodable {
    init(from decoder: Decoder) throws {
        _ = try decoder.singleValueContainer()
    }
}

// MARK: - FSEventStream wrapper

final class FSWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let tracker: TailTracker

    init(path: String, tracker: TailTracker) {
        self.path = path
        self.tracker = tracker
    }

    func start() -> Bool {
        let paths = [path] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(tracker).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let cb: FSEventStreamCallback = { _, info, numEvents, eventPathsPtr, _, _ in
            guard let info else { return }
            let tracker = Unmanaged<TailTracker>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPathsPtr, to: NSArray.self) as! [String]
            for i in 0..<numEvents {
                let path = paths[i]
                if path.hasSuffix(".jsonl") {
                    tracker.note(path: path)
                }
            }
        }

        let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes  // makes eventPaths a CFArray<CFString>
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            cb,
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05,  // 50 ms coalescing latency
            flags
        )
        guard let stream else { return false }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
        return FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
}

// MARK: - Synthetic streaming writer (mimics rapid JSONL append)

func writeSyntheticSession(slug: String, sessionId: String, lineCount: Int) {
    let dir = "\(projectsDir)/\(slug)"
    try? FileManager.default.createDirectory(
        atPath: dir, withIntermediateDirectories: true
    )
    let path = "\(dir)/\(sessionId).jsonl"
    let fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    guard fd >= 0 else { return }
    defer { close(fd) }
    for i in 0..<lineCount {
        // Realistic-ish line: mid-sized JSON, mostly content
        let line = "{\"type\":\"assistant\",\"sessionId\":\"\(sessionId)\",\"i\":\(i),\"content\":\"\(String(repeating: "x", count: 200))\"}\n"
        let data = Array(line.utf8)
        _ = data.withUnsafeBufferPointer { buf -> Int in
            write(fd, buf.baseAddress, buf.count)
        }
        // Tight loop most of the time, occasional small pause to spread events.
        if i % 50 == 0 { usleep(2_000) }
    }
    _ = fsync(fd)
}

func runSyntheticStress(concurrentSessions: Int, linesPerSession: Int) {
    let slug = "-stress-test-slug"
    let queue = DispatchQueue(label: "stress", attributes: .concurrent)
    let group = DispatchGroup()
    for k in 0..<concurrentSessions {
        group.enter()
        queue.async {
            let sessionId = "synthetic-session-\(k)"
            writeSyntheticSession(slug: slug, sessionId: sessionId, lineCount: linesPerSession)
            group.leave()
        }
    }
    group.wait()
}

// MARK: - Drive claude

func runClaudePrompt(_ prompt: String) -> Int32 {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/Users/oyvind/.local/bin/claude")
    task.arguments = ["-p", prompt]
    var env = ProcessInfo.processInfo.environment
    env["HOME"] = spikeHome
    task.environment = env
    task.currentDirectoryURL = URL(fileURLWithPath: spikeHome)
    let outPipe = Pipe()
    task.standardOutput = outPipe
    task.standardError = outPipe
    do {
        try task.run()
        task.waitUntilExit()
        return task.terminationStatus
    } catch {
        return -1
    }
}

// MARK: - Validation

func walkActual(_ dir: String) -> [String: Int] {
    var result: [String: Int] = [:]
    let url = URL(fileURLWithPath: dir)
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else {
        return result
    }
    for case let file as URL in enumerator where file.pathExtension == "jsonl" {
        if let data = try? Data(contentsOf: file) {
            let count = data.filter { $0 == 0x0A }.count
            result[file.path] = count
        }
    }
    return result
}

// MARK: - Main

setbuf(stdout, nil)

print("=== WatcherSpike (Spike 6) ===")
print("spikeHome=\(spikeHome)")
print("projectsDir=\(projectsDir)")

try? FileManager.default.removeItem(at: URL(fileURLWithPath: spikeHome))
try FileManager.default.createDirectory(
    at: URL(fileURLWithPath: projectsDir),
    withIntermediateDirectories: true
)

let tracker = TailTracker()
let watcher = FSWatcher(path: projectsDir, tracker: tracker)
guard watcher.start() else {
    print("Failed to start FSEventStream")
    exit(1)
}
print("FSEventStream started, latency=50ms")
print("")

print("Phase 1: synthetic stress (3 concurrent sessions × 1000 lines each)...")
let stressStart = Date()
runSyntheticStress(concurrentSessions: 3, linesPerSession: 1000)
let stressElapsed = Date().timeIntervalSince(stressStart)
print("  synthetic phase wrote 3000 lines in \(String(format: "%.2f", stressElapsed))s")
usleep(500_000)  // let FSEvents drain

print("")
print("Phase 2: real claude (3 prompts, may exit 1 if sandbox lacks credentials)...")
let prompts = [
    "say hi",
    "list five short adjectives describing chairs, one per line",
    "write a haiku about debugging, then a second haiku about deploying, then a third about testing",
]
for (i, prompt) in prompts.enumerated() {
    let exitCode = runClaudePrompt(prompt)
    print("  prompt #\(i + 1) exit=\(exitCode)")
    // Give FSEvents a moment to drain after each turn
    usleep(200_000)
}

// Final drain: 50 ms latency × ~10 just to be sure.
usleep(500_000)
watcher.stop()

// Compare
let observed = tracker.files
let actual = walkActual(projectsDir)

print("")
print("--- Per-file comparison ---")
var perfectFiles = 0
var mismatches = 0
let allPaths = Set(observed.keys).union(actual.keys)
for path in allPaths.sorted() {
    let obs = observed[path]?.lineCount ?? 0
    let act = actual[path] ?? 0
    let name = (path as NSString).lastPathComponent
    let dir = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    if obs == act {
        perfectFiles += 1
        print("  ✓ \(dir)/\(name)  observed=\(obs) actual=\(act)")
    } else {
        mismatches += 1
        print("  ✗ \(dir)/\(name)  observed=\(obs) actual=\(act) (delta=\(act - obs))")
    }
}
print("")
print("--- Summary ---")
print("  fsevents callbacks total:  \(tracker.totalCallbacks)")
print("  files seen:                \(allPaths.count)")
print("  per-file line counts ok:   \(perfectFiles)")
print("  per-file mismatches:       \(mismatches)")
print("  unparseable lines:         \(tracker.unparseableLines)")

let green = mismatches == 0 && tracker.unparseableLines == 0
print("")
print(green ? "RESULT: ✅" : "RESULT: 🔴")
exit(green ? 0 : 1)
