import SwiftUI
import ManiCore
import Foundation

// Minimal v0.1 creation dialogs. Color picking, swatch palette, branch
// dropdown for git worktrees, etc. come later — see docs/ui.md.

struct NewProjectSheet: View {
    let store: Store
    @Binding var isPresented: Bool
    @EnvironmentObject var sweeper: SafekeepingSweeper
    @State private var name: String = ""
    @State private var color: String = ColorPalette.swatches.first ?? "#e74c3c"
    @State private var rootDir: String = NSHomeDirectory()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New repo").font(.headline)
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Repo root", text: $rootDir)
                    Button("Choose…") { pickFolder() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                ColorSwatchPicker(hex: $color)
            }
            Text("The repo root anchors `git worktree add` and shows as the repo's main workspace. Additional worktrees can be added after creation.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let url = URL(fileURLWithPath: rootDir)
                    _Concurrency.Task {
                        await store.dispatch(.createRepo(
                            name: name.isEmpty ? "untitled" : name,
                            color: color,
                            rootDir: url
                        ))
                        // Kick the safekeep sweeper immediately so
                        // existing ~/.claude/repos sessions for
                        // this rootDir get matched + surfaced now,
                        // not on the next 5-min tick.
                        await sweeper.runOnce()
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || rootDir.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            rootDir = url.path
        }
    }
}

struct NewWorktreeSheet: View {
    let store: Store
    let repoId: UUID
    @Binding var isPresented: Bool
    @EnvironmentObject var sweeper: SafekeepingSweeper

    enum Kind: String, CaseIterable, Identifiable {
        case folder = "Folder"
        case git = "Git worktree"
        var id: String { rawValue }
    }

    @State private var path: String = NSHomeDirectory()
    @State private var kind: Kind = .folder
    @State private var branch: String = ""
    @State private var baseRef: String = "main"
    @State private var addShellTask: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New worktree").font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.segmented)
            Form {
                HStack {
                    TextField("Path", text: $path)
                    Button("Choose…") { pickFolder() }
                }
                if kind == .git {
                    TextField("Branch", text: $branch)
                    TextField("Base ref", text: $baseRef)
                }
                Toggle("Add a default shell task", isOn: $addShellTask)
            }
            Text("The worktree's directory name + current branch identify it in the sidebar.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let worktreeKind: WorktreeKind = (kind == .git)
                        ? .git(branch: branch.isEmpty ? "main" : branch,
                               baseRef: baseRef.isEmpty ? nil : baseRef)
                        : .folder
                    let pathURL = URL(fileURLWithPath: path)
                    let wantShell = addShellTask
                    let repoId = repoId
                    _Concurrency.Task {
                        await store.dispatch(.createWorktree(
                            repoId: repoId,
                            kind: worktreeKind,
                            path: pathURL
                        ))
                        guard let repo = store.state.repos.first(where: { $0.id == repoId }),
                              let worktree = repo.worktrees.last else {
                            isPresented = false
                            return
                        }
                        let wtPath = WorktreePath(
                            repo: repoId, worktree: worktree.id
                        )
                        if wantShell {
                            let spec = ProcessSpec(
                                command: "/bin/zsh",
                                args: ["-l"],
                                env: [:],
                                cwd: pathURL,
                                initialInput: nil
                            )
                            await store.dispatch(.createTask(
                                at: wtPath, name: "shell", kind: .shell,
                                spec: spec, autoSelect: true
                            ))
                        }
                        // .git kind worktrees are by definition git checkouts.
                        // For .folder kind, check the filesystem — many
                        // `.folder` worktrees ARE git repos the user just
                        // chose to register as plain folders.
                        if ManiApp.isGitCheckout(at: pathURL) {
                            await SidebarView.spawnDiff(
                                at: wtPath, cwd: pathURL, store: store
                            )
                        }
                        // Pull in any pre-existing claude sessions
                        // that match the new worktree's path now,
                        // instead of waiting for the 5-min tick.
                        await sweeper.runOnce()
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(path.isEmpty || (kind == .git && branch.isEmpty))
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }
}

struct RenameJobSheet: View {
    let store: Store
    let taskPath: TaskPath
    let currentName: String
    @Binding var isPresented: Bool
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename task").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { commit() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty || trimmedName == currentName)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear { name = currentName }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func commit() {
        guard !trimmedName.isEmpty, trimmedName != currentName else { return }
        let final = trimmedName
        _Concurrency.Task {
            await store.dispatch(.renameTask(at: taskPath, name: final))
            isPresented = false
        }
    }
}

struct ResumeClaudeSheet: View {
    let store: Store
    let worktreePath: WorktreePath
    let cwd: URL
    @Binding var isPresented: Bool
    var onCreated: ((UUID) -> Void)?
    @EnvironmentObject var archiveCache: SessionArchiveCache

