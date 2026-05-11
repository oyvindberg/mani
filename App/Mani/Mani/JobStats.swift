import Foundation
import SwiftUI

// Per-job runtime stats refreshed by a background poller every 5s. For
// claude jobs we expose the transcript file size (a useful proxy for
// "how much conversation has accumulated") plus the message count from
// the existing ExternalSessionInfoCache. Shell jobs get a stat hole —
// future polls could add RSS, log line counts etc.

struct JobStats: Equatable {
    var transcriptBytes: Int?     // size of the <sid>.jsonl on disk
    var messageCount: Int?        // duplicated from ExternalSessionInfoCache for convenience
    var lastCheckedAt: Date
}

@MainActor
final class JobStatsCache: ObservableObject {
    static let shared = JobStatsCache()
    @Published private(set) var stats: [UUID: JobStats] = [:]

    func record(jobId: UUID, stats: JobStats) {
        self.stats[jobId] = stats
    }
}

final class JobStatsPoller {
    private let tickSeconds: UInt64 = 5
    private weak var store: Store?
    private var task: Task<Void, Never>?

    init(store: Store) {
        self.store = store
    }

    func start() {
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            await self?.loop()
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func loop() async {
        while !Task.isCancelled {
            let snapshots = await collectSnapshots()
            for s in snapshots {
                guard !Task.isCancelled else { return }
                let stats = Self.statsFor(snapshot: s)
                await MainActor.run {
                    JobStatsCache.shared.record(jobId: s.jobId, stats: stats)
                }
            }
            try? await Task.sleep(nanoseconds: tickSeconds * 1_000_000_000)
        }
    }

    // Snapshot of just the bits we need to compute stats off the main actor.
    private struct Snapshot {
        let jobId: UUID
        let sessionId: String?
        let cwd: URL
    }

    @MainActor
    private func collectSnapshots() async -> [Snapshot] {
        guard let store else { return [] }
        var out: [Snapshot] = []
        for project in store.state.projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    if case let .claude(sid) = job.kind {
                        out.append(Snapshot(
                            jobId: job.id, sessionId: sid, cwd: job.primary.cwd
                        ))
                    }
                }
            }
        }
        return out
    }

    private static func statsFor(snapshot s: Snapshot) -> JobStats {
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
        return JobStats(
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
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sid).jsonl")
    }
}

// MARK: - Formatting helpers

enum JobStatsFormatter {
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
