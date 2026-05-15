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
