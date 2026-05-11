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
        .contentShape(Rectangle())
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
    let onContextMenu: () -> AnyView

    var body: some View {
        HStack(spacing: 6) {
            // Project color stripe — full height of the row, anchored
            // left so it lines up with the rows below for "everything
            // under atlas is the same atlas" continuity.
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
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
                    .font(.system(.subheadline, design: .default).weight(.medium))
                    .foregroundStyle(.secondary)
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
                if let diffJobId {
                    Button(action: onSelectDiff) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(
                                selectedJobId == diffJobId
                                    ? SwiftUI.Color.accentColor
                                    : .secondary
                            )
                    }
                    .buttonStyle(.borderless)
                    .help("Diff workspace")
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 10)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .contextMenu { onContextMenu() }
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
                : SwiftUI.Color.clear
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { onContextMenu() }
    }

    // Subtitle: claude session id (last 6 chars) for linked claude jobs;
    // nothing for shell. Helps disambiguate multiple claude tasks in the
    // same worktree.
    private var subtitle: String? {
        if case let .claude(sid) = job.kind, let sid {
            return "session " + String(sid.prefix(8))
        }
        return nil
    }
}
