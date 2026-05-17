import SwiftUI
import ManiCore

// Visual components shared by the new sidebar hierarchy. Three levels:
//   RepoHeaderRow → WorktreeHeaderRow → TaskRow
// Each is collapsible at its parent level (the parent owns the
// expansion state). A continuous repo-color stripe runs along the
// left edge of every row inside a repo so the hierarchy reads as
// "this all belongs to atlas" even when projects are collapsed away.

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

// MARK: - Repo header

struct RepoHeaderRow: View {
    let repo: Repo
    let isExpanded: Bool
    let taskCount: Int
    let anyChildThinking: Bool
    let anyChildReady: Bool
    let anyChildJustReady: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onContextMenu: () -> AnyView

    @State private var hovered = false

    var body: some View {
        let color = SwiftUI.Color(hex: repo.color)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(color.opacity(0.7))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 12)
            // New York serif for repo names — the editorial display
            // face that ships with macOS but nobody uses. Distinctive
            // vs every other SwiftUI app's SF Pro.
            Text(repo.name)
                .font(.system(.title3, design: .serif).weight(.bold))
                .tracking(-0.3)
                .foregroundStyle(repo.enabled ? color : color.opacity(0.55))
                .strikethrough(!repo.enabled)
            Spacer()
            if taskCount > 0 {
                Text("\(taskCount)")
                    .font(.system(size: 11, design: .monospaced).weight(.medium))
                    .foregroundStyle(color.opacity(0.9))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(color.opacity(0.15))
                    )
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
        .background(
            ZStack {
                if hovered { SwiftUI.Color.secondary.opacity(0.06) }
                // .subtle so the per-task pulse remains the strongest
                // signal — the repo row is more of an aggregate
                // breathing.
                ActivityOverlay(
                    repoColor: color,
                    isThinking: anyChildThinking,
                    isReady: anyChildReady,
                    isJustReady: anyChildJustReady,
                    intensity: .subtle
                )
            }
        )
        // The repo-color spine. Persistent (not hover-gated) and runs
        // along the leading edge so the same stripe visually connects
        // every row in the repo — header, projects, tasks. The repo
        // identity becomes a continuous thread instead of scattered
        // tints.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(color)
                .frame(width: 2)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(count: 1, perform: onToggle)
        .contextMenu { onContextMenu() }
    }
}

// MARK: - Project header

struct WorktreeHeaderRow: View {
    let repo: Repo
    let project: Project
    let isExpanded: Bool
    let diffJobId: UUID?
    let selectedJobId: UUID?
    let anyChildThinking: Bool
    let anyChildReady: Bool
    let anyChildJustReady: Bool
    let onToggle: () -> Void
    let onRename: () -> Void
    let onSelectDiff: () -> Void
    let onNewShell: () -> Void
    let onNewClaude: () -> Void
    let onContextMenu: () -> AnyView

    @State private var headerHovered = false

    private var displayName: String {
        project.name
    }

