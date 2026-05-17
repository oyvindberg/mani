import Foundation
import CoreServices

// FSEvents-driven tail-tracker over ~/.claude/projects/. Validated by
// Spike 6 (docs/spikes.md): kFSEventStreamCreateFlagUseCFTypes is required;
// anchor the next read offset on bytes-actually-read, not stat size, to
// avoid double-counting under concurrent writes.
//
// Walking-skeleton scope: detect sessions and report them. Auto-linking
// detected sessions to Jobs comes in a later chunk (cwd + recency rules
// per docs/claude-integration.md).

// Not @MainActor at the class level: FSEvents fires on a background dispatch
// queue, and we hand-roll the mainactor handoff inside `note(path:)` →
// `publish(...)` so the on-disk parsing stays off the main thread.
final class ClaudeWatcher: ObservableObject {

    struct DetectedSession {
        let sessionId: String
        let path: String
        let cwd: String?
        let lastMessageAt: Date?
        let messageCount: Int
    }

    // Plain dict (not @Published): byte-arrivals from any active
    // claude session would otherwise fire objectWillChange on every
    // single line written, forcing a full SwiftUI rerender of
    // everything observing the watcher (sidebar, ready-claude bar,
    // detail panes). That pegged a core. The count is published
    // separately and only changes on add/remove.
    private(set) var sessions: [String: DetectedSession] = [:]
    @Published private(set) var sessionCount: Int = 0
    var onNewSession: ((DetectedSession) -> Void)?
    // Fires when an existing session's message count goes up. The Int is the
    // delta (always > 0). Used to bump per-task unread badges.
    var onMessages: ((DetectedSession, Int) -> Void)?
    // Fires whenever ANY new bytes are observed on a known session's
    // JSONL, including non-message records (compaction summaries,
    // file-history-snapshots, attachments, tool-use intermediate
    // writes). Drives the per-task "thinking" pulse — the UI signal
    // for "claude is doing something right now" needs the broader
    // surface, because messageCount only ticks for user/assistant
    // records.
    var onActivity: ((String) -> Void)?

    private struct FileTail {
        var size: UInt64
        var sessionId: String?
        var cwd: String?
        var lastMessageAt: Date?
        var messageCount: Int
    }

    private var stream: FSEventStreamRef?
    private let lock = NSLock()
    private var files: [String: FileTail] = [:]
    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    let reposDir: String

    init(reposDir: String) {
        self.reposDir = reposDir
    }

    func start() {
        guard stream == nil else { return }
        try? FileManager.default.createDirectory(
            atPath: reposDir, withIntermediateDirectories: true
        )

        let paths = [reposDir] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let cb: FSEventStreamCallback = { _, info, numEvents, eventPathsPtr, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<ClaudeWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(eventPathsPtr, to: NSArray.self) as! [String]
            for i in 0..<numEvents where paths[i].hasSuffix(".jsonl") {
                watcher.note(path: paths[i])
            }
        }

        let flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        stream = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &context, paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, flags
        )
        guard let stream else { return }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global())
        FSEventStreamStart(stream)
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    // Called on the FSEvents dispatch queue (background).
    private func note(path: String) {
        // Read tail under lock, decode lines, then publish on the main actor.
        lock.lock()
        let prev = files[path] ?? FileTail(size: 0, sessionId: nil, cwd: nil, lastMessageAt: nil, messageCount: 0)
        var fileState = prev

        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let statSize = (attrs[.size] as? NSNumber)?.uint64Value,
           statSize <= prev.size {
            lock.unlock()
            return
        }

        guard let fh = FileHandle(forReadingAtPath: path) else {
            lock.unlock()
            return
        }
        do { try fh.seek(toOffset: prev.size) } catch {
            try? fh.close()
            lock.unlock()
            return
        }
        let data = (try? fh.readToEnd()) ?? Data()
        try? fh.close()
        let bytesRead = UInt64(data.count)

        var startIdx = data.startIndex
        let decoder = JSONDecoder()
        while startIdx < data.endIndex {
            guard let nlIdx = data[startIdx...].firstIndex(of: 0x0A) else { break }
            let line = data[startIdx..<nlIdx]
            startIdx = data.index(after: nlIdx)
            if line.isEmpty { continue }
            if let envelope = try? decoder.decode(JSONLLine.self, from: line) {
                if fileState.sessionId == nil, let s = envelope.sessionId {
                    fileState.sessionId = s
                }
                if fileState.cwd == nil, let c = envelope.cwd {
                    fileState.cwd = c
                }
                if envelope.type == "user" || envelope.type == "assistant" {
                    fileState.messageCount += 1
                    if let ts = envelope.timestamp,
                       let date = isoFormatter.date(from: ts) {
                        fileState.lastMessageAt = date
                    }
                }
            }
        }

        fileState.size = prev.size + bytesRead
        files[path] = fileState
        let snapshot = (path: path, state: fileState)
        lock.unlock()

        if let sid = snapshot.state.sessionId {
            let detected = DetectedSession(
                sessionId: sid,
                path: snapshot.path,
                cwd: snapshot.state.cwd,
                lastMessageAt: snapshot.state.lastMessageAt,
                messageCount: snapshot.state.messageCount
            )
            let sawBytes = bytesRead > 0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let prev = self.sessions[sid]
                self.sessions[sid] = detected
                if prev == nil {
                    self.sessionCount = self.sessions.count
                    self.onNewSession?(detected)
                } else if let prev, detected.messageCount > prev.messageCount {
                    self.onMessages?(detected, detected.messageCount - prev.messageCount)
                }
                // Activity signal fires regardless of whether the new
                // bytes contained a user/assistant message — covers
                // compaction, tool-use streaming, etc.
                if sawBytes { self.onActivity?(sid) }
            }
        }
    }
}

// Minimal decoder for the JSONL fields we actually use. Permissive — all
// fields optional; unknown extras are ignored.
private struct JSONLLine: Decodable {
    let type: String?
    let sessionId: String?
    let cwd: String?
    let timestamp: String?
}
