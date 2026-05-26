import SwiftUI
import AppKit
import ManiCore

// Detail pane for a Task whose kind is .diff. Left: file pane (refs section,
// tracked changes tree, untracked files tree). Right: libghostty terminal
// connected to the kept-warm shell that delta runs in. Clicking a tracked
// file writes a `git diff <ref> -- <path> | delta` pipeline to the shell's
// master FD — no per-click spawn, just a stdin write.
//
// The shell PTY is the Task's primary process; it lives in EffectRunner for
// the Task's lifetime and survives view re-mounts (switching to a different
// sidebar item and back).
struct DiffWorkspaceView: View {
    let task: Task
    let taskPath: TaskPath
    let projectPath: URL

    @EnvironmentObject var store: Store

    @State private var stagedExpanded: Bool = true
    @State private var unstagedExpanded: Bool = true
    @State private var untrackedExpanded: Bool = true
    @State private var stagedTree: [PathTreeNode] = []
    @State private var unstagedTree: [PathTreeNode] = []
    @State private var untrackedTree: [PathTreeNode] = []
    @State private var stagedPaths: [String] = []
    @State private var unstagedPaths: [String] = []
    @State private var untrackedPaths: [String] = []
    @State private var untrackedSelection: Set<String> = []
    @State private var selectedFile: SelectedFile?
    @State private var commitMessage: String = ""
    @State private var commitInFlight: Bool = false
    @State private var renameMap: [String: String] = [:] // current → previous
    @FocusState private var fileListFocused: Bool
    @State private var fsWatcher: WorktreeFSWatcher?
    @State private var refreshInFlight: Bool = false
    @State private var refreshAgainPending: Bool = false

