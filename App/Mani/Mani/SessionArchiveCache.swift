import Foundation
import SwiftUI
import ManiCore

// Main-actor cache of per-project session index entries.
//
// Boot:
//   1. ManiApp calls loadFromDisk(for:) for every project — populates
//      the cache from sessions-index.json instantly.
//   2. ExternalSessionInfoCache is mirrored from these entries so
//      every existing PastSessionRow / JobStats display keeps working
//      without modification.
//
// Live:
//   - SafekeepingSweeper replaces the per-project entry set every 5
//     min. Sidebar re-renders via @ObservedObject.
//   - ClaudeWatcher.onMessages still calls
//     ExternalSessionInfoCache.touch(...) for hot sessions; the
//     archive cache is for safekept state.
@MainActor
final class SessionArchiveCache: ObservableObject {
    static let shared = SessionArchiveCache()

    @Published private(set) var entriesByProject: [UUID: [SessionIndexEntry]] = [:]

    // Used by the sidebar status row to show "Scanning Claude
    // history…" while the very first post-boot sweep is in flight.
    @Published var bootstrapComplete: Bool = false

    func loadFromDisk(for projectId: UUID, store: SafekeepingStore) {
        let index = store.loadIndex(for: projectId)
        entriesByProject[projectId] = index.entries
        // Mirror into the legacy cache so PastSessionRow keeps working
        // unchanged.
        for entry in index.entries {
            ExternalSessionInfoCache.shared.record(
                sid: entry.sessionId,
                info: ExternalSessionInfoCache.Info(
                    firstUserMessage: entry.firstUserMessage,
                    lastMessageAt: entry.lastMessageAt,
                    messageCount: entry.messageCount
                )
            )
        }
    }

    func replace(entries: [SessionIndexEntry], for projectId: UUID) {
        entriesByProject[projectId] = entries
        for entry in entries {
            ExternalSessionInfoCache.shared.record(
                sid: entry.sessionId,
                info: ExternalSessionInfoCache.Info(
                    firstUserMessage: entry.firstUserMessage,
                    lastMessageAt: entry.lastMessageAt,
                    messageCount: entry.messageCount
                )
            )
        }
    }

    func entries(for projectId: UUID) -> [SessionIndexEntry] {
        entriesByProject[projectId] ?? []
    }

    // Split a project's entries into "originating worktree still
    // present" vs. "archived worktree". The caller (sidebar) passes
    // the live worktree paths; this is recomputed on every render so
    // it always reflects current state.
    func entriesByPresence(
        for projectId: UUID, worktreePaths: [String]
    ) -> (present: [SessionIndexEntry], archived: [SessionIndexEntry]) {
        let entries = entries(for: projectId)
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
