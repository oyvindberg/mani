import SwiftUI
import ManiCore

// Visual components shared by the new sidebar hierarchy. Three levels:
//   ProjectHeaderRow → WorktreeHeaderRow → JobRow
// Each is collapsible at its parent level (the parent owns the
// expansion state). A continuous project-color stripe runs along the
// left edge of every row inside a project so the hierarchy reads as
// "this all belongs to atlas" even when worktrees are collapsed away.

// MARK: - Job kind icon

// Rounded-rect badge with the per-kind glyph + tint. Sized to read as
// an icon in a sidebar row (24x24). Mirrors the sizing conventions of
// Xcode and VS Code's source-control sidebars.
struct JobKindIcon: View {
    let kind: JobKind
    var size: CGFloat = 22

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(tint.opacity(0.18))
            Image(systemName: symbol)
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(tint)
        }
        .frame(width: size, height: size)
    }

    private var symbol: String {
        switch kind {
        case .shell: return "terminal.fill"
        case .claude: return "sparkles"
        case .diff: return "arrow.left.arrow.right"
        case .custom: return "puzzlepiece.extension.fill"
        }
    }

    private var tint: SwiftUI.Color {
        switch kind {
        case .shell: return .blue
        case .claude: return .orange
        case .diff: return .purple
        case .custom: return .gray
        }
    }
}

// MARK: - Project header

struct ProjectHeaderRow: View {
    let project: Project
    let isExpanded: Bool
    let jobCount: Int
    let onToggle: () -> Void
    let onContextMenu: () -> AnyView

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Circle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 12, height: 12)
                .overlay(
                    Circle().strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
                )
            Text(project.name)
                .font(.headline)
                .foregroundStyle(project.enabled ? .primary : .secondary)
                .strikethrough(!project.enabled)
            Spacer()
            if jobCount > 0 {
                Text("\(jobCount)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(SwiftUI.Color.secondary.opacity(0.12))
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            hovered ? SwiftUI.Color.secondary.opacity(0.10) : .clear
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu { onContextMenu() }
    }
}

// MARK: - Worktree header

struct WorktreeHeaderRow: View {
    let project: Project
    let worktree: Worktree
    let isExpanded: Bool
    let diffJobId: UUID?
    let selectedJobId: UUID?
    let onToggle: () -> Void
    let onSelectDiff: () -> Void
    let onNewShell: () -> Void
    let onNewClaude: () -> Void
    let onContextMenu: () -> AnyView

    @ObservedObject private var statsCache = WorktreeStatsCache.shared
    @State private var headerHovered = false

    private var dirSuffix: String {
        // The path's last component. If the user's worktree.name already
        // matches it we don't show it again on the second line.
        URL(fileURLWithPath: worktree.path.path).lastPathComponent
    }

    private var gitStats: WorktreeGitStats? {
        statsCache.stats[worktree.id]
    }

    var body: some View {
        HStack(spacing: 0) {
            // Project color stripe — full height of the row, anchored
            // left so it lines up with the rows below for "everything
            // under atlas is the same atlas" continuity.
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                topLine
                bottomLine
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .padding(.vertical, 6)
        }
        .background(
            headerHovered ? SwiftUI.Color.secondary.opacity(0.08) : .clear
        )
        .contentShape(Rectangle())
        .onHover { headerHovered = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu { onContextMenu() }
    }

    private var topLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: worktreeIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(worktree.name)
                .font(.system(.subheadline, design: .default).weight(.semibold))
                .opacity(worktree.enabled ? 1 : 0.5)
            if worktree.primary {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .help("Primary worktree — `git worktree add` runs from here")
            }
            if worktree.missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Path no longer exists")
            }
            Spacer()
            gitBadges
        }
    }

    @ViewBuilder
    private var gitBadges: some View {
        if let stats = gitStats {
            if let branch = stats.branch {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(branch)
                        .font(.caption2.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(SwiftUI.Color.secondary.opacity(0.10))
                )
                .help("Current branch")
            }
            if stats.ahead > 0 {
                Text("↑\(stats.ahead)")
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.green)
                    .help("Commits ahead of \(stats.upstream ?? "upstream")")
            }
            if stats.behind > 0 {
                Text("↓\(stats.behind)")
                    .font(.caption2.monospaced().weight(.medium))
                    .foregroundStyle(.orange)
                    .help("Commits behind \(stats.upstream ?? "upstream")")
            }
            if stats.hasUncommitted {
                Image(systemName: "pencil.tip")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow)
                    .help("Uncommitted changes")
            }
        }
    }

    private var bottomLine: some View {
        HStack(spacing: 6) {
            // Indent to align under the chevron + folder glyph.
            Spacer().frame(width: 22)
            if dirSuffix != worktree.name {
                Text(dirSuffix)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer()
            actionButton(systemImage: "terminal", help: "New shell here", action: onNewShell)
            actionButton(systemImage: "sparkles", help: "New Claude task", action: onNewClaude)
            if let diffJobId {
                actionButton(
                    systemImage: "arrow.left.arrow.right",
                    help: "Diff workspace",
                    tint: selectedJobId == diffJobId ? .accentColor : .secondary,
                    action: onSelectDiff
                )
            }
        }
    }

    private func actionButton(
        systemImage: String,
        help: String,
        tint: SwiftUI.Color = .secondary,
        action: @escaping () -> Void
    ) -> some View {
        SidebarActionButton(
            systemImage: systemImage, help: help, tint: tint, action: action
        )
    }

    private var worktreeIcon: String {
        switch worktree.kind {
        case .git: return "arrow.triangle.branch"
        case .folder: return "folder.fill"
        }
    }
}

