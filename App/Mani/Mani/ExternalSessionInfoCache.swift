import Foundation
import SwiftUI

// Per-session metadata cache for external (Mani-discovered) claude
// transcripts. The data in here doesn't fit on the reducer-driven Task
// model — it's derived from the on-disk JSONL and is purely UI-side
// (relative dates, message previews). Sidebar's PastSessionRow reads
// from this cache to show something more useful than a UUID.
//
// Populated:
//   - In `discoverHistoricalClaudeSessions` at launch (full scan).
//   - When `ClaudeWatcher.onMessages` reports activity (live count
//     update for currently-running externals).
@MainActor
final class ExternalSessionInfoCache: ObservableObject {
    static let shared = ExternalSessionInfoCache()

    struct Info: Equatable {
        let firstUserMessage: String?
        let lastMessageAt: Date?
        let messageCount: Int
    }

    @Published private(set) var entries: [String: Info] = [:]

    func record(sid: String, info: Info) {
        entries[sid] = info
    }

    // Bulk write: builds the new dict locally, then swaps in one
    // shot so SwiftUI sees a single @Published update. Used by the
    // safekeep sweep, which can replay hundreds of entries per
    // tick — per-key writes triggered hundreds of re-render
    // passes and made the UI feel locked during a sweep.
    func recordBatch(_ pairs: [(sid: String, info: Info)]) {
        guard !pairs.isEmpty else { return }
        var copy = entries
        for (sid, info) in pairs { copy[sid] = info }
        entries = copy
    }

    func touch(sid: String, lastMessageAt: Date, messageCount: Int) {
        if let existing = entries[sid] {
            entries[sid] = Info(
                firstUserMessage: existing.firstUserMessage,
                lastMessageAt: lastMessageAt,
                messageCount: messageCount
            )
        } else {
            entries[sid] = Info(
                firstUserMessage: nil,
                lastMessageAt: lastMessageAt,
                messageCount: messageCount
            )
        }
    }
}
