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
    @State private var trackedPaths: [String] = []
    @State private var untrackedSelection: Set<String> = []
    @State private var selectedFile: String?
    @State private var commitMessage: String = ""
    @State private var commitInFlight: Bool = false
    @State private var renameMap: [String: String] = [:] // current → previous
    @FocusState private var fileListFocused: Bool
    @State private var fsWatcher: WorktreeFSWatcher?
    // Token written once after the shell prompt settles so the Mani-typed
    // commands aren't echoed back into the pane. The library runs `stty
    // -echo` to suppress keystroke echo plus a clear-screen reset.
    @State private var hasInitialisedShell = false
    // nil = check pending; "" = delta missing; else = resolved absolute path
    @State private var deltaPath: String? = nil

    var body: some View {
        HSplitView {
            filePane
                .frame(minWidth: 260, idealWidth: 320, maxWidth: 480)
            rightPane
        }
        .task {
            // Run the initial refresh and the one-shot shell setup off the
            // main actor; both can take 50–200 ms.
            checkDelta()
            refreshFileList()
            initialiseShellIfNeeded()
            startFSWatching()
        }
        .onChange(of: sourceRef) { _, _ in refreshFileList() }
        .onDisappear { fsWatcher?.stop() }
    }

    @ViewBuilder
    private var rightPane: some View {
        if deltaPath == "" {
            DeltaMissingCard()
        } else {
            TerminalPane(jobPath: jobPath)
                .id(jobPath)
        }
    }

    private func checkDelta() {
        Task.detached(priority: .userInitiated) {
            let resolved = Self.findExecutable("delta") ?? ""
            await MainActor.run { deltaPath = resolved }
        }
    }

    // Mirrors EffectRunner's augmented PATH so `delta` is found in the
    // same locations a spawned Mani task would search. The Mac app-launched
    // process inherits a stripped PATH from launchd, so we have to prepend
    // the conventional user bin dirs.
    private static func findExecutable(_ name: String) -> String? {
        let extras = [
            "\(NSHomeDirectory())/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        let inherited = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []
        for dir in extras + inherited {
            let candidate = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
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
            .focusable()
            .focused($fileListFocused)
            .onKeyPress(.upArrow) {
                stepSelection(by: -1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                stepSelection(by: +1)
                return .handled
            }
            .onKeyPress(.return) {
                if let f = selectedFile { showDiff(for: f) }
                return .handled
            }
            Divider()
            commitBar
        }
    }

    private var commitBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("Commit message…", text: $commitMessage, axis: .vertical)
                .lineLimit(1...3)
                .textFieldStyle(.roundedBorder)
                .disabled(commitInFlight)
            HStack {
                Spacer()
                Button(commitInFlight ? "Committing…" : "Commit -am") {
                    performCommit()
                }
                .disabled(
                    commitInFlight
                        || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || trackedPaths.isEmpty
                )
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(8)
        .background(SwiftUI.Color.secondary.opacity(0.06))
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
                if let prev = renameMap[fullPath], prev != fullPath {
                    Text("\(URL(fileURLWithPath: prev).lastPathComponent) → \(node.name)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(node.name)
                        .font(.caption)
                }
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
                fileListFocused = true
            }
            .contextMenu {
                Button("Stage") { stage(paths: [fullPath]) }
                Button("Discard changes…", role: .destructive) {
                    discardWithConfirm(paths: [fullPath])
                }
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
            let trackedPaths = tracked.map { $0.path }
            var renames: [String: String] = [:]
            for ch in tracked where ch.previousPath != nil {
                renames[ch.path] = ch.previousPath
            }
            await MainActor.run {
                self.trackedTree = trackedTree
                self.untrackedTree = untrackedTree
                self.trackedPaths = trackedPaths
                self.renameMap = renames
                // Drop any selected untracked paths that vanished.
                self.untrackedSelection.formIntersection(Set(untracked))
                // Drop selectedFile if it disappeared (e.g. discarded).
                if let sel = self.selectedFile,
                   !trackedPaths.contains(sel),
                   !untracked.contains(sel) {
                    self.selectedFile = nil
                }
            }
        }
    }

    // MARK: Keyboard nav

    private func stepSelection(by delta: Int) {
        let all = trackedPaths + Array(untrackedTree.flatMap { collectLeafPaths($0) })
        guard !all.isEmpty else { return }
        if let current = selectedFile, let idx = all.firstIndex(of: current) {
            let next = (idx + delta + all.count) % all.count
            selectedFile = all[next]
        } else {
            selectedFile = delta >= 0 ? all.first : all.last
        }
        if let sel = selectedFile {
            if trackedPaths.contains(sel) { showDiff(for: sel) }
            else { showUntrackedFile(for: sel) }
        }
    }

    private func collectLeafPaths(_ node: PathTreeNode) -> [String] {
        if let p = node.fullPath { return [p] }
        return node.children.flatMap { collectLeafPaths($0) }
    }

    // MARK: Git ops

    private func stage(paths: [String]) {
        let wt = worktreePath
        Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.add(paths: paths, worktree: wt)
            await MainActor.run { refreshFileList() }
        }
    }

    private func discardWithConfirm(paths: [String]) {
        let alert = NSAlert()
        alert.messageText = "Discard changes to \(paths.count) file\(paths.count == 1 ? "" : "s")?"
        alert.informativeText = paths.prefix(5).joined(separator: "\n")
            + (paths.count > 5 ? "\n…and \(paths.count - 5) more" : "")
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let wt = worktreePath
        Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.discard(paths: paths, worktree: wt)
            await MainActor.run { refreshFileList() }
        }
    }

    private func performCommit() {
        let msg = commitMessage
        let wt = worktreePath
        commitInFlight = true
        Task.detached(priority: .userInitiated) {
            let ok = GitChangesScanner.commitAllTracked(message: msg, worktree: wt)
            await MainActor.run {
                commitInFlight = false
                if ok {
                    commitMessage = ""
                    refreshFileList()
                }
            }
        }
    }

    // MARK: FS auto-refresh

    private func startFSWatching() {
        let watcher = WorktreeFSWatcher(root: worktreePath) {
            // Coalesce bursts of writes.
            Task { @MainActor in refreshFileList() }
        }
        watcher.start()
        fsWatcher = watcher
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
            "git diff \(useRef) -- \(escaped) | delta --paging=never | less -RF\n"
        )
    }

    private func showUntrackedFile(for path: String) {
        let escaped = shellEscape(path)
        // Untracked = nothing committed yet. Show as if comparing /dev/null
        // to the working copy — delta renders the whole file as added.
        sendCommand(
            "diff -u /dev/null \(escaped) | delta --paging=never | less -RF\n"
        )
    }

    // Send a shell command into the warm PTY, first making sure we're not
    // inside a previously-spawned pager (less). The prefix is:
    //   Ctrl-U  → at the shell, kill the current input line (no-op if empty)
    //   q       → if less is active, this is its quit key
    //   Ctrl-U  → if less consumed q and we're back at the shell, clear any
    //             accidental 'q' that got typed
    // 40 ms lets less relinquish the alt screen before the new pipeline
    // arrives. The whole dance keeps subsequent file clicks fast: no
    // shell respawn, no rendering hiccup beyond the brief screen restore.
    private func sendCommand(_ command: String) {
        let runner = store.runner
        let path = jobPath
        Task.detached {
            guard let pty = await runner.pty(for: path) else { return }
            pty.write(Data("\u{15}q\u{15}".utf8))
            try? await Task.sleep(nanoseconds: 40_000_000)
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

private struct DeltaMissingCard: View {
    private let installCommand = "brew install git-delta"
    @State private var copied = false

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("delta is required")
                .font(.title3)
                .bold()
            Text("The Diff Workspace renders git output through `delta` for syntax-highlighted diffs. It isn't on your PATH yet.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            HStack(spacing: 6) {
                Text(installCommand)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(SwiftUI.Color.secondary.opacity(0.15))
                    .cornerRadius(4)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(installCommand, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copied ? "Copied" : "Copy command")
            }
            Text("Re-open the Diff Workspace after installing.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