    // Filter the repo-wide cache down to sessions whose
    // originating cwd matches this worktree. Cheap — the cache is
    // already in memory after boot's bootstrap + first sweep, so no
    // disk scan on open.
    private var sessions: [SessionIndexEntry] {
        let cwdPath = cwd.path
        let cwdPrefix = cwdPath + "/"
        return archiveCache.entries(for: worktreePath.repo)
            .filter { entry in
                entry.originatingCwd == cwdPath
                    || entry.originatingCwd.hasPrefix(cwdPrefix)
            }
            .sorted {
                ($0.lastMessageAt ?? .distantPast)
                    > ($1.lastMessageAt ?? .distantPast)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume Claude session").font(.headline)
            Text("Sessions previously run in \(cwd.path)")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                if sessions.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No prior Claude sessions found for this directory.")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    sessionList
                }
            }
            .frame(minHeight: 240)

            HStack {
                Button("Start fresh task") { startFresh() }
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 580, height: 380)
    }

    private var sessionList: some View {
        List(sessions, id: \.sessionId) { session in
            Button { resume(sessionId: session.sessionId) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.firstUserMessage ?? "(no user prompt yet)")
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(session.sessionId.prefix(8))
                            .font(.system(.caption2, design: .monospaced))
                        if let ts = session.lastMessageAt {
                            Text(ts, style: .relative)
                                .font(.caption2)
                        }
                        Text("\(session.messageCount) msgs")
                            .font(.caption2)
                    }
                    .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func resume(sessionId: String) {
        let repo = store.state.repos.first(where: { $0.id == worktreePath.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sessionId, invocation: invocation)
        _Concurrency.Task {
            await store.dispatch(.createTask(
                at: worktreePath,
                name: "claude (resumed \(sessionId.prefix(6)))",
                kind: .claude(sessionId: sessionId),
                spec: spec,
                autoSelect: true
            ))
            if let id = store.state.repos
                .first(where: { $0.id == worktreePath.repo })?
                .worktrees.first(where: { $0.id == worktreePath.worktree })?
                .tasks.last?.id
            {
                onCreated?(id)
            }
            isPresented = false
        }
    }

    private func startFresh() {
        let repo = store.state.repos.first(where: { $0.id == worktreePath.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil, invocation: invocation)
        _Concurrency.Task {
            await store.dispatch(.createTask(
                at: worktreePath, name: "claude",
                kind: .claude(sessionId: nil),
                spec: spec,
                autoSelect: true
            ))
            if let id = store.state.repos
                .first(where: { $0.id == worktreePath.repo })?
                .worktrees.first(where: { $0.id == worktreePath.worktree })?
                .tasks.last?.id
            {
                onCreated?(id)
            }
            isPresented = false
        }
    }
}

struct NewTaskSheet: View {
    let store: Store
    let worktreePath: WorktreePath
    let cwd: URL
    @Binding var isPresented: Bool
    var onCreated: ((UUID) -> Void)?

    enum Kind: String, CaseIterable, Identifiable {
        case shell = "Shell"
        case claude = "Claude"
        var id: String { rawValue }
    }

    @State private var name: String = ""
    @State private var kind: Kind = .shell
    @State private var command: String = "/bin/zsh"
    @State private var argsString: String = "-l"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New task").font(.headline)
            Picker("Kind", selection: $kind) {
                ForEach(Kind.allCases) { k in Text(k.rawValue).tag(k) }
            }
            .pickerStyle(.segmented)
            .onChange(of: kind) { _, new in
                switch new {
                case .shell:
                    command = "/bin/zsh"
                    argsString = "-l"
                    if name.isEmpty || name == "claude" { name = "shell" }
                case .claude:
                    // Plain login shell here; the actual `claude` invocation
                    // is injected post-spawn (initialInput) so the TUI's
                    // resize-redraw matches the user's manual workflow.
                    command = "/bin/zsh"
                    argsString = "-l"
                    if name.isEmpty || name == "shell" { name = "claude" }
                }
            }
            Form {
                TextField("Name", text: $name)
                if kind == .shell {
                    TextField("Command", text: $command)
                    TextField("Args (space-separated)", text: $argsString)
                } else {
                    // Claude tasks always spawn /bin/zsh -l + injected `claude\r`
                    // (ADR-015). Showing/editing the command field would lie —
                    // ClaudeTaskSpec.make ignores the form values.
                    Text("Spawned via /bin/zsh -l with `claude` injected at the prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let args = argsString
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    let claudeRepo = store.state.repos.first(where: { $0.id == worktreePath.repo })
                    let claudeInvocation = ClaudeTaskSpec.resolveInvocation(
                        repo: claudeRepo, settings: store.state.settings
                    )
                    let spec: ProcessSpec = (kind == .claude)
                        ? ClaudeTaskSpec.make(cwd: cwd, sessionId: nil, invocation: claudeInvocation)
                        : ProcessSpec(
                            command: command, args: args,
                            env: [:], cwd: cwd,
                            initialInput: nil
                        )
                    let taskKind: TaskKind = (kind == .claude)
                        ? .claude(sessionId: nil)
                        : .shell
                    let taskName = name.isEmpty ? kind.rawValue.lowercased() : name
                    _Concurrency.Task {
                        await store.dispatch(.createTask(
                            at: worktreePath,
                            name: taskName,
                            kind: taskKind,
                            spec: spec,
                            autoSelect: true
                        ))
                        if let id = store.state.repos
                            .first(where: { $0.id == worktreePath.repo })?
                            .worktrees.first(where: { $0.id == worktreePath.worktree })?
                            .tasks.last?.id
                        {
                            onCreated?(id)
                        }
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