    var body: some View {
        singleLine
        .padding(.leading, 12)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            ZStack {
                if headerHovered {
                    SwiftUI.Color.secondary.opacity(0.06)
                }
                // Dimmer overlay than per-task: this is the aggregate
                // signal across all child claudes in the project, so
                // we don't want it to overpower the per-task pulses
                // nested inside.
                ActivityOverlay(
                    repoColor: SwiftUI.Color(hex: repo.color),
                    isThinking: anyChildThinking,
                    isReady: anyChildReady,
                    isJustReady: anyChildJustReady,
                    intensity: .subtle
                )
            }
        )
        // Continuation of the repo-color spine through the project row.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(SwiftUI.Color(hex: repo.color))
                .frame(width: 2)
        }
        .contentShape(Rectangle())
        .onHover { headerHovered = $0 }
        // Double-click → rename. SwiftUI waits for the double-tap
        // window before firing the single-tap, so collapse/expand
        // still works correctly on a normal click.
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(count: 1, perform: onToggle)
        .contextMenu { onContextMenu() }
    }

    private var singleLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            // Project name in New York serif — the editorial display
            // face shared with the repo header above. Same face,
            // different weight: bold on repos, semibold on projects.
            // Hard-clip on overflow rather than ellipsis-truncate.
            // .fixedSize(.horizontal) makes the Text render at its
            // natural width with no `…`; the surrounding frame +
            // .clipped() crops what doesn't fit. Other HStack items
            // (pill, triangle, action buttons) keep their natural
            // positions on the right; the text just gets cut.
            Text(displayName)
                .font(.system(.body, design: .serif).weight(.semibold))
                .tracking(-0.2)
                .opacity((!project.isArchived) ? 1 : 0.5)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
            if project.workspace.missing {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .help("Path no longer exists")
            }
            Spacer(minLength: 4)
            // Action buttons are always laid out — only their opacity
            // and hit-testing flip on hover. Conditional rendering
            // caused the name/pill to shift when the buttons appeared
            // (the spacer had to give up width), which was jarring.
            HStack(spacing: 4) {
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
            .opacity(headerHovered ? 1 : 0)
            .allowsHitTesting(headerHovered)
            .animation(.easeOut(duration: 0.12), value: headerHovered)
            // Pill goes last so it sits at the row's right edge —
            // matching the repo-header pill above it. The action
            // buttons live to its left, opacity-gated on hover.
            if !isExpanded {
                let count = visibleTaskCount
                if count > 0 {
                    let tint = SwiftUI.Color(hex: repo.color)
                    Text("\(count)")
                        .font(.system(size: 10, design: .monospaced).weight(.semibold))
                        .foregroundStyle(tint.opacity(0.85))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(tint.opacity(0.13))
                        )
                        .help("\(count) task\(count == 1 ? "" : "s")")
                }
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

    // Tasks the user actually sees in the expanded view. Excludes
    // the diff fixture so the badge matches what the user will get
    // when they expand the project.
    private var visibleTaskCount: Int {
        project.tasks.reduce(0) { acc, task in
            if case .diff = task.kind { return acc }
            return acc + 1
        }
    }
}

// MARK: - Task row

