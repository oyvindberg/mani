import Foundation
import ManiCore
import SwiftUI

// Background process that:
//   1. Walks ~/.claude/repos/-<slug>/*.jsonl
//   2. Matches each session file's recorded cwd to the longest-prefix
//      project across all repos in the live AppState.
//   3. For settled files (mtime > 5 min) without a safekept copy:
//      gzip-archive the JSONL and upsert a full index entry.
//   4. For hot files (mtime <= 5 min): upsert a thin index entry only.
//      The next sweep that catches the file after it settles archives it.
//   5. Publishes per-repo entries (full set, including archived-
//      project ones) onto SessionArchiveCache so the sidebar can
//      render PastSessionRow + the "Archived projects" group.
//
// Scheduling:
//   - One sweep ~5s after launch (so the UI is interactive first).
//   - Every 5 min thereafter.
//   - Sweeper.isRunning publishes to drive the "Scanning Claude history…"
//     status row in the sidebar.
@MainActor
final class SafekeepingSweeper: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastSweepAt: Date?
    // The slug directory currently being scanned (e.g.
    // "-Users-oyvind-asp"). Cleared after the sweep finishes. The
    // sidebar status row reads this to render "Scanning Claude
    // history… (-Users-oyvind-asp)".
    @Published private(set) var currentScanLabel: String?

    private let store: Store
    private let archive: SafekeepingStore
    private let cache: SessionArchiveCache
    private var loopTask: _Concurrency.Task<Void, Never>?

    init(store: Store, archive: SafekeepingStore, cache: SessionArchiveCache) {
        self.store = store
        self.archive = archive
        self.cache = cache
    }

    func start() {
        loopTask?.cancel()
        loopTask = _Concurrency.Task { @MainActor [weak self] in
            // First sweep is delayed 5s so the UI gets a chance to draw
            // and the rest of the boot path runs unimpeded. The user's
            // existing cache (from the previous app session) is already
            // visible from disk via SessionArchiveCache.loadFromDisk.
            try? await _Concurrency.Task.sleep(nanoseconds: 5 * 1_000_000_000)
            while !_Concurrency.Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                try? await _Concurrency.Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // One pass. Called automatically every 5 min by start(); also
    // exposed so future code (e.g. "Refresh now" menu) can trigger.
    func runOnce() async {
        isRunning = true
        defer {
            isRunning = false
            currentScanLabel = nil
            lastSweepAt = Date()
        }

        // Snapshot the repo→projects map up-front. The sweep runs
        // off-main; if state mutates mid-sweep that's fine, but a
        // stable snapshot keeps the matching consistent.
        let reposSnapshot: [RepoMatcher] = store.state.repos.map {
            RepoMatcher(
                id: $0.id,
                name: $0.name,
                worktreePaths: $0.projects.map { $0.workspace.path.resolvingSymlinksInPath().path }
            )
        }
        let archive = self.archive
        let cache = self.cache

        // Progress callback published back onto the main actor so the
        // sidebar status row can show which slug is being scanned.
        let progress: (String) -> Void = { [weak self] label in
            _Concurrency.Task { @MainActor [weak self] in
                self?.currentScanLabel = label
            }
        }

        // The actual filesystem walk + gzip work runs off the main
        // actor; results come back as a per-repo diff to apply to
        // the cache.
        let diffs = await _Concurrency.Task.detached(priority: .utility) {
            SafekeepingSweepWorker.sweep(
                repos: reposSnapshot, archive: archive, progress: progress
            )
        }.value

        for (repoId, entries) in diffs {
            cache.replace(entries: entries, for: repoId)
        }
        // Reactive discovery: a repo the user just created (or a
        // claude conversation that pre-existed the repo) needs
        // Jobs dispatched once the cache catches up. Without this
        // call, those sessions would only show up after the next
        // app restart's bootstrap pass.
        await ManiApp.reconcileJobsForArchivedSessions(store: store, cache: cache)
    }
}

// Pure-data view of a repo for the off-main sweep — avoids
// snapshotting Repo structs across actor boundaries.
struct RepoMatcher {
    let id: UUID
    let name: String
    let worktreePaths: [String]
}

enum SafekeepingSweepWorker {

    // Returns [repoId: full current entries] for any repo that
    // had at least one matched session file. Repos with no matches
    // are omitted (don't touch their cache slot).
    static func sweep(
        repos: [RepoMatcher],
        archive: SafekeepingStore,
        progress: (String) -> Void
    ) -> [UUID: [SessionIndexEntry]] {
        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/repos")
        guard let slugDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeRoot, includingPropertiesForKeys: nil
        ) else { return [:] }

        // Rebuild each repo's index from scratch this pass. We
        // seed an "archived metadata" lookup from the prior on-disk
        // index so previously-archived sessions keep their
        // archivedAt + transcriptBytes; entries we don't re-add this
        // pass are dropped (content-gone cleanup).
        var indexes: [UUID: SessionIndex] = [:]
        var priorArchived: [UUID: [String: SessionIndexEntry]] = [:]
        var changed: Set<UUID> = []
        for repo in repos {
            let prior = archive.loadIndex(for: repo.id)
            var lookup: [String: SessionIndexEntry] = [:]
            for entry in prior.entries { lookup[entry.sessionId] = entry }
            priorArchived[repo.id] = lookup
            indexes[repo.id] = .empty
            if !prior.entries.isEmpty { changed.insert(repo.id) }
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path

        // Single source of truth: claude's own per-slug sessions-
        // index.json. One small JSON per slug dir, already pre-
        // indexed. We never open individual JSONL files for
        // metadata — that's hundreds of MB of file I/O.
        //
        // Archiving (gzipping the transcript) IS the only time we
        // touch a JSONL, and only ONCE per session — the
        // alreadySafekept check skips re-archival on every sweep.
        for slugDir in slugDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: slugDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            progress(slugDir.lastPathComponent)

            let claudeIndexURL = slugDir
                .appendingPathComponent("sessions-index.json", isDirectory: false)
            guard FileManager.default.fileExists(atPath: claudeIndexURL.path),
                  let data = try? Data(contentsOf: claudeIndexURL),
                  let parsed = ClaudeOwnSessionsIndex.parse(data: data)
            else { continue }

            for record in parsed.entries {
                let cwd = record.repoPath
                if cwd == homePath || cwd == "/" { continue }
                guard let match = bestMatch(cwd: cwd, repos: repos)
                else { continue }
                let repoId = match.id

                let fullPath = URL(fileURLWithPath: record.fullPath)
                let transcriptExists = FileManager.default
                    .fileExists(atPath: fullPath.path)
                let alreadySafekept = archive.hasTranscript(
                    sessionId: record.sessionId, for: repoId
                )
                // Content-gone (no JSONL, no gzip) → skip; nothing
                // actionable for the user.
                if !transcriptExists, !alreadySafekept { continue }

                let prior = priorArchived[repoId]?[record.sessionId]
                var archivedAt: Date? = prior?.archivedAt
                var transcriptBytes: Int = prior?.transcriptBytes ?? 0

                if transcriptExists, !alreadySafekept {
                    do {
                        let bytes = try archive.archiveTranscript(
                            from: fullPath, sessionId: record.sessionId,
                            for: repoId
                        )
                        archivedAt = Date()
                        transcriptBytes = bytes
                    } catch {
                        NSLog("[mani] safekeeping archive failed for \(record.sessionId): \(error)")
                    }
                }

                let entry = SessionIndexEntry(
                    sessionId: record.sessionId,
                    originatingCwd: cwd,
                    originatingWorktreeName: URL(fileURLWithPath: cwd).lastPathComponent,
                    firstUserMessage: record.firstPrompt ?? record.summary,
                    lastMessageAt: record.modified,
                    messageCount: record.messageCount ?? 0,
                    transcriptBytes: transcriptBytes,
                    archivedAt: archivedAt
                )

                var idx = indexes[repoId] ?? .empty
                idx.entries.append(entry)
                indexes[repoId] = idx
                if prior != entry { changed.insert(repoId) }
            }
        }

        // Flush changed indexes to disk. Errors here are logged but
        // not propagated — the in-memory result still goes to the
        // cache so the UI updates.
        for repoId in changed {
            guard let idx = indexes[repoId] else { continue }
            do {
                try archive.writeIndex(idx, for: repoId)
            } catch {
                NSLog("[mani] safekeeping index write failed: \(error)")
            }
        }

        // Even unchanged repos should be returned so the cache
        // reflects the on-disk state on a fresh boot (where the cache
        // starts empty and the index is the source of truth).
        var result: [UUID: [SessionIndexEntry]] = [:]
        for repo in repos {
            result[repo.id] = indexes[repo.id]?.entries ?? []
        }
        return result
    }

    private static func bestMatch(
        cwd: String, repos: [RepoMatcher]
    ) -> RepoMatcher? {
        var best: RepoMatcher?
        var bestLen = 0
        for repo in repos {
            for wt in repo.worktreePaths {
                if cwd == wt || cwd.hasPrefix(wt + "/") {
                    if wt.count > bestLen {
                        bestLen = wt.count
                        best = repo
                    }
                }
            }
        }
        return best
    }

    // Scan the first N lines of a JSONL until we find both `cwd`
    // and `sessionId`. Older claude versions put cwd on line 1;
    // newer ones lead with a `permission-mode` record (no cwd) and
    // sometimes a `file-history-snapshot` record before getting to
    // the first user message (which carries the cwd at the top
    // level). Read up to a bounded byte/line budget covering all
    // observed formats.
    private static func peekFirstLine(jsonl: URL) -> (cwd: String?, sid: String?)? {
        // Read in one shot up to a safe upper bound — bigger than
        // any plausible header but small enough to be cheap. Then
        // split into UTF-8 byte lines explicitly with our own
        // offset arithmetic (Data indices aren't 0-based after
        // mutation, which broke an earlier streaming attempt).
        guard let handle = try? FileHandle(forReadingFrom: jsonl) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 256 * 1024) else { return nil }
        var cwd: String?
        var sid: String?
        var linesScanned = 0
        let maxLines = 30
        var start = 0
        let bytes = [UInt8](data)
        while start < bytes.count, linesScanned < maxLines {
            var end = start
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            if end > start {
                let lineData = Data(bytes[start..<end])
                if let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                    if cwd == nil, let c = json["cwd"] as? String { cwd = c }
                    if sid == nil, let s = json["sessionId"] as? String { sid = s }
                    if cwd != nil, sid != nil { return (cwd, sid) }
                }
            }
            linesScanned += 1
            start = end + 1
        }
        if cwd == nil && sid == nil { return nil }
        return (cwd, sid)
    }
}

