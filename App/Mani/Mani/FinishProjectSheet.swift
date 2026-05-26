import SwiftUI
import ManiCore

// The user-facing endpoint for the managed-worktree finish flow.
// Triggered from the project context menu ("Finish project…").
// Shows the project's current git status, lets the user pick how
// aggressively to clean up, and dispatches `finishProject` with
// the matching FinishCleanup case.
//
// Two-pane layout: status header at the top (branch, ahead/behind,
// line diff, dirty/conflict markers), three radio options below.
// The destructive `Discard everything` option is gated behind an
// explicit confirmation checkbox so an accidental click can't blow
// away an unmerged branch.
struct FinishProjectSheet: View {
    let store: Store
    let repoColor: SwiftUI.Color
    let repoName: String
    let projectName: String
    let projectPath: ProjectPath
    let workspace: Workspace
    @Binding var isPresented: Bool

    @ObservedObject private var statsCache = WorktreeStatsCache.shared
    @State private var choice: FinishChoice = .archiveOnly
    @State private var confirmDestructive: Bool = false

    enum FinishChoice: Hashable {
        case archiveOnly
        case removeWorktree
        case removeWorktreeAndBranch
    }

    // Derived: which choices to render. `.folder` workspaces only
    // get archive-only — there's no worktree to remove.
    private var availableChoices: [FinishChoice] {
        switch workspace.kind {
        case .folder:
            return [.archiveOnly]
        case .gitWorktree:
            return [.archiveOnly, .removeWorktree, .removeWorktreeAndBranch]
        }
    }

    // Branch name (when this is a gitWorktree) for the
    // "discard everything" label.
    private var branch: String? {
        if case let .gitWorktree(branch, _, _) = workspace.kind {
            return branch
        }
        return nil
    }

    private var stats: WorktreeGitStats? {
        statsCache.stats[projectPath.project]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            statusLine
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("What should happen to the workspace?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                ForEach(availableChoices, id: \.self) { c in
                    choiceRow(c)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Finish") { onFinish() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(isFinishDisabled)
            }
        }
        .padding(22)
        .frame(width: 520)
        .onAppear {
            // Default to .removeWorktree when offered — it's the
            // recommended path for managed worktrees and a no-op
            // for the archive-only sheet (where it's not available).
            if availableChoices.contains(.removeWorktree) {
                choice = .removeWorktree
            }
        }
    }

    // MARK: Sub-views

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Finish '\(projectName)'")
                .font(.system(.title3, design: .serif).weight(.semibold))
            HStack(spacing: 6) {
                Text(repoName)
                    .foregroundStyle(repoColor)
                Text("/").foregroundStyle(.tertiary)
                Text(projectName)
                    .foregroundStyle(.secondary)
            }
            .font(.system(size: 11, design: .monospaced))
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if let s = stats {
            HStack(spacing: 12) {
                if let b = s.branch {
                    Label {
                        Text(b)
                            .font(.system(size: 11, design: .monospaced))
                    } icon: {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(.secondary)
                    if let d = s.defaultBranch {
                        Text("vs \(d)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
                if s.ahead > 0 {
                    Text("↑\(s.ahead)")
                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                        .foregroundStyle(.green.opacity(0.85))
                }
                if s.behind > 0 {
                    Text("↓\(s.behind)")
                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                        .foregroundStyle(.orange.opacity(0.85))
                }
                if s.insertions > 0 || s.deletions > 0 {
                    HStack(spacing: 4) {
                        if s.insertions > 0 {
                            Text("+\(s.insertions)")
                                .foregroundStyle(.green.opacity(0.85))
                        }
                        if s.deletions > 0 {
                            Text("−\(s.deletions)")
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                    .font(.system(size: 11, design: .monospaced).weight(.medium))
                }
                if s.hasConflicts {
                    Label("conflicts", systemImage: "exclamationmark.octagon.fill")
                        .font(.system(size: 11, design: .rounded).weight(.medium))
                        .foregroundStyle(.red)
                } else if s.hasUncommitted {
                    Label("dirty", systemImage: "pencil.tip")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.yellow.opacity(0.9))
                } else {
                    Label("clean", systemImage: "checkmark.circle")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.green.opacity(0.85))
                }
                Spacer()
            }
        } else {
            Text("git status pending…")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private func choiceRow(_ c: FinishChoice) -> some View {
        let isSelected = choice == c
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? repoColor : .secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title(for: c))
                        .font(.system(.body).weight(isSelected ? .semibold : .regular))
                    Text(subtitle(for: c))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            // Destructive confirmation inline under the option.
            if c == .removeWorktreeAndBranch, isSelected {
                Toggle(isOn: $confirmDestructive) {
                    Text("I understand the branch \(branch.map { "`\($0)`" } ?? "") will be permanently deleted.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .toggleStyle(.checkbox)
                .padding(.leading, 24)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isSelected ? repoColor.opacity(0.08) : SwiftUI.Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    isSelected ? repoColor.opacity(0.35) : SwiftUI.Color.clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onTapGesture { choice = c }
    }

    private func title(for c: FinishChoice) -> String {
        switch c {
        case .archiveOnly: return "Archive only"
        case .removeWorktree: return "Remove worktree" + (availableChoices.contains(.removeWorktree) && c == .removeWorktree ? "  ·  recommended" : "")
        case .removeWorktreeAndBranch: return "Discard everything"
        }
    }

    private func subtitle(for c: FinishChoice) -> String {
        switch c {
        case .archiveOnly:
            return "Keep the worktree on disk. The project moves to Finished. Use this if you might come back."
        case .removeWorktree:
            if let b = branch {
                return "Run `git worktree remove`. The work survives as branch `\(b)` in the main repo; the worktree directory is gone."
            }
            return "Run `git worktree remove`. The worktree directory is gone."
        case .removeWorktreeAndBranch:
            if let b = branch {
                return "Remove the worktree AND `git branch -D \(b)`. The work is unrecoverable unless it's been pushed."
            }
            return "Remove the worktree AND delete the branch. Destructive."
        }
    }

    private var isFinishDisabled: Bool {
        if choice == .removeWorktreeAndBranch && !confirmDestructive { return true }
        return false
    }

    private func onFinish() {
        let cleanup: FinishCleanup
        switch choice {
        case .archiveOnly:
            cleanup = .archiveOnly
        case .removeWorktree:
            // Pass force: true — the user clicked Finish despite
            // any dirty/conflict warning shown in the status line.
            cleanup = .removeWorktree(force: true)
        case .removeWorktreeAndBranch:
            cleanup = .removeWorktreeAndBranch(force: true)
        }
        let path = projectPath
        _Concurrency.Task {
            await store.dispatch(.finishProject(at: path, cleanup: cleanup))
            isPresented = false
        }
    }
}