struct TaskRow: View {
    let repo: Repo
    let task: Task
    let selected: Bool
    let onTap: () -> Void
    let onRename: () -> Void
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
                .overlay(alignment: .topTrailing) {
                    // Status dot anchored to icon corner — small,
                    // out-of-the-way, but visible. Replaces the
                    // mid-row floating dot that was easy to miss.
                    Circle()
                        .fill(task.statusColor)
                        .frame(width: 5, height: 5)
                        .overlay(Circle().strokeBorder(.background, lineWidth: 1))
                        .offset(x: 2, y: -2)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(task.name)
                    .font(.system(.callout, design: .default))
                    .strikethrough(!task.enabled)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            if task.unread > 0 {
                Text("\(task.unread)")
                    .font(.system(size: 10, design: .monospaced).weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .foregroundStyle(.white)
                    .background(Capsule().fill(.tint))
            }
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .opacity(task.enabled ? 1 : 0.55)
        .padding(.vertical, 4)
        .background(
            ZStack {
                if selected {
                    // Selection in repo color, not accent blue — the
                    // selected row "claims" the repo identity rather
                    // than overriding it with a system color.
                    SwiftUI.Color(hex: repo.color).opacity(0.16)
                } else if hovered {
                    SwiftUI.Color.secondary.opacity(0.08)
                }
                ActivityOverlay(
                    repoColor: SwiftUI.Color(hex: repo.color),
                    isThinking: isThinking,
                    isReady: isReady,
                    isJustReady: isJustReady
                )
            }
        )
        // The repo-color spine becomes a chunky "tab" for the selected
        // task — 4pt wide vs the standard 2pt on neighboring rows.
        // The spine swells where the user is looking, claiming the
        // edge of the panel.
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(SwiftUI.Color(hex: repo.color))
                .frame(width: selected ? 4 : 2)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // Double-click → rename. Single-click still selects the task.
        .onTapGesture(count: 2, perform: onRename)
        .onTapGesture(count: 1, perform: onTap)
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

// Small icon button used in the project header's bottom row. Designed
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
    let repo: Repo
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

// Repo-color overlay reused by both TaskRow and WorktreeHeaderRow.
// Three render modes:
//   - thinking: opacity oscillates with a slow easeInOut, drawing the
//     eye to "claude is working" — the row "breathes".
//   - just-ready: bright steady highlight for ~3 s after claude
//     finished its turn, so the user spots the transition.
//   - ready (past the just-ready window): steady but dim highlight,
//     keeps the row visually claimed.
//
// `intensity` controls absolute opacity caps. .normal for per-task
// rows; .subtle for the parent project (aggregate) row, so the
// nested per-task pulse stays the primary signal.
struct ActivityOverlay: View {
    let repoColor: SwiftUI.Color
    let isThinking: Bool
    let isReady: Bool
    let isJustReady: Bool
    let intensity: Intensity

    enum Intensity {
        case normal
        case subtle
    }

    init(
        repoColor: SwiftUI.Color,
        isThinking: Bool,
        isReady: Bool,
        isJustReady: Bool,
        intensity: Intensity
    ) {
        self.repoColor = repoColor
        self.isThinking = isThinking
        self.isReady = isReady
        self.isJustReady = isJustReady
        self.intensity = intensity
    }

    // Two-arg convenience used by TaskRow (which doesn't need to
    // override intensity). The "no default parameters" rule still
    // holds — this is a separate initializer, not a defaulted arg.
    init(
        repoColor: SwiftUI.Color,
        isThinking: Bool,
        isReady: Bool,
        isJustReady: Bool
    ) {
        self.init(
            repoColor: repoColor,
            isThinking: isThinking,
            isReady: isReady,
            isJustReady: isJustReady,
            intensity: .normal
        )
    }

    @State private var pulsePhase = false

    private var maxThinkingOpacity: Double {
        switch intensity {
        case .normal: return 0.18
        case .subtle: return 0.10
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
        case .normal: return 0.22
        case .subtle: return 0.13
        }
    }
    private var readyOpacity: Double {
        switch intensity {
        case .normal: return 0.08
        case .subtle: return 0.04
        }
    }

    var body: some View {
        Group {
            if isThinking {
                repoColor
                    .opacity(pulsePhase ? maxThinkingOpacity : minThinkingOpacity)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: pulsePhase
                    )
                    .onAppear { pulsePhase = true }
            } else if isReady {
                repoColor
                    .opacity(isJustReady ? justReadyOpacity : readyOpacity)
                    .animation(.easeOut(duration: 1.5), value: isJustReady)
            }
        }
        .allowsHitTesting(false)
    }
}

// Row for a safekept session whose originating project is no longer
// in the repo's live projects. Doesn't render off a Task because
// these don't have one — they live only in the SessionArchiveCache.
// Click does nothing yet (a future "Adopt as project" / "Resume in
// new project" action would dispatch through Store).
struct ArchivedSessionRow: View {
    let repo: Repo
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

// MARK: - External convo row

// Compact row for an ExternalConvo (claude session running outside
// Mani). Same density as PastSessionRow but driven directly by the
// reducer-owned ExternalConvo struct rather than a Task wrapper.
struct ExternalConvoRow: View {
    let repo: Repo
    let convo: ExternalConvo
    let selected: Bool
    let onTap: () -> Void
    let onContextMenu: () -> AnyView
    let indent: CGFloat

    @ObservedObject private var infoCache = ExternalSessionInfoCache.shared
    @State private var hovered = false

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        let info = infoCache.entries[convo.sessionId]
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
                        Text("session \(convo.sessionId.prefix(8))")
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
        .padding(.leading, indent)
        .padding(.trailing, 10)
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
}
