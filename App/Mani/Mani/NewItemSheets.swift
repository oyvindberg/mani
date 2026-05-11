import SwiftUI
import ManiCore
import Foundation

// Minimal v0.1 creation dialogs. Color picking, swatch palette, branch
// dropdown for git worktrees, etc. come later — see docs/ui.md.

struct NewProjectSheet: View {
    let store: Store
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var color: String = ColorPalette.swatches.first ?? "#e74c3c"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.headline)
            Form {
                TextField("Name", text: $name)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                ColorSwatchPicker(hex: $color)
            }
            Text("Add worktrees after creation. The first worktree becomes the project's primary.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        await store.dispatch(.createProject(
                            name: name.isEmpty ? "untitled" : name,
                            color: color
                        ))
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct NewWorktreeSheet: View {
    let store: Store
    let projectId: UUID
    @Binding var isPresented: Bool

    enum Kind: String, CaseIterable, Identifiable {
        case folder = "Folder"
        case git = "Git worktree"
        var id: String { rawValue }
    }

    @State private var name: String = ""
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
                TextField("Name", text: $name)
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
                    let projectId = projectId
                    Task {
                        await store.dispatch(.createWorktree(
                            projectId: projectId,
                            name: name.isEmpty ? "untitled" : name,
                            kind: worktreeKind,
                            path: pathURL
                        ))
                        guard let project = store.state.projects.first(where: { $0.id == projectId }),
                              let worktree = project.worktrees.last else {
                            isPresented = false
                            return
                        }
                        let wtPath = WorktreePath(
                            project: projectId, worktree: worktree.id
                        )
                        if wantShell {
                            let spec = ProcessSpec(
                                command: "/bin/zsh",
                                args: ["-l"],
                                env: [:],
                                cwd: pathURL,
                                pid: nil,
                                initialInput: nil, restartPolicy: .never)
                            await store.dispatch(.createJob(
                                at: wtPath, name: "shell", kind: .shell,
                                primary: spec, auxiliary: []
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
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || (kind == .git && branch.isEmpty))
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
    let jobPath: JobPath
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
        Task {
            await store.dispatch(.renameJob(at: jobPath, name: final))
            isPresented = false
        }
    }
}

struct ResumeClaudeSheet: View {
    let store: Store
    let worktreePath: WorktreePath
    let cwd: URL
    @Binding var isPresented: Bool
    @State private var sessions: [ClaudeHistoryScanner.Session] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resume Claude session").font(.headline)
            Text("Sessions previously run in \(cwd.path)")
                .font(.caption).foregroundStyle(.secondary)
            Group {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if sessions.isEmpty {
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
        .task {
            sessions = ClaudeHistoryScanner.sessions(forCwd: cwd.path)
            loaded = true
        }
    }

    private var sessionList: some View {
        List(sessions, id: \.id) { session in
            Button { resume(session: session) } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.firstUserMessage ?? "(no user prompt yet)")
                        .lineLimit(2)
                    HStack(spacing: 8) {
                        Text(session.id.prefix(8))
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

    private func resume(session: ClaudeHistoryScanner.Session) {
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: session.id)
        Task {
            await store.resetForNewClaudeTask()
            await store.dispatch(.createJob(
                at: worktreePath,
                name: "claude (resumed \(session.id.prefix(6)))",
                kind: .claude(sessionId: session.id),
                primary: spec, auxiliary: []
            ))
            isPresented = false
        }
    }

    private func startFresh() {
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil)
        Task {
            await store.resetForNewClaudeTask()
            await store.dispatch(.createJob(
                at: worktreePath, name: "claude",
                kind: .claude(sessionId: nil),
                primary: spec, auxiliary: []
            ))
            isPresented = false
        }
    }
}

struct NewTaskSheet: View {
    let store: Store
    let worktreePath: WorktreePath
    let cwd: URL
    @Binding var isPresented: Bool

    enum Kind: String, CaseIterable, Identifiable {
        case shell = "Shell"
        case claude = "Claude"
        var id: String { rawValue }
    }

    struct AuxRow: Identifiable {
        let id = UUID()
        var command: String
        var argsString: String
        var restartPolicy: RestartPolicy
    }

    @State private var name: String = ""
    @State private var kind: Kind = .shell
    @State private var command: String = "/bin/zsh"
    @State private var argsString: String = "-l"
    @State private var aux: [AuxRow] = []

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
                    // Claude jobs always spawn /bin/zsh -l + injected `claude\r`
                    // (ADR-015). Showing/editing the command field would lie —
                    // ClaudeTaskSpec.make ignores the form values.
                    Text("Spawned via /bin/zsh -l with `claude` injected at the prompt.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if kind == .shell {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Auxiliary processes")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("+ Add") {
                            aux.append(AuxRow(
                                command: "", argsString: "", restartPolicy: .never
                            ))
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    ForEach($aux) { $row in
                        HStack {
                            TextField("command", text: $row.command)
                                .textFieldStyle(.roundedBorder)
                            TextField("args", text: $row.argsString)
                                .textFieldStyle(.roundedBorder)
                            Picker("", selection: $row.restartPolicy) {
                                Text("no restart").tag(RestartPolicy.never)
                                Text("always restart").tag(RestartPolicy.alwaysRestart)
                            }
                            .pickerStyle(.menu)
                            .frame(width: 130)
                            Button {
                                aux.removeAll { $0.id == row.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let args = argsString
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    let spec: ProcessSpec = (kind == .claude)
                        ? ClaudeTaskSpec.make(cwd: cwd, sessionId: nil)
                        : ProcessSpec(
                            command: command, args: args,
                            env: [:], cwd: cwd, pid: nil,
                            initialInput: nil, restartPolicy: .never)
                    let auxSpecs: [ProcessSpec] = (kind == .claude)
                        ? []
                        : aux.compactMap { row in
                            guard !row.command.isEmpty else { return nil }
                            let auxArgs = row.argsString
                                .split(whereSeparator: { $0.isWhitespace })
                                .map(String.init)
                            return ProcessSpec(
                                command: row.command, args: auxArgs,
                                env: [:], cwd: cwd, pid: nil,
                                initialInput: nil,
                                restartPolicy: row.restartPolicy
                            )
                        }
                    let jobKind: JobKind = (kind == .claude)
                        ? .claude(sessionId: nil)
                        : .shell
                    let jobName = name.isEmpty ? kind.rawValue.lowercased() : name
                    let isClaude = (kind == .claude)
                    Task {
                        if isClaude { await store.resetForNewClaudeTask() }
                        await store.dispatch(.createJob(
                            at: worktreePath,
                            name: jobName,
                            kind: jobKind,
                            primary: spec,
                            auxiliary: auxSpecs
                        ))
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
