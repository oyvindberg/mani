import SwiftUI
import AppKit
import ManiCore

// Detail pane for a Job whose kind is .diff. Left: file pane (refs section,
// tracked changes tree, untracked files tree). Right: libghostty terminal
// connected to the kept-warm shell that delta runs in. Clicking a tracked
// file writes a `git diff <ref> -- <path> | delta` pipeline to the shell's
// master FD — no per-click spawn, just a stdin write.
//
// The shell PTY is the Job's primary process; it lives in EffectRunner for
// the Job's lifetime and survives view re-mounts (switching to a different
// sidebar item and back).
struct DiffWorkspaceView: View {
    let job: Job
    let jobPath: JobPath
    let worktreePath: URL

    @EnvironmentObject var store: Store

    @State private var sourceRef: String = "HEAD"
    @State private var refsExpanded: Bool = true
    @State private var trackedExpanded: Bool = true
    @State private var untrackedExpanded: Bool = true
    @State private var trackedTree: [PathTreeNode] = []
    @State private var untrackedTree: [PathTreeNode] = []
    @State private var untrackedSelection: Set<String> = []
    @State private var selectedFile: String?
    // Token written once after the shell prompt settles so the Mani-typed
    // commands aren't echoed back into the pane. The library runs `stty
    // -echo` to suppress keystroke echo plus a clear-screen reset.
    @State private var hasInitialisedShell = false

    var body: some View {
        HSplitView {
            filePane
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            TerminalPane(jobPath: jobPath)
                .id(jobPath)
        }
        .task {
            // Run the initial refresh and the one-shot shell setup off the
            // main actor; both can take 50–200 ms.
            refreshFileList()
            initialiseShellIfNeeded()
        }
        .onChange(of: sourceRef) { _, _ in refreshFileList() }
    }

    // MARK: File pane

