import SwiftUI

// Compact git-status indicator for the sidebar project header.
//
// Always-visible (when stats are loaded). Three modes:
//   .nothing      — clean, no diff, no ahead/behind. Renders empty.
//   .conflicts    — mid-merge / mid-rebase with conflicts. Renders
//                   a single red marker; the rest is suppressed
//                   because conflicts are urgent and the diff
//                   numbers can mislead while they're unresolved.
//   .diff         — anything else with content: a tiny green/red
//                   proportion bar, mono +N -M, and ↑N when ahead.
//
// All numbers are vs origin's default branch (origin/main or
// origin/master, whichever the upstream's symbolic HEAD points at).
// Updated by WorktreeStatsPoller every 5 s; the background `git
// fetch` runs every 5 min so the behind count stays honest.

struct GitStatusBar: View {
    let stats: WorktreeGitStats?

    var body: some View {
        if let stats {
            content(stats)
        }
    }

    @ViewBuilder
    private func content(_ stats: WorktreeGitStats) -> some View {
        if stats.hasConflicts {
            conflictMarker
        } else if hasAnythingToShow(stats) {
            normalRow(stats)
        }
    }

    private var conflictMarker: some View {
        HStack(spacing: 4) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 9))
                .foregroundStyle(.red)
            Text("conflicts")
                .font(.system(size: 10, design: .monospaced).weight(.medium))
                .foregroundStyle(.red.opacity(0.95))
        }
        .help("Unresolved conflicts in this workspace")
    }

    // Sidebar-tight summary: bar + ahead count only. Behind count,
    // numeric +N/−N, and the branch name all live in the hover
    // tooltip and the masthead WorkspaceInfoBar. The sidebar row is
    // a glance surface, not a dashboard.
    private func normalRow(_ stats: WorktreeGitStats) -> some View {
        HStack(spacing: 6) {
            if stats.insertions > 0 || stats.deletions > 0 {
                ProportionBar(
                    insertions: stats.insertions,
                    deletions: stats.deletions
                )
                .frame(width: 28, height: 4)
            }
            if stats.ahead > 0 {
                Text("↑\(stats.ahead)")
                    .font(.system(size: 10, design: .monospaced).weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .help(Self.summary(stats: stats))
    }

    private static func summary(stats: WorktreeGitStats) -> String {
        var lines: [String] = []
        if let b = stats.branch {
            if let d = stats.defaultBranch {
                lines.append("\(b)  vs  \(d)")
            } else {
                lines.append(b)
            }
        }
        if stats.insertions > 0 || stats.deletions > 0 {
            lines.append("+\(stats.insertions)  −\(stats.deletions) lines")
        }
        if stats.ahead > 0 {
            lines.append("↑ \(stats.ahead) commit\(stats.ahead == 1 ? "" : "s") ahead")
        }
        if stats.behind > 0 {
            lines.append("↓ \(stats.behind) commit\(stats.behind == 1 ? "" : "s") behind")
        }
        if stats.hasUncommitted {
            lines.append("uncommitted changes")
        }
        if lines.isEmpty {
            return "in sync with \(stats.defaultBranch ?? "default branch")"
        }
        return lines.joined(separator: "\n")
    }

    private func hasAnythingToShow(_ stats: WorktreeGitStats) -> Bool {
        stats.insertions > 0
            || stats.deletions > 0
            || stats.ahead > 0
            || stats.behind > 0
    }
}

// Two-segment proportion bar — green for insertions, red for
// deletions. Proportional to the relative sizes, with a minimum
// segment width so a vastly-asymmetric diff (e.g. +400 / −1) still
// shows a visible red tip.
private struct ProportionBar: View {
    let insertions: Int
    let deletions: Int

    var body: some View {
        GeometryReader { geo in
            let widths = segmentWidths(in: geo.size.width)
            HStack(spacing: 1) {
                Rectangle()
                    .fill(SwiftUI.Color.green.opacity(0.75))
                    .frame(width: widths.green)
                Rectangle()
                    .fill(SwiftUI.Color.red.opacity(0.75))
                    .frame(width: widths.red)
            }
            .clipShape(Capsule())
        }
    }

    private func segmentWidths(in total: CGFloat) -> (green: CGFloat, red: CGFloat) {
        if insertions == 0 && deletions == 0 {
            return (0, 0)
        }
        if insertions == 0 { return (0, total) }
        if deletions == 0  { return (total, 0) }
        let sum = max(1, insertions + deletions)
        let rawGreen = CGFloat(insertions) / CGFloat(sum) * total
        let rawRed   = total - rawGreen
        let minSegment: CGFloat = 2
        return (max(minSegment, rawGreen), max(minSegment, rawRed))
    }
}

#if DEBUG
#Preview("Variations") {
    VStack(alignment: .leading, spacing: 12) {
        GitStatusBar(stats: WorktreeGitStats(
            branch: "feat/auth",
            defaultBranch: "origin/main",
            ahead: 11,
            behind: 3,
            insertions: 412,
            deletions: 28,
            hasUncommitted: false,
            hasConflicts: false,
            lastCheckedAt: Date()
        ))
        GitStatusBar(stats: WorktreeGitStats(
            branch: "feat/auth",
            defaultBranch: "origin/main",
            ahead: 0,
            behind: 0,
            insertions: 0,
            deletions: 0,
            hasUncommitted: false,
            hasConflicts: true,
            lastCheckedAt: Date()
        ))
        GitStatusBar(stats: WorktreeGitStats(
            branch: "main",
            defaultBranch: "origin/main",
            ahead: 0,
            behind: 12,
            insertions: 0,
            deletions: 0,
            hasUncommitted: false,
            hasConflicts: false,
            lastCheckedAt: Date()
        ))
        GitStatusBar(stats: nil)
    }
    .padding(20)
    .background(SwiftUI.Color(white: 0.08))
    .preferredColorScheme(.dark)
}
#endif
