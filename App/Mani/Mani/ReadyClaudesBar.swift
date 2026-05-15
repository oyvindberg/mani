import SwiftUI
import ManiCore

// Top-of-window strip that surfaces every Claude session currently
// awaiting user attention. The intended flow is: glance up → see a
// row of repo-colored pills → click the freshest one → respond →
// repeat.
//
// Layout (left → right):
//   [thinking dot · N]   [ pill ][ pill ][ pill ]   [ N ready ]
//
// `thinking dot · N`     small pulsing repo-neutral indicator
//                         with the count of sessions that have
//                         streamed bytes in the last 1.5 s.
// pills                   one per ready claude, sorted newest-first.
//                         Fill is the originating repo color so
//                         the user pattern-matches identity without
//                         reading text.
// `N ready`               compact counter; tooltip lists all ready
//                         pills as text fallback when the strip is
//                         narrowed by the window resizing.
struct ReadyClaudesBar: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var activityTracker: TaskActivityTracker
    let onSelect: (UUID) -> Void

    var body: some View {
        HStack(spacing: 10) {
            thinkingIndicator
            pillRow
            readyCounter
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }

    // Aggregate signals across the whole AppState. Recomputed on
    // every body invocation; cheap (O(repos × worktrees × tasks))
    // and SwiftUI only invokes body when its observed sources change.
    private var readyEntries: [ReadyEntry] {
        var out: [ReadyEntry] = []
        for repo in store.state.repos {
            for worktree in repo.worktrees {
                for task in worktree.tasks {
                    guard case let .claude(sid) = task.kind, let sid else { continue }
                    if activityTracker.isThinking(sid: sid) { continue }
                    guard task.unread > 0 else { continue }
                    out.append(ReadyEntry(
                        repo: repo,
                        worktree: worktree,
                        task: task,
                        sessionId: sid,
                        settledAt: activityTracker.settledAt[sid],
                        isJustReady: activityTracker.justBecameReady(sid: sid)
                    ))
                }
            }
        }
        // Newest "settled" first; falls back to task createdAt so
        // stable ordering before any tracking-recorded transition.
        out.sort { lhs, rhs in
            (lhs.settledAt ?? lhs.task.createdAt)
                > (rhs.settledAt ?? rhs.task.createdAt)
        }
        return out
    }

    private var thinkingCount: Int {
        var n = 0
        for repo in store.state.repos {
            for worktree in repo.worktrees {
                for task in worktree.tasks {
                    guard case let .claude(sid) = task.kind, let sid else { continue }
                    if activityTracker.isThinking(sid: sid) { n += 1 }
                }
            }
        }
        return n
    }

    @ViewBuilder
    private var thinkingIndicator: some View {
        if thinkingCount > 0 {
            HStack(spacing: 5) {
                PulsingDot(color: .secondary, size: 7)
                Text("\(thinkingCount)")
                    .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .help("\(thinkingCount) Claude\(thinkingCount == 1 ? "" : "s") thinking")
        }
    }

    @ViewBuilder
    private var pillRow: some View {
        let entries = readyEntries
        if !entries.isEmpty {
            HStack(spacing: 4) {
                ForEach(Array(entries.prefix(9).enumerated()), id: \.element.task.id) { _, entry in
                    ReadyPill(entry: entry, onSelect: onSelect)
                }
                if entries.count > 9 {
                    Text("+\(entries.count - 9)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }
        }
    }

    @ViewBuilder
    private var readyCounter: some View {
        let entries = readyEntries
        if !entries.isEmpty {
            let tip = entries
                .map { "\($0.repo.name) › \($0.worktree.displayName) › \($0.task.name)" }
                .joined(separator: "\n")
            HStack(spacing: 3) {
                Image(systemName: "bell.badge.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                Text("\(entries.count) ready")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
            }
            .help(tip)
        }
    }
}

// One row in the ReadyClaudesBar. Kept out-of-line so the view is
// composable: ReadyPill stays a pure renderer with no env deps.
struct ReadyEntry {
    let repo: Repo
    let worktree: Worktree
    let task: Task
    let sessionId: String
    let settledAt: Date?
    let isJustReady: Bool
}

// Capsule rendered in the originating repo color. Pulses briefly
// when this session has just become ready (so the user can spot the
// transition out of the corner of their eye), then settles into a
// steady fill.
private struct ReadyPill: View {
    let entry: ReadyEntry
    let onSelect: (UUID) -> Void

    @State private var hovered = false
    @State private var animatePulse = false

    var body: some View {
        let baseColor = SwiftUI.Color(hex: entry.repo.color)
        Button(action: { onSelect(entry.task.id) }) {
            Capsule()
                .fill(baseColor)
                .overlay(
                    Capsule()
                        .stroke(SwiftUI.Color.white.opacity(0.35), lineWidth: 0.5)
                )
                .frame(width: 32, height: 13)
                .scaleEffect(animatePulse ? 1.15 : 1.0)
                .shadow(
                    color: baseColor.opacity(animatePulse ? 0.6 : 0.0),
                    radius: animatePulse ? 6 : 0
                )
                .overlay(
                    // Hover ring to reinforce that it's clickable.
                    Capsule()
                        .stroke(SwiftUI.Color.white.opacity(0.85), lineWidth: hovered ? 1.0 : 0)
                )
                .animation(
                    .easeInOut(duration: 0.9).repeatForever(autoreverses: true),
                    value: animatePulse
                )
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .onAppear { animatePulse = entry.isJustReady }
        .onChange(of: entry.isJustReady) { _, newValue in
            animatePulse = newValue
        }
        .help("\(entry.repo.name) › \(entry.worktree.displayName) › \(entry.task.name)")
    }
}

// Small reusable pulsing dot. Used in the thinking-count indicator.
struct PulsingDot: View {
    let color: SwiftUI.Color
    let size: CGFloat
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .opacity(pulse ? 1.0 : 0.35)
            .animation(
                .easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                value: pulse
            )
            .onAppear { pulse = true }
    }
}