// Reader for claude's own sessions-index.json file (one per slug
// dir). Format example:
//   { "version": 1, "entries": [
//       { "sessionId": "...", "fullPath": "...", "firstPrompt": "...",
//         "summary": "...", "messageCount": 58, "modified": "...",
//         "repoPath": "...", ... }
//   ]}
// We only pluck the fields we need; missing ones decode as nil.
enum ClaudeOwnSessionsIndex {

    struct Record {
        let sessionId: String
        let fullPath: String
        let firstPrompt: String?
        let summary: String?
        let messageCount: Int?
        let modified: Date?
        let repoPath: String
    }

    struct Parsed {
        let entries: [Record]
    }

    static func parse(data: Data) -> Parsed? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let entriesRaw = root["entries"] as? [[String: Any]] else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]

        var out: [Record] = []
        for raw in entriesRaw {
            guard let sid = raw["sessionId"] as? String,
                  let fullPath = raw["fullPath"] as? String,
                  let repoPath = raw["repoPath"] as? String
            else { continue }
            let modified: Date? = (raw["modified"] as? String).flatMap {
                iso.date(from: $0) ?? isoNoFrac.date(from: $0)
            }
            out.append(Record(
                sessionId: sid,
                fullPath: fullPath,
                firstPrompt: raw["firstPrompt"] as? String,
                summary: raw["summary"] as? String,
                messageCount: raw["messageCount"] as? Int,
                modified: modified,
                repoPath: repoPath
            ))
        }
        return Parsed(entries: out)
    }
}
