import Foundation
import ManiCore
import SwiftUI

// Background process that:
//   1. Walks ~/.claude/projects/-<slug>/*.jsonl
//   2. Matches each session file's recorded cwd to the longest-prefix
//      worktree across all projects in the live AppState.
//   3. For settled files (mtime > 5 min) without a safekept copy:
//      gzip-archive the JSONL and upsert a full index entry.
//   4. For hot files (mtime <= 5 min): upsert a thin index entry only.
//      The next sweep that catches the file after it settles archives it.
//   5. Publishes per-project entries (full set, including archived-
//      worktree ones) onto SessionArchiveCache so the sidebar can
//      render PastSessionRow + the "Archived worktrees" group.
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

    private let store: Store
    private let archive: SafekeepingStore
    private let cache: SessionArchiveCache
    private var loopTask: Task<Void, Never>?

    init(store: Store, archive: SafekeepingStore, cache: SessionArchiveCache) {
        self.store = store
        self.archive = archive
        self.cache = cache
    }

    func start() {
        loopTask?.cancel()
        loopTask = Task { @MainActor [weak self] in
            // First sweep is delayed 5s so the UI gets a chance to draw
            // and the rest of the boot path runs unimpeded. The user's
            // existing cache (from the previous app session) is already
            // visible from disk via SessionArchiveCache.loadFromDisk.
            try? await Task.sleep(nanoseconds: 5 * 1_000_000_000)
            while !Task.isCancelled {
                guard let self else { return }
                await self.runOnce()
                try? await Task.sleep(nanoseconds: 5 * 60 * 1_000_000_000)
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
            lastSweepAt = Date()
        }

        // Snapshot the project→worktrees map up-front. The sweep runs
        // off-main; if state mutates mid-sweep that's fine, but a
        // stable snapshot keeps the matching consistent.
        let projectsSnapshot: [ProjectMatcher] = store.state.projects.map {
            ProjectMatcher(
                id: $0.id,
                worktreePaths: $0.worktrees.map { $0.path.resolvingSymlinksInPath().path }
            )
        }
        let archive = self.archive
        let cache = self.cache

        // The actual filesystem walk + gzip work runs off the main
        // actor; results come back as a per-project diff to apply to
        // the cache.
        let diffs = await Task.detached(priority: .utility) {
            SafekeepingSweepWorker.sweep(
                projects: projectsSnapshot, archive: archive
            )
        }.value

        for (projectId, entries) in diffs {
            cache.replace(entries: entries, for: projectId)
        }
    }
}

// Pure-data view of a project for the off-main sweep — avoids
// snapshotting Project structs across actor boundaries.
struct ProjectMatcher {
    let id: UUID
    let worktreePaths: [String]
}

enum SafekeepingSweepWorker {

