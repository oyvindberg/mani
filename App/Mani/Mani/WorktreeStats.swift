import Foundation
import SwiftUI

// Background git poller. Every 5 seconds it shells out to git in each
// worktree path and refreshes branch + ahead/behind counts against the
// remote tracking branch (or origin/main / origin/master as a fallback).
// Periodic background `git fetch` keeps the ahead/behind numbers honest;
// it runs at a slower cadence (~5 min) so we don't hammer the network.

struct WorktreeGitStats: Equatable {
    var branch: String?           // current branch name; nil when detached
    var upstream: String?         // tracking ref, e.g. "origin/main"
    var ahead: Int                // local commits not in upstream
    var behind: Int               // upstream commits not in local
    var hasUncommitted: Bool      // anything in `git status --porcelain`
    var lastCheckedAt: Date
}

@MainActor
final class WorktreeStatsCache: ObservableObject {
    static let shared = WorktreeStatsCache()
    @Published private(set) var stats: [UUID: WorktreeGitStats] = [:]

    func record(worktreeId: UUID, stats: WorktreeGitStats) {
        self.stats[worktreeId] = stats
    }
}

// Runs in the background, polls every `localTickSeconds`, fetches every
// `fetchTickSeconds`. Kept alive by the main actor's reference.
final class WorktreeStatsPoller {
    private let localTickSeconds: UInt64 = 5
    private let fetchTickSeconds: UInt64 = 5 * 60
    private weak var store: Store?
    private var task: Task<Void, Never>?
    private var lastFetchAt: Date = .distantPast

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
            let worktrees = await collectWorktrees()
            let now = Date()
            let shouldFetch = now.timeIntervalSince(lastFetchAt) > Double(fetchTickSeconds)
            if shouldFetch { lastFetchAt = now }

            for (id, path) in worktrees {
                guard !Task.isCancelled else { return }
                if shouldFetch {
                    _ = Self.runGit(["fetch", "--quiet", "--no-tags"], in: path)
                }
                let stats = Self.statsFor(path: path)
                await MainActor.run {
                    WorktreeStatsCache.shared.record(worktreeId: id, stats: stats)
                }
            }

            try? await Task.sleep(nanoseconds: localTickSeconds * 1_000_000_000)
        }
    }

    @MainActor
    private func collectWorktrees() async -> [(UUID, URL)] {
        guard let store else { return [] }
        var result: [(UUID, URL)] = []
        for project in store.state.projects {
            for worktree in project.worktrees {
                result.append((worktree.id, worktree.path))
            }
        }
        return result
    }

    // MARK: Static git helpers

    private static func statsFor(path: URL) -> WorktreeGitStats {
        let branch = runGit(["symbolic-ref", "--short", "HEAD"], in: path)
        // Try the explicit upstream first; fall back to origin/main →
        // origin/master so untracked branches still get meaningful
        // numbers in the common case.
        let upstream =
            runGit(["rev-parse", "--abbrev-ref", "@{upstream}"], in: path)
            ?? (refExists("origin/main", in: path) ? "origin/main" : nil)
            ?? (refExists("origin/master", in: path) ? "origin/master" : nil)
        var ahead = 0
        var behind = 0
        if let upstream {
            // `rev-list --left-right --count <local>...<upstream>` returns
            // "<ahead>\t<behind>" in one call.
            let head = branch ?? "HEAD"
            if let out = runGit(
                ["rev-list", "--left-right", "--count", "\(head)...\(upstream)"],
                in: path
            ) {
                let parts = out.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2 {
                    ahead = Int(parts[0]) ?? 0
                    behind = Int(parts[1]) ?? 0
                }
            }
        }
        let dirty = (runGit(["status", "--porcelain"], in: path) ?? "")
            .isEmpty == false
        return WorktreeGitStats(
            branch: branch,
            upstream: upstream,
            ahead: ahead,
            behind: behind,
            hasUncommitted: dirty,
            lastCheckedAt: Date()
        )
    }

    private static func refExists(_ ref: String, in path: URL) -> Bool {
        runGit(["rev-parse", "--verify", "--quiet", ref], in: path) != nil
    }

    private static func runGit(_ args: [String], in cwd: URL) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.currentDirectoryURL = cwd
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe() // discard
        do {
            try task.run()
            task.waitUntilExit()
            guard task.terminationStatus == 0 else { return nil }
            let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
            let s = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty ?? true) ? nil : s
        } catch {
            return nil
        }
    }
}
