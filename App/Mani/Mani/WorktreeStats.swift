import Foundation
import SwiftUI

// Background git poller. Every 5 seconds it shells out to git in each
// project path and refreshes branch + ahead/behind counts against the
// remote tracking branch (or origin/main / origin/master as a fallback).
// Periodic background `git fetch` keeps the ahead/behind numbers honest;
// it runs at a slower cadence (~5 min) so we don't hammer the network.

struct WorktreeGitStats: Equatable {
    var branch: String?           // current branch name; nil when detached
    var defaultBranch: String?    // "origin/main" or "origin/master" or
                                  //  whatever origin/HEAD points to
    var ahead: Int                // local commits not in defaultBranch
    var behind: Int               // defaultBranch commits not in local
    var insertions: Int           // lines added vs defaultBranch
    var deletions: Int            // lines removed vs defaultBranch
    var hasUncommitted: Bool      // anything in `git status --porcelain`
    var hasConflicts: Bool        // unmerged paths from `ls-files -u`
                                  //  (mid-merge / mid-rebase / mid-cherry)
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
    private var task: _Concurrency.Task<Void, Never>?
    private var lastFetchAt: Date = .distantPast

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
            let projects = await collectWorktrees()
            let now = Date()
            let shouldFetch = now.timeIntervalSince(lastFetchAt) > Double(fetchTickSeconds)
            if shouldFetch { lastFetchAt = now }

            for (id, path) in projects {
                guard !_Concurrency.Task.isCancelled else { return }
                if shouldFetch {
                    _ = Self.runGit(["fetch", "--quiet", "--no-tags"], in: path)
                }
                let stats = Self.statsFor(path: path)
                await MainActor.run {
                    WorktreeStatsCache.shared.record(worktreeId: id, stats: stats)
                }
            }

            try? await _Concurrency.Task.sleep(nanoseconds: localTickSeconds * 1_000_000_000)
        }
    }

    @MainActor
    private func collectWorktrees() async -> [(UUID, URL)] {
        guard let store else { return [] }
        var result: [(UUID, URL)] = []
        for repo in store.state.repos {
            for project in repo.projects {
                result.append((project.id, project.workspace.path))
            }
        }
        return result
    }

    // MARK: Static git helpers

    private static func statsFor(path: URL) -> WorktreeGitStats {
        let branch = runGit(["symbolic-ref", "--short", "HEAD"], in: path)
        let defaultBranch = resolveDefaultBranch(in: path)
        var ahead = 0
        var behind = 0
        var insertions = 0
        var deletions = 0
        if let defaultBranch {
            // ahead/behind vs default branch — the user-facing
            // "how far am I from baseline" question, not the
            // upstream-tracking "have I pushed everything"
            // question (which a separate poller could surface
            // later if needed).
            let head = branch ?? "HEAD"
            if let out = runGit(
                ["rev-list", "--left-right", "--count", "\(head)...\(defaultBranch)"],
                in: path
            ) {
                let parts = out.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2 {
                    ahead = Int(parts[0]) ?? 0
                    behind = Int(parts[1]) ?? 0
                }
            }
            // Line-count diff vs default branch. `--shortstat`
            // gives one line: " N files changed, X insertions(+), Y deletions(-)".
            // Either insertions or deletions may be absent when
            // the diff is one-sided.
            if let stat = runGit(
                ["diff", "--shortstat", "\(defaultBranch)...HEAD"],
                in: path
            ) {
                (insertions, deletions) = parseShortstat(stat)
            }
        }
        let dirty = (runGit(["status", "--porcelain"], in: path) ?? "")
            .isEmpty == false
        // Unmerged paths only exist during an in-progress merge /
        // rebase / cherry-pick where git has flagged conflicts.
        // Non-empty `ls-files -u` is the cleanest one-shot signal.
        let conflicts = (runGit(["ls-files", "-u"], in: path) ?? "")
            .isEmpty == false
        return WorktreeGitStats(
            branch: branch,
            defaultBranch: defaultBranch,
            ahead: ahead,
            behind: behind,
            insertions: insertions,
            deletions: deletions,
            hasUncommitted: dirty,
            hasConflicts: conflicts,
            lastCheckedAt: Date()
        )
    }

    // Prefer origin's symbolic HEAD (whatever the upstream
    // considers "default" — typically main or master, sometimes
    // trunk / develop). Falls back to checking origin/main then
    // origin/master so cloned-without-HEAD-symref repos still work.
    private static func resolveDefaultBranch(in path: URL) -> String? {
        if let head = runGit(
            ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"],
            in: path
        ) {
            return head
        }
        if refExists("origin/main", in: path)   { return "origin/main" }
        if refExists("origin/master", in: path) { return "origin/master" }
        return nil
    }

    // Parse `git diff --shortstat` output:
    //   " 5 files changed, 412 insertions(+), 28 deletions(-)"
    //   " 1 file changed, 1 insertion(+)"
    //   " 1 file changed, 1 deletion(-)"
    private static func parseShortstat(_ s: String) -> (Int, Int) {
        var ins = 0
        var del = 0
        for piece in s.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if let n = leadingInt(trimmed) {
                if trimmed.contains("insertion") { ins = n }
                else if trimmed.contains("deletion") { del = n }
            }
        }
        return (ins, del)
    }

    private static func leadingInt(_ s: String) -> Int? {
        let digits = s.prefix(while: { $0.isNumber })
        return Int(digits)
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
