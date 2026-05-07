import Foundation
import Darwin
import ManiCore

// Tier 2 (events) + Tier 3 (snapshot) of docs/persistence.md.
// Tier 1 (scrollback) is per-task PTY output and lives elsewhere.
//
// Carries forward into the app target as real v0.1 infrastructure (per
// docs/spikes.md spike 5 disposition).

public enum PersistenceError: Error {
    case openFailed(path: String, errno: Int32)
    case writeFailed(path: String, errno: Int32)
}

// On-disk events.jsonl line: timestamp + the Event itself. The timestamp
// lets recovery skip events already folded into a snapshot taken at a
// later mtime — guarding the window between snapshot rename and
// events.jsonl truncation, which could otherwise re-apply non-idempotent
// events (e.g. projectCreated would duplicate).
struct StoredEvent: Codable {
    let t: Date
    let event: Event
}

public final class PersistenceStore {
    public let rootDir: URL
    public var stateURL: URL    { rootDir.appendingPathComponent("state.json") }
    public var stateBakURL: URL { rootDir.appendingPathComponent("state.json.bak") }
    public var stateNewURL: URL { rootDir.appendingPathComponent("state.json.new") }
    public var eventsURL: URL   { rootDir.appendingPathComponent("events.jsonl") }

    public init(rootDir: URL) throws {
        self.rootDir = rootDir
        try FileManager.default.createDirectory(
            at: rootDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: Tier 2 — append + per-event fsync

    public func appendEvent(_ event: Event) throws {
        let stored = StoredEvent(t: Date(), event: event)
        var line = try JSONEncoder().encode(stored)
        line.append(0x0A)

        let fd = open(eventsURL.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        if fd < 0 {
            throw PersistenceError.openFailed(path: eventsURL.path, errno: errno)
        }
        defer { close(fd) }

        try line.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = line.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw PersistenceError.writeFailed(path: eventsURL.path, errno: errno)
                }
                remaining -= Int(n)
                ptr = ptr.advanced(by: Int(n))
            }
        }

        // Durability boundary: per-event fsync, per spec.
        _ = fsync(fd)
    }

    // MARK: Tier 3 — atomic snapshot + truncate events

    public func compact(_ state: AppState) throws {
        let data = try JSONEncoder().encode(state)

        // 1. Write to .new + fsync
        let fd = open(stateNewURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if fd < 0 {
            throw PersistenceError.openFailed(path: stateNewURL.path, errno: errno)
        }
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = data.count
            var ptr = base
            while remaining > 0 {
                let n = Darwin.write(fd, ptr, remaining)
                if n < 0 {
                    if errno == EINTR { continue }
                    close(fd)
                    throw PersistenceError.writeFailed(path: stateNewURL.path, errno: errno)
                }
                remaining -= Int(n)
                ptr = ptr.advanced(by: Int(n))
            }
        }
        _ = fsync(fd)
        close(fd)

        // 2. Rotate state.json → state.json.bak (only if state.json exists)
        if FileManager.default.fileExists(atPath: stateURL.path) {
            _ = rename(stateURL.path, stateBakURL.path)
        }

        // 3. Promote .new → state.json
        _ = rename(stateNewURL.path, stateURL.path)

        // 4. fsync the directory so the rename is durable
        let dirFD = open(rootDir.path, O_RDONLY)
        if dirFD >= 0 {
            _ = fsync(dirFD)
            close(dirFD)
        }

        // 5. Truncate events.jsonl
        let evFD = open(eventsURL.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        if evFD >= 0 {
            _ = fsync(evFD)
            close(evFD)
        }
    }

    // MARK: Recovery

    public struct RecoveryReport {
        public var snapshotSource: String  // "state.json" | "state.json.bak" | "empty"
        public var eventsReplayed: Int
        public var eventsSkippedOnDecodeFailure: Int
    }

    public func recover() throws -> (state: AppState, report: RecoveryReport) {
        var report = RecoveryReport(
            snapshotSource: "empty",
            eventsReplayed: 0,
            eventsSkippedOnDecodeFailure: 0
        )
        var state = AppState.empty

        if let s = readSnapshot(at: stateURL) {
            state = s
            report.snapshotSource = "state.json"
        } else if let s = readSnapshot(at: stateBakURL) {
            state = s
            report.snapshotSource = "state.json.bak"
            // If the .new file exists, recovery midway through compact happened —
            // promote it. Safe because .new was fsync'd before rename.
            if FileManager.default.fileExists(atPath: stateNewURL.path),
               let promoted = readSnapshot(at: stateNewURL) {
                state = promoted
                report.snapshotSource = "state.json.new (promoted from mid-compact)"
            }
        }

        if FileManager.default.fileExists(atPath: eventsURL.path) {
            // Anchor: the mtime of the snapshot we just loaded. Events strictly
            // newer than this are real; events at or before this are already
            // in the snapshot (the truncate step may have been interrupted).
            // distantPast means "no snapshot yet, apply everything".
            let anchor = snapshotMtime() ?? .distantPast
            let (stored, skipped) = readEvents()
            for s in stored where s.t > anchor {
                apply(&state, s.event)
                report.eventsReplayed += 1
            }
            report.eventsSkippedOnDecodeFailure = skipped
        }

        return (state, report)
    }

    private func snapshotMtime() -> Date? {
        let path: String
        if FileManager.default.fileExists(atPath: stateURL.path) {
            path = stateURL.path
        } else if FileManager.default.fileExists(atPath: stateBakURL.path) {
            path = stateBakURL.path
        } else {
            return nil
        }
        return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
    }

    private func readSnapshot(at url: URL) -> AppState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppState.self, from: data)
    }

    private func readEvents() -> (events: [StoredEvent], skippedOnDecodeFailure: Int) {
        guard let data = try? Data(contentsOf: eventsURL) else { return ([], 0) }
        let decoder = JSONDecoder()
        var events: [StoredEvent] = []
        var skipped = 0
        var start = data.startIndex
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start {
                let lineData = data[start..<end]
                if let stored = try? decoder.decode(StoredEvent.self, from: lineData) {
                    events.append(stored)
                } else {
                    // The last line may be truncated (kill -9 mid-write). One trailing
                    // bad line is expected and not a corruption; multiple is suspicious.
                    skipped += 1
                }
            }
            start = end < data.endIndex ? data.index(after: end) : data.endIndex
        }
        return (events, skipped)
    }
}
