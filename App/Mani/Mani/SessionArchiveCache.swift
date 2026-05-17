import Foundation
import SwiftUI
import ManiCore

// Main-actor cache of per-repo session index entries.
//
// Boot:
//   1. ManiApp calls loadFromDisk(for:) for every repo — populates
//      the cache from sessions-index.json instantly.
//   2. ExternalSessionInfoCache is mirrored from these entries so
//      every existing PastSessionRow / TaskStats display keeps working
//      without modification.
//
// Live:
//   - SafekeepingSweeper replaces the per-repo entry set every 5
//     min. Sidebar re-renders via @ObservedObject.
//   - ClaudeWatcher.onMessages still calls
//     ExternalSessionInfoCache.touch(...) for hot sessions; the
//     archive cache is for safekept state.
@MainActor
final class SessionArchiveCache: ObservableObject {
    static let shared = SessionArchiveCache()

    @Published private(set) var entriesByRepo: [UUID: [SessionIndexEntry]] = [:]

    // Used by the sidebar status row to show "Scanning Claude
    // history…" while the very first post-boot sweep is in flight.
    @Published var bootstrapComplete: Bool = false

    func loadFromDisk(for repoId: UUID, store: SafekeepingStore) {
        let index = store.loadIndex(for: repoId)
        entriesByRepo[repoId] = index.entries
        mirrorToInfoCache(index.entries)
    }

    func replace(entries: [SessionIndexEntry], for repoId: UUID) {
        entriesByRepo[repoId] = entries
        mirrorToInfoCache(entries)
    }

    private func mirrorToInfoCache(_ entries: [SessionIndexEntry]) {
        // Single @Published update across all entries so SwiftUI
        // re-renders once instead of N times. Per-entry record()
        // calls during a sweep used to thrash the sidebar.
        let pairs = entries.map { entry in
            (sid: entry.sessionId,
             info: ExternalSessionInfoCache.Info(
                firstUserMessage: entry.firstUserMessage,
                lastMessageAt: entry.lastMessageAt,
                messageCount: entry.messageCount
             ))
        }
        ExternalSessionInfoCache.shared.recordBatch(pairs)
    }

    func entries(for repoId: UUID) -> [SessionIndexEntry] {
        entriesByRepo[repoId] ?? []
    }

    // Split a repo's entries into "originating project still
    // present" vs. "archived project". The caller (sidebar) passes
    // the live project paths; this is recomputed on every render so
    // it always reflects current state.
    func entriesByPresence(
        for repoId: UUID, worktreePaths: [String]
    ) -> (present: [SessionIndexEntry], archived: [SessionIndexEntry]) {
        let entries = entries(for: repoId)
        var present: [SessionIndexEntry] = []
        var archived: [SessionIndexEntry] = []
        for entry in entries {
            if isCwd(entry.originatingCwd, underAny: worktreePaths) {
                present.append(entry)
            } else {
                archived.append(entry)
            }
        }
        return (present, archived)
    }

    private func isCwd(_ cwd: String, underAny paths: [String]) -> Bool {
        for path in paths {
            if cwd == path || cwd.hasPrefix(path + "/") { return true }
        }
        return false
    }
}