    private var filePane: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    refsSection
                    Divider().padding(.vertical, 4)
                    trackedSection
                    Divider().padding(.vertical, 4)
                    untrackedSection
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
        }
    }

    private var refsSection: some View {
        DisclosureGroup(isExpanded: $refsExpanded) {
            HStack {
                Text("Compare against:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("HEAD", text: $sourceRef)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { refreshFileList() }
            }
            .padding(.top, 4)
        } label: {
            Text("Refs").font(.headline)
        }
    }

    private var trackedSection: some View {
        DisclosureGroup(isExpanded: $trackedExpanded) {
            if trackedTree.isEmpty {
                Text("No tracked changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            } else {
                ForEach(trackedTree) { node in
                    trackedNode(node, depth: 0)
                }
            }
        } label: {
            HStack {
                Text("Tracked changes").font(.headline)
                Text("(\(countLeaves(trackedTree)))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    refreshFileList()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    private var untrackedSection: some View {
        DisclosureGroup(isExpanded: $untrackedExpanded) {
            if untrackedTree.isEmpty {
                Text("No untracked files.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            } else {
                ForEach(untrackedTree) { node in
                    untrackedNode(node, depth: 0)
                }
            }
        } label: {
            HStack {
                Text("Untracked").font(.headline)
                Text("(\(countLeaves(untrackedTree)))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !untrackedSelection.isEmpty {
                    Button("Add \(untrackedSelection.count) to git") {
                        addSelectedToGit()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            }
        }
    }

    // MARK: Tree row rendering

    @ViewBuilder
    private func trackedNode(_ node: PathTreeNode, depth: Int) -> some View {
        if node.isDirectory {
            // Directory: always expanded (single-level disclosure would
            // double-nest; nested DisclosureGroups create UI clutter).
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text(node.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(depth) * 12)
                ForEach(node.children) { child in
                    trackedNode(child, depth: depth + 1)
                }
            }
        } else if let fullPath = node.fullPath {
            HStack(spacing: 4) {
                Text(node.status?.glyph ?? " ")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(statusColor(node.status))
                    .frame(width: 12)
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                Text(node.name)
                    .font(.caption)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(
                selectedFile == fullPath
                    ? SwiftUI.Color.accentColor.opacity(0.18)
                    : SwiftUI.Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedFile = fullPath
                showDiff(for: fullPath)
            }
        }
    }

    @ViewBuilder
    private func untrackedNode(_ node: PathTreeNode, depth: Int) -> some View {
        if node.isDirectory {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 11))
                    Text(node.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, CGFloat(depth) * 12)
                ForEach(node.children) { child in
                    untrackedNode(child, depth: depth + 1)
                }
            }
        } else if let fullPath = node.fullPath {
            HStack(spacing: 4) {
                Toggle("", isOn: Binding(
                    get: { untrackedSelection.contains(fullPath) },
                    set: { isOn in
                        if isOn { untrackedSelection.insert(fullPath) }
                        else { untrackedSelection.remove(fullPath) }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                Text(node.name)
                    .font(.caption)
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(
                selectedFile == fullPath
                    ? SwiftUI.Color.accentColor.opacity(0.18)
                    : SwiftUI.Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                selectedFile = fullPath
                showUntrackedFile(for: fullPath)
            }
        }
    }

    private func statusColor(_ s: GitChange.Status?) -> SwiftUI.Color {
        switch s {
        case .added:    return .green
        case .modified: return .yellow
        case .deleted:  return .red
        case .renamed:  return .blue
        default:        return .secondary
        }
    }

    private func countLeaves(_ nodes: [PathTreeNode]) -> Int {
        nodes.reduce(0) { acc, n in
            acc + (n.isDirectory ? countLeaves(n.children) : 1)
        }
    }

    // MARK: Refresh

    private func refreshFileList() {
        let ref = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let wt = worktreePath
        let useRef = ref.isEmpty ? "HEAD" : ref
        Task.detached(priority: .userInitiated) {
            let tracked = GitChangesScanner.tracked(worktree: wt, sourceRef: useRef)
            let untracked = GitChangesScanner.untracked(worktree: wt)
            let trackedTree = PathTreeNode.tree(
                from: tracked.map { ($0.path, .some($0.status)) }
            )
            let untrackedTree = PathTreeNode.tree(
                from: untracked.map { ($0, .added) } // untracked = "would be added"
            )
            await MainActor.run {
                self.trackedTree = trackedTree
                self.untrackedTree = untrackedTree
                // Drop any selected untracked paths that vanished.
                self.untrackedSelection.formIntersection(Set(untracked))
            }
        }
    }

    // MARK: Shell command pipelines

    private func initialiseShellIfNeeded() {
        guard !hasInitialisedShell else { return }
        // Wait briefly for the spawn to settle (zsh's initial prompt arrives
        // ~800 ms after fork; matches ClaudeTaskSpec's delay).
        let runner = store.runner
        let path = jobPath
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard let pty = await runner.pty(for: path) else { return }
            // Suppress keystroke echo + clear screen so the only thing the
            // user ever sees in this pane is delta output (and any error
            // output from git / delta).
            pty.write(Data("stty -echo; clear\n".utf8))
        }
        hasInitialisedShell = true
    }

    private func showDiff(for path: String) {
        let ref = sourceRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let useRef = ref.isEmpty ? "HEAD" : ref
        let escaped = shellEscape(path)
        sendCommand(
            "printf '\\033c'; git diff \(useRef) -- \(escaped) | delta --paging=never\n"
        )
    }

    private func showUntrackedFile(for path: String) {
        let escaped = shellEscape(path)
        // Untracked = nothing committed yet. Show as if comparing /dev/null
        // to the working copy — delta renders the whole file as added.
        sendCommand(
            "printf '\\033c'; diff -u /dev/null \(escaped) | delta --paging=never\n"
        )
    }

    private func sendCommand(_ command: String) {
        let runner = store.runner
        let path = jobPath
        Task.detached {
            guard let pty = await runner.pty(for: path) else { return }
            pty.write(Data(command.utf8))
        }
    }

    private func shellEscape(_ s: String) -> String {
        // Single-quote everything, escape embedded single quotes.
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func addSelectedToGit() {
        let paths = Array(untrackedSelection)
        let wt = worktreePath
        Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.add(paths: paths, worktree: wt)
            await MainActor.run {
                untrackedSelection.removeAll()
                refreshFileList()
            }
        }
    }
}
