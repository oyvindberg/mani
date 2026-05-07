import SwiftUI
import ManiCore
import Foundation

// Minimal v0.1 creation dialogs. Color picking, swatch palette, branch
// dropdown for git worktrees, etc. come later — see docs/ui.md.

struct NewProjectSheet: View {
    let store: Store
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var rootDir: String = NSHomeDirectory()
    @State private var color: String = ColorPalette.swatches.first ?? "#e74c3c"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project").font(.headline)
            Form {
                TextField("Name", text: $name)
                HStack {
                    TextField("Root directory", text: $rootDir)
                    Button("Choose…") { pickFolder() }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Color").font(.caption).foregroundStyle(.secondary)
                ColorSwatchPicker(hex: $color)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        await store.dispatch(.createProject(
                            name: name.isEmpty ? "untitled" : name,
                            color: color,
                            rootDir: URL(fileURLWithPath: rootDir)
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
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let worktreeKind: WorktreeKind = (kind == .git)
                        ? .git(branch: branch.isEmpty ? "main" : branch,
                               baseRef: baseRef.isEmpty ? nil : baseRef)
                        : .folder
                    Task {
                        await store.dispatch(.createWorktree(
                            projectId: projectId,
                            name: name.isEmpty ? "untitled" : name,
                            kind: worktreeKind,
                            path: URL(fileURLWithPath: path)
                        ))
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
                    command = "/usr/bin/env"
                    argsString = "claude"
                    if name.isEmpty || name == "shell" { name = "claude" }
                }
            }
            Form {
                TextField("Name", text: $name)
                TextField("Command", text: $command)
                TextField("Args (space-separated)", text: $argsString)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    let args = argsString
                        .split(whereSeparator: { $0.isWhitespace })
                        .map(String.init)
                    let spec = ProcessSpec(
                        command: command,
                        args: args,
                        env: [:],
                        cwd: cwd,
                        pid: nil
                    )
                    let jobKind: JobKind = (kind == .claude)
                        ? .claude(sessionId: nil)
                        : .shell
                    let jobName = name.isEmpty ? kind.rawValue.lowercased() : name
                    Task {
                        await store.dispatch(.createJob(
                            at: worktreePath,
                            name: jobName,
                            kind: jobKind,
                            primary: spec,
                            auxiliary: []
                        ))
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty || command.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