    // Returns [projectId: full current entries] for any project that
    // had at least one matched session file. Projects with no matches
    // are omitted (don't touch their cache slot).
    static func sweep(
        projects: [ProjectMatcher],
        archive: SafekeepingStore
    ) -> [UUID: [SessionIndexEntry]] {
        let claudeRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let slugDirs = try? FileManager.default.contentsOfDirectory(
            at: claudeRoot, includingPropertiesForKeys: nil
        ) else { return [:] }

        // Start each project from its on-disk index. We re-write only
        // when something actually changed, so a no-op sweep doesn't
        // bump file mtimes.
        var indexes: [UUID: SessionIndex] = [:]
        var changed: Set<UUID> = []
        for project in projects {
            indexes[project.id] = archive.loadIndex(for: project.id)
        }

        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let now = Date()

        for slugDir in slugDirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: slugDir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let jsonls = (try? FileManager.default.contentsOfDirectory(
                at: slugDir, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []

            for jsonl in jsonls where jsonl.pathExtension == "jsonl" {
                let sessionId = jsonl.deletingPathExtension().lastPathComponent

                // First-line peek: cheap. Gives us cwd + sometimes the
                // first user message in a few KB of read.
                guard let peek = peekFirstLine(jsonl: jsonl),
                      let cwd = peek.cwd
                else { continue }

                if cwd == homePath || cwd == "/" { continue }

                guard let match = bestMatch(cwd: cwd, projects: projects) else { continue }
                let projectId = match.id

                // Re-parse for the full summary (lastMessageAt, count,
                // firstUserMessage). Cheaper than it sounds: the
                // ClaudeHistoryScanner reads stream-style and stops at
                // EOF.
                guard let summary = ClaudeHistoryScanner.parsePublic(jsonl: jsonl)
                else { continue }

                let mtime = (try? jsonl.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                let settled = now.timeIntervalSince(mtime) > 5 * 60

                let alreadyArchived = archive.hasTranscript(
                    sessionId: sessionId, for: projectId
                )
                let existing = indexes[projectId]?.entries
                    .first(where: { $0.sessionId == sessionId })

                var archivedAt: Date? = existing?.archivedAt
                var transcriptBytes: Int = existing?.transcriptBytes ?? 0

                if settled && !alreadyArchived {
                    do {
                        let bytes = try archive.archiveTranscript(
                            from: jsonl, sessionId: sessionId, for: projectId
                        )
                        archivedAt = Date()
                        transcriptBytes = bytes
                    } catch {
                        NSLog("[mani] safekeeping archive failed for \(sessionId): \(error)")
                    }
                }

                let entry = SessionIndexEntry(
                    sessionId: sessionId,
                    originatingCwd: cwd,
                    originatingWorktreeName: URL(fileURLWithPath: cwd).lastPathComponent,
                    firstUserMessage: summary.firstUserMessage,
                    lastMessageAt: summary.lastMessageAt,
                    messageCount: summary.messageCount,
                    transcriptBytes: transcriptBytes,
                    archivedAt: archivedAt
                )

                if existing != entry {
                    var idx = indexes[projectId] ?? .empty
                    if let i = idx.entries.firstIndex(where: { $0.sessionId == sessionId }) {
                        idx.entries[i] = entry
                    } else {
                        idx.entries.append(entry)
                    }
                    indexes[projectId] = idx
                    changed.insert(projectId)
                }
            }
        }

        // Flush changed indexes to disk. Errors here are logged but
        // not propagated — the in-memory result still goes to the
        // cache so the UI updates.
        for projectId in changed {
            guard let idx = indexes[projectId] else { continue }
            do {
                try archive.writeIndex(idx, for: projectId)
            } catch {
                NSLog("[mani] safekeeping index write failed: \(error)")
            }
        }

        // Even unchanged projects should be returned so the cache
        // reflects the on-disk state on a fresh boot (where the cache
        // starts empty and the index is the source of truth).
        var result: [UUID: [SessionIndexEntry]] = [:]
        for project in projects {
            result[project.id] = indexes[project.id]?.entries ?? []
        }
        return result
    }

    private static func bestMatch(
        cwd: String, projects: [ProjectMatcher]
    ) -> ProjectMatcher? {
        var best: ProjectMatcher?
        var bestLen = 0
        for project in projects {
            for wt in project.worktreePaths {
                if cwd == wt || cwd.hasPrefix(wt + "/") {
                    if wt.count > bestLen {
                        bestLen = wt.count
                        best = project
                    }
                }
            }
        }
        return best
    }

    // Read just the first line of a JSONL to get cwd + sessionId
    // without loading the full transcript. The JSONL format puts a
    // header-ish first record up top so this is enough for matching.
    private static func peekFirstLine(jsonl: URL) -> (cwd: String?, sid: String?)? {
        guard let stream = InputStream(url: jsonl) else { return nil }
        stream.open()
        defer { stream.close() }
        var buf = [UInt8](repeating: 0, count: 4096)
        var data = Data()
        while stream.hasBytesAvailable {
            let n = stream.read(&buf, maxLength: buf.count)
            if n <= 0 { break }
            data.append(buf, count: n)
            if let nl = data.firstIndex(of: 0x0A) {
                data = data.subdata(in: 0..<nl)
                break
            }
            if data.count > 64 * 1024 { break } // safety
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return (json["cwd"] as? String, json["sessionId"] as? String)
    }
}
