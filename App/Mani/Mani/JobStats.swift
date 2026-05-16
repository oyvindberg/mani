import Foundation
import SwiftUI

// Per-task runtime stats refreshed by a background poller every 5s. For
// claude tasks we expose the transcript file size (a useful proxy for
// "how much conversation has accumulated") plus the message count from
// the existing ExternalSessionInfoCache. Shell tasks get a stat hole —
// future polls could add RSS, log line counts etc.

struct TaskStats: Equatable {
    var transcriptBytes: Int?     // size of the <sid>.jsonl on disk
    var messageCount: Int?        // duplicated from ExternalSessionInfoCache for convenience
    var lastCheckedAt: Date
}

@MainActor
final class TaskStatsCache: ObservableObject {
    static let shared = TaskStatsCache()
    @Published private(set) var stats: [UUID: TaskStats] = [:]

    func record(taskId: UUID, stats: TaskStats) {
        self.stats[taskId] = stats
    }
}

final class TaskStatsPoller {
    private let tickSeconds: UInt64 = 5
    private weak var store: Store?
    private var task: _Concurrency.Task<Void, Never>?

    init(store: Store) {
        self.store = store
    }

    func start() {
        task?.cancel()
        task = _Concurrency.Task.detached(priority: .utility) { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !_Concurrency.Task.isCancelled {
            let snapshots = await collectSnapshots()
            for s in snapshots {
                guard !_Concurrency.Task.isCancelled else { return }
                let stats = Self.statsFor(snapshot: s)
                await MainActor.run {
                    TaskStatsCache.shared.record(taskId: s.taskId, stats: stats)
                }
            }
            try? await _Concurrency.Task.sleep(nanoseconds: tickSeconds * 1_000_000_000)
        }
    }

    // Snapshot of just the bits we need to compute stats off the main actor.
    private struct Snapshot {
        let taskId: UUID
        let sessionId: String?
        let cwd: URL
    }

    @MainActor
    private func collectSnapshots() async -> [Snapshot] {
        guard let store else { return [] }
        var out: [Snapshot] = []
        for repo in store.state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    if case let .claude(sid) = task.kind {
                        out.append(Snapshot(
                            taskId: task.id, sessionId: sid, cwd: task.spec.cwd
                        ))
                    }
                }
            }
        }
        return out
    }

    private static func statsFor(snapshot s: Snapshot) -> TaskStats {
        var bytes: Int? = nil
        var msgCount: Int? = nil
        if let sid = s.sessionId {
            let url = transcriptURL(forCwd: s.cwd, sessionId: sid)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let n = (attrs[.size] as? NSNumber)?.intValue {
                bytes = n
            }
            // Pull msg count from the existing ExternalSessionInfoCache if
            // the discovery + watcher path populated it.
            msgCount = nil // resolved on read-side from the cache directly
        }
        return TaskStats(
            transcriptBytes: bytes,
            messageCount: msgCount,
            lastCheckedAt: Date()
        )
    }

    private static func transcriptURL(forCwd cwd: URL, sessionId sid: String) -> URL {
        let path = cwd.path
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let slug = "-" + trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/repos")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sid).jsonl")
    }
}

// MARK: - Formatting helpers

enum TaskStatsFormatter {
    static func size(bytes: Int) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(bytes)
        var i = 0
        while value >= 1024 && i < units.count - 1 {
            value /= 1024
            i += 1
        }
        if i == 0 {
            return "\(bytes) B"
        }
        return String(format: "%.1f %@", value, units[i])
    }
}