    // Tracks which section the selected file lives in so the right pane
    // renders the right diff: staged shows index-vs-HEAD, unstaged shows
    // project-vs-index, untracked shows the full file as added.
    enum Section: Equatable { case staged, unstaged, untracked }
    struct SelectedFile: Equatable {
        let path: String
        let section: Section
    }
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
            checkDelta()
            refreshFileList()
            initialiseShellIfNeeded()
            startFSWatching()
        }
        .onDisappear { fsWatcher?.stop() }
    }

    @ViewBuilder
    private var rightPane: some View {
        if deltaPath == "" {
            DeltaMissingCard()
        } else {
            TerminalPane(taskPath: taskPath)
                .id(taskPath)
        }
    }

    private func checkDelta() {
        _Concurrency.Task.detached(priority: .userInitiated) {
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
                    stagedSection
                    Divider().padding(.vertical, 4)
                    unstagedSection
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
                if let f = selectedFile { renderDiff(for: f) }
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
                if stagedPaths.isEmpty {
                    Text("Nothing staged")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Will commit \(stagedPaths.count) staged file\(stagedPaths.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(commitInFlight ? "Committing…" : "Commit") {
                    performCommit()
                }
                .disabled(
                    commitInFlight
                        || commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || stagedPaths.isEmpty
                )
                .keyboardShortcut(.return, modifiers: [.command])
            }
        }
        .padding(8)
        .background(SwiftUI.Color.secondary.opacity(0.06))
    }

    private var stagedSection: some View {
        DisclosureGroup(isExpanded: $stagedExpanded) {
            if stagedTree.isEmpty {
                Text("Nothing staged.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            } else {
                ForEach(stagedTree) { node in
                    fileNode(node, depth: 0, section: .staged)
                }
            }
        } label: {
            HStack {
                Text("Staged").font(.headline)
                Text("(\(stagedPaths.count))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !stagedPaths.isEmpty {
                    Menu {
                        Button("Unstage all") { unstage(paths: stagedPaths) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                Button { refreshFileList() } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh")
            }
        }
    }

    private var unstagedSection: some View {
        DisclosureGroup(isExpanded: $unstagedExpanded) {
            if unstagedTree.isEmpty {
                Text("No unstaged changes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 12)
            } else {
                ForEach(unstagedTree) { node in
                    fileNode(node, depth: 0, section: .unstaged)
                }
            }
        } label: {
            HStack {
                Text("Unstaged").font(.headline)
                Text("(\(unstagedPaths.count))")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !unstagedPaths.isEmpty {
                    Menu {
                        Button("Stage all") { stage(paths: unstagedPaths) }
                        Button("Discard all…", role: .destructive) {
                            discardWithConfirm(paths: unstagedPaths)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
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
                    fileNode(node, depth: 0, section: .untracked)
                }
            }
        } label: {
            HStack {
                Text("Untracked").font(.headline)
                Text("(\(untrackedPaths.count))")
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

    private func fileNode(
        _ node: PathTreeNode,
        depth: Int,
        section: Section
    ) -> AnyView {
        if node.isDirectory {
            return AnyView(VStack(alignment: .leading, spacing: 2) {
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
                    fileNode(child, depth: depth + 1, section: section)
                }
            })
        } else if let fullPath = node.fullPath {
            let selected = (selectedFile?.path == fullPath
                            && selectedFile?.section == section)
            return AnyView(HStack(spacing: 4) {
                if section == .untracked {
                    Toggle("", isOn: Binding(
                        get: { untrackedSelection.contains(fullPath) },
                        set: { isOn in
                            if isOn { untrackedSelection.insert(fullPath) }
                            else { untrackedSelection.remove(fullPath) }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                } else {
                    Text(node.status?.glyph ?? " ")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(statusColor(node.status))
                        .frame(width: 12)
                }
                Image(systemName: "doc")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 10))
                if let prev = renameMap[fullPath], prev != fullPath {
                    Text("\(URL(fileURLWithPath: prev).lastPathComponent) → \(node.name)")
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text(node.name).font(.caption)
                }
                Spacer()
            }
            .padding(.leading, CGFloat(depth) * 12)
            .padding(.vertical, 1)
            .padding(.horizontal, 4)
            .background(
                selected
                    ? SwiftUI.Color.accentColor.opacity(0.18)
                    : SwiftUI.Color.clear
            )
            .contentShape(Rectangle())
            .onTapGesture {
                let sel = SelectedFile(path: fullPath, section: section)
                selectedFile = sel
                renderDiff(for: sel)
                fileListFocused = true
            }
            .contextMenu { menu(for: section, path: fullPath) })
        } else {
            return AnyView(EmptyView())
        }
    }

    @ViewBuilder
    private func menu(for section: Section, path: String) -> some View {
        switch section {
        case .staged:
            Button("Unstage") { unstage(paths: [path]) }
        case .unstaged:
            Button("Stage") { stage(paths: [path]) }
            Button("Discard changes…", role: .destructive) {
                discardWithConfirm(paths: [path])
            }
        case .untracked:
            Button("Add to git") { stage(paths: [path]) }
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
        // Re-entrance guard: if a refresh is already in flight, just
        // mark a follow-up. Without this, FSEvents bursts (and the
        // self-trigger from running git itself) used to spawn N
        // overlapping `git status` subprocesses, each tying up a
        // core. Empirically: 800 % CPU on a 7-project machine.
        if refreshInFlight {
            refreshAgainPending = true
            return
        }
        refreshInFlight = true
        let wt = projectPath
        _Concurrency.Task.detached(priority: .userInitiated) {
            let staged = GitChangesScanner.staged(project: wt)
            let unstaged = GitChangesScanner.unstaged(project: wt)
            let untracked = GitChangesScanner.untracked(project: wt)
            let stagedTree = PathTreeNode.tree(
                from: staged.map { ($0.path, .some($0.status)) }
            )
            let unstagedTree = PathTreeNode.tree(
                from: unstaged.map { ($0.path, .some($0.status)) }
            )
            let untrackedTree = PathTreeNode.tree(
                from: untracked.map { ($0, .added) }
            )
            let stagedPaths = staged.map { $0.path }
            let unstagedPaths = unstaged.map { $0.path }
            var renames: [String: String] = [:]
            for ch in staged + unstaged where ch.previousPath != nil {
                renames[ch.path] = ch.previousPath
            }
            await MainActor.run {
                self.stagedTree = stagedTree
                self.unstagedTree = unstagedTree
                self.untrackedTree = untrackedTree
                self.stagedPaths = stagedPaths
                self.unstagedPaths = unstagedPaths
                self.untrackedPaths = untracked
                self.renameMap = renames
                self.untrackedSelection.formIntersection(Set(untracked))
                // Drop selectedFile if it disappeared (e.g. discarded /
                // moved between sections after stage / unstage).
                if let sel = self.selectedFile {
                    switch sel.section {
                    case .staged where !stagedPaths.contains(sel.path):
                        self.selectedFile = nil
                    case .unstaged where !unstagedPaths.contains(sel.path):
                        self.selectedFile = nil
                    case .untracked where !untracked.contains(sel.path):
                        self.selectedFile = nil
                    default: break
                    }
                }
                self.refreshInFlight = false
                if self.refreshAgainPending {
                    self.refreshAgainPending = false
                    self.refreshFileList()
                }
            }
        }
    }

    // MARK: Keyboard nav

    // Walk staged → unstaged → untracked in order. Arrow up/down moves
    // across section boundaries; section context follows.
    private func stepSelection(by delta: Int) {
        let all: [SelectedFile] =
            stagedPaths.map    { SelectedFile(path: $0, section: .staged) }
          + unstagedPaths.map  { SelectedFile(path: $0, section: .unstaged) }
          + untrackedPaths.map { SelectedFile(path: $0, section: .untracked) }
        guard !all.isEmpty else { return }
        if let current = selectedFile, let idx = all.firstIndex(of: current) {
            let next = (idx + delta + all.count) % all.count
            selectedFile = all[next]
        } else {
            selectedFile = delta >= 0 ? all.first : all.last
        }
        if let sel = selectedFile { renderDiff(for: sel) }
    }

    // MARK: Git ops

    private func stage(paths: [String]) {
        let wt = projectPath
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.add(paths: paths, project: wt)
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
        let wt = projectPath
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.discard(paths: paths, project: wt)
            await MainActor.run { refreshFileList() }
        }
    }

    private func unstage(paths: [String]) {
        let wt = projectPath
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.unstage(paths: paths, project: wt)
            await MainActor.run { refreshFileList() }
        }
    }

    private func performCommit() {
        let msg = commitMessage
        let wt = projectPath
        commitInFlight = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            let ok = GitChangesScanner.commitStaged(message: msg, project: wt)
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
        let watcher = WorktreeFSWatcher(root: projectPath) {
            // Coalesce bursts of writes.
            _Concurrency.Task { @MainActor in refreshFileList() }
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
        let path = taskPath
        _Concurrency.Task.detached {
            try? await _Concurrency.Task.sleep(nanoseconds: 1_000_000_000)
            guard let pty = await runner.pty(for: path) else { return }
            // Suppress keystroke echo + clear screen so the only thing the
            // user ever sees in this pane is delta output (and any error
            // output from git / delta).
            pty.write(Data("stty -echo; clear\n".utf8))
        }
        hasInitialisedShell = true
    }

    private func renderDiff(for sel: SelectedFile) {
        let escaped = shellEscape(sel.path)
        let pipeline: String
        switch sel.section {
        case .staged:
            // Index vs HEAD: what's been added with `git add` since last commit.
            pipeline = "git diff --cached -- \(escaped) | delta --paging=never | less -RF\n"
        case .unstaged:
            // Project vs index: what would be staged next.
            pipeline = "git diff -- \(escaped) | delta --paging=never | less -RF\n"
        case .untracked:
            // Untracked = nothing committed yet; render as all-added.
            pipeline = "diff -u /dev/null \(escaped) | delta --paging=never | less -RF\n"
        }
        sendCommand(pipeline)
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
        let path = taskPath
        _Concurrency.Task.detached {
            guard let pty = await runner.pty(for: path) else { return }
            pty.write(Data("\u{15}q\u{15}".utf8))
            try? await _Concurrency.Task.sleep(nanoseconds: 40_000_000)
            pty.write(Data(command.utf8))
        }
    }

    private func shellEscape(_ s: String) -> String {
        // Single-quote everything, escape embedded single quotes.
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func addSelectedToGit() {
        let paths = Array(untrackedSelection)
        let wt = projectPath
        _Concurrency.Task.detached(priority: .userInitiated) {
            _ = GitChangesScanner.add(paths: paths, project: wt)
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