// MARK: - Job row

struct JobRow: View {
    let project: Project
    let job: Job
    let selected: Bool
    let onTap: () -> Void
    let onContextMenu: () -> AnyView

    @ObservedObject private var statsCache = JobStatsCache.shared
    @ObservedObject private var externalInfo = ExternalSessionInfoCache.shared
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
            HStack(spacing: 8) {
                JobKindIcon(kind: job.kind)
                VStack(alignment: .leading, spacing: 1) {
                    Text(job.name)
                        .font(.system(.body, design: .default))
                        .strikethrough(!job.enabled)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Spacer()
                Image(systemName: job.statusSymbol)
                    .font(.system(size: 8))
                    .foregroundStyle(job.statusColor)
                if job.unread > 0 {
                    Text("\(job.unread)")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .foregroundStyle(.white)
                        .background(Capsule().fill(.tint))
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .opacity(job.enabled ? 1 : 0.55)
        }
        .padding(.vertical, 4)
        .background(
            selected
                ? SwiftUI.Color.accentColor.opacity(0.18)
                : (hovered ? SwiftUI.Color.secondary.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { onContextMenu() }
    }

    // Subtitle: for claude jobs, "N msgs · 1.2 MB" (data from the
    // JobStatsCache / ExternalSessionInfoCache pollers). For shell
    // jobs there's no subtitle.
    private var subtitle: String? {
        guard case let .claude(sid) = job.kind, let sid else { return nil }
        var parts: [String] = []
        if let msg = externalInfo.entries[sid]?.messageCount {
            parts.append("\(msg) msg\(msg == 1 ? "" : "s")")
        }
        if let bytes = statsCache.stats[job.id]?.transcriptBytes, bytes > 0 {
            parts.append(JobStatsFormatter.size(bytes: bytes))
        }
        if parts.isEmpty {
            return "session " + String(sid.prefix(8))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Reusable action button

// Small icon button used in the worktree header's bottom row. Designed
// to be visibly different from informational badges: stronger hover
// state, accentColor pulse on press, and a hand-pointer cursor while
// hovered so the affordance is obvious.
struct SidebarActionButton: View {
    let systemImage: String
    let help: String
    let tint: SwiftUI.Color
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(hovered ? .white : tint)
                .frame(width: 24, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(hovered
                            ? SwiftUI.Color.accentColor.opacity(0.85)
                            : SwiftUI.Color.secondary.opacity(0.14))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { isOver in
            hovered = isOver
            if isOver { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

// MARK: - Past session row

// Compact row for an EXTERNAL claude session (a transcript Mani didn't
// spawn). Renders relative date + msg count on a top line and a
// truncated first-user-message preview underneath. Tap selects the
// underlying Job so the user can adopt / delete from the right pane.
struct PastSessionRow: View {
    let project: Project
    let job: Job
    let selected: Bool
    let onTap: () -> Void
    let onContextMenu: () -> AnyView

    @ObservedObject private var infoCache = ExternalSessionInfoCache.shared
    @State private var hovered = false

    private var sessionId: String? {
        if case let .claude(sid) = job.kind { return sid }
        return nil
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange.opacity(0.7))
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        if let when = info?.lastMessageAt {
                            Text(Self.relativeFormatter.localizedString(
                                for: when, relativeTo: Date()
                            ))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        } else {
                            Text("session \((sessionId ?? "").prefix(8))")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                        }
                        if let count = info?.messageCount, count > 0 {
                            Text("\(count) msg\(count == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                    }
                    if let preview = info?.firstUserMessage, !preview.isEmpty {
                        Text(preview)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else {
                        Text("(no user message)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                }
            }
            .padding(.leading, 22)
            .padding(.trailing, 10)
            .opacity(job.enabled ? 1 : 0.55)
        }
        .padding(.vertical, 3)
        .background(
            selected
                ? SwiftUI.Color.accentColor.opacity(0.18)
                : (hovered ? SwiftUI.Color.secondary.opacity(0.10) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { onContextMenu() }
    }

    private var info: ExternalSessionInfoCache.Info? {
        sessionId.flatMap { infoCache.entries[$0] }
    }
}
