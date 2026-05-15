import SwiftUI
import ManiCore

// Visual components shared by the new sidebar hierarchy. Three levels:
//   ProjectHeaderRow → WorktreeHeaderRow → TaskRow
// Each is collapsible at its parent level (the parent owns the
// expansion state). A continuous project-color stripe runs along the
// left edge of every row inside a project so the hierarchy reads as
// "this all belongs to atlas" even when worktrees are collapsed away.

// MARK: - Task kind icon

// Rounded-rect badge with the per-kind glyph + tint. Sized to read as
// an icon in a sidebar row (24x24). Mirrors the sizing conventions of
// Xcode and VS Code's source-control sidebars.
struct TaskKindIcon: View {
    let kind: TaskKind
    let size: CGFloat

    init(kind: TaskKind) {
        self.kind = kind
        self.size = 22
    }

    init(kind: TaskKind, size: CGFloat) {
        self.kind = kind
        self.size = size
    }

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
    let taskCount: Int
    let anyChildThinking: Bool
    let anyChildReady: Bool
    let anyChildJustReady: Bool
    let onToggle: () -> Void
    let onContextMenu: () -> AnyView

    @State private var hovered = false

    var body: some View {
        let color = SwiftUI.Color(hex: project.color)
        HStack(spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color.opacity(0.7))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            Text(project.name)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(project.enabled ? color : color.opacity(0.55))
                .strikethrough(!project.enabled)
            Spacer()
            if taskCount > 0 {
                Text("\(taskCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0)
                    .background(
                        Capsule().fill(color.opacity(0.18))
                    )
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 5)
        .background(
            ZStack {
                if hovered { color.opacity(0.10) }
                // .subtle so the per-task pulse remains the strongest
                // signal — the project row is more of an aggregate
                // breathing.
                ActivityOverlay(
                    projectColor: color,
                    isThinking: anyChildThinking,
                    isReady: anyChildReady,
                    isJustReady: anyChildJustReady,
                    intensity: .subtle
                )
            }
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
    let anyChildThinking: Bool
    let anyChildReady: Bool
    let anyChildJustReady: Bool
    let onToggle: () -> Void
    let onSelectDiff: () -> Void
    let onNewShell: () -> Void
    let onNewClaude: () -> Void
    let onContextMenu: () -> AnyView

    @ObservedObject private var statsCache = WorktreeStatsCache.shared
    @State private var headerHovered = false

    private var displayName: String {
        worktree.displayName
    }

    private var gitStats: WorktreeGitStats? {
        statsCache.stats[worktree.id]
    }

    var body: some View {
        singleLine
        .padding(.leading, 8)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .background(
            ZStack {
                if headerHovered {
                    SwiftUI.Color.secondary.opacity(0.08)
                }
                // Dimmer overlay than per-task: this is the aggregate
                // signal across all child claudes in the worktree, so
                // we don't want it to overpower the per-task pulses
                // nested inside.
                ActivityOverlay(
                    projectColor: SwiftUI.Color(hex: project.color),
                    isThinking: anyChildThinking,
                    isReady: anyChildReady,
                    isJustReady: anyChildJustReady,
                    intensity: .subtle
                )
            }
        )
        .contentShape(Rectangle())
        .onHover { headerHovered = $0 }
        .onTapGesture(perform: onToggle)
        .contextMenu { onContextMenu() }
    }

    private var singleLine: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Image(systemName: worktreeIcon)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(displayName)
                .font(.system(.subheadline, design: .default).weight(.semibold))
                .opacity(worktree.enabled ? 1 : 0.5)
                .lineLimit(1)
                .truncationMode(.middle)
            if worktree.path == project.rootDir {
                Image(systemName: "star.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .help("Project root — `git worktree add` anchors here")
            }
            if worktree.missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Path no longer exists")
            }
            gitBadges
            Spacer(minLength: 4)
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

// MARK: - Task row

struct TaskRow: View {
    let project: Project
    let task: Task
    let selected: Bool
    let onTap: () -> Void
    let onContextMenu: () -> AnyView

    @ObservedObject private var statsCache = TaskStatsCache.shared
    @ObservedObject private var externalInfo = ExternalSessionInfoCache.shared
    @EnvironmentObject private var activity: TaskActivityTracker
    @State private var hovered = false

    private var sessionId: String? {
        if case let .claude(sid) = task.kind { return sid }
        return nil
    }

    private var isThinking: Bool { activity.isThinking(sid: sessionId) }
    private var isReady: Bool {
        guard !isThinking else { return false }
        return task.unread > 0
    }
    private var isJustReady: Bool {
        guard isReady else { return false }
        return activity.justBecameReady(sid: sessionId)
    }

    var body: some View {
        HStack(spacing: 8) {
            TaskKindIcon(kind: task.kind, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(task.name)
                    .font(.system(.callout, design: .default))
                    .strikethrough(!task.enabled)
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
            Image(systemName: task.statusSymbol)
                .font(.system(size: 7))
                .foregroundStyle(task.statusColor)
            if task.unread > 0 {
                Text("\(task.unread)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 0)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(.tint))
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 10)
        .opacity(task.enabled ? 1 : 0.55)
        .padding(.vertical, 2)
        .background(
            ZStack {
                if selected {
                    SwiftUI.Color.accentColor.opacity(0.18)
                } else if hovered {
                    SwiftUI.Color.secondary.opacity(0.10)
                }
                ActivityOverlay(
                    projectColor: SwiftUI.Color(hex: project.color),
                    isThinking: isThinking,
                    isReady: isReady,
                    isJustReady: isJustReady
                )
            }
        )
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: onTap)
        .contextMenu { onContextMenu() }
    }

    // Subtitle: for claude tasks, "N msgs · 1.2 MB" (data from the
    // TaskStatsCache / ExternalSessionInfoCache pollers). For shell
    // tasks there's no subtitle.
    private var subtitle: String? {
        guard case let .claude(sid) = task.kind, let sid else { return nil }
        var parts: [String] = []
        if let msg = externalInfo.entries[sid]?.messageCount {
            parts.append("\(msg) msg\(msg == 1 ? "" : "s")")
        }
        if let bytes = statsCache.stats[task.id]?.transcriptBytes, bytes > 0 {
            parts.append(TaskStatsFormatter.size(bytes: bytes))
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
// underlying Task so the user can adopt / delete from the right pane.
struct PastSessionRow: View {
    let project: Project
    let task: Task
    let selected: Bool
    let onTap: () -> Void
    let onContextMenu: () -> AnyView

    @ObservedObject private var infoCache = ExternalSessionInfoCache.shared
    @State private var hovered = false

    private var sessionId: String? {
        if case let .claude(sid) = task.kind { return sid }
        return nil
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.7))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
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
        .padding(.leading, 32)
        .padding(.trailing, 10)
        .opacity(task.enabled ? 1 : 0.55)
        .padding(.vertical, 2)
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

// MARK: - Pulse / ready overlay

// Project-color overlay reused by both TaskRow and WorktreeHeaderRow.
// Three render modes:
//   - thinking: opacity oscillates with a slow easeInOut, drawing the
//     eye to "claude is working" — the row "breathes".
//   - just-ready: bright steady highlight for ~3 s after claude
//     finished its turn, so the user spots the transition.
//   - ready (past the just-ready window): steady but dim highlight,
//     keeps the row visually claimed.
//
// `intensity` controls absolute opacity caps. .normal for per-task
// rows; .subtle for the parent worktree (aggregate) row, so the
// nested per-task pulse stays the primary signal.
struct ActivityOverlay: View {
    let projectColor: SwiftUI.Color
    let isThinking: Bool
    let isReady: Bool
    let isJustReady: Bool
    let intensity: Intensity

    enum Intensity {
        case normal
        case subtle
    }

    init(
        projectColor: SwiftUI.Color,
        isThinking: Bool,
        isReady: Bool,
        isJustReady: Bool,
        intensity: Intensity
    ) {
        self.projectColor = projectColor
        self.isThinking = isThinking
        self.isReady = isReady
        self.isJustReady = isJustReady
        self.intensity = intensity
    }

    // Two-arg convenience used by TaskRow (which doesn't need to
    // override intensity). The "no default parameters" rule still
    // holds — this is a separate initializer, not a defaulted arg.
    init(
        projectColor: SwiftUI.Color,
        isThinking: Bool,
        isReady: Bool,
        isJustReady: Bool
    ) {
        self.init(
            projectColor: projectColor,
            isThinking: isThinking,
            isReady: isReady,
            isJustReady: isJustReady,
            intensity: .normal
        )
    }

    @State private var pulsePhase = false

    private var maxThinkingOpacity: Double {
        switch intensity {
        case .normal: return 0.22
        case .subtle: return 0.12
        }
    }
    private var minThinkingOpacity: Double {
        switch intensity {
        case .normal: return 0.04
        case .subtle: return 0.02
        }
    }
    private var justReadyOpacity: Double {
        switch intensity {
        case .normal: return 0.28
        case .subtle: return 0.16
        }
    }
    private var readyOpacity: Double {
        switch intensity {
        case .normal: return 0.10
        case .subtle: return 0.05
        }
    }

    var body: some View {
        Group {
            if isThinking {
                projectColor
                    .opacity(pulsePhase ? maxThinkingOpacity : minThinkingOpacity)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: pulsePhase
                    )
                    .onAppear { pulsePhase = true }
            } else if isReady {
                projectColor
                    .opacity(isJustReady ? justReadyOpacity : readyOpacity)
                    .animation(.easeOut(duration: 1.5), value: isJustReady)
            }
        }
        .allowsHitTesting(false)
    }
}

// Row for a safekept session whose originating worktree is no longer
// in the project's live worktrees. Doesn't render off a Task because
// these don't have one — they live only in the SessionArchiveCache.
// Click does nothing yet (a future "Adopt as worktree" / "Resume in
// new worktree" action would dispatch through Store).
struct ArchivedSessionRow: View {
    let project: Project
    let entry: SessionIndexEntry

    @State private var hovered = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10))
                .foregroundStyle(.orange.opacity(0.55))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    if let when = entry.lastMessageAt {
                        Text(Self.relativeFormatter.localizedString(
                            for: when, relativeTo: Date()
                        ))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    } else {
                        Text("session \(entry.sessionId.prefix(8))")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                    }
                    if entry.messageCount > 0 {
                        Text("\(entry.messageCount) msg\(entry.messageCount == 1 ? "" : "s")")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if entry.archivedAt != nil {
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                if let preview = entry.firstUserMessage, !preview.isEmpty {
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
        .padding(.leading, 40)
        .padding(.trailing, 10)
        .opacity(0.85)
        .padding(.vertical, 2)
        .background(hovered ? SwiftUI.Color.secondary.opacity(0.08) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}
