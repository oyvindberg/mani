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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New project").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Root directory", text: $rootDir)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        await store.dispatch(.createProject(
                            name: name.isEmpty ? "untitled" : name,
                            color: "#6699cc",
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
        .frame(width: 380)
    }
}

struct NewWorktreeSheet: View {
    let store: Store
    let projectId: UUID
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var path: String = NSHomeDirectory()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New worktree").font(.headline)
            Form {
                TextField("Name", text: $name)
                TextField("Path", text: $path)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task {
                        await store.dispatch(.createWorktree(
                            projectId: projectId,
                            name: name.isEmpty ? "untitled" : name,
                            kind: .folder,
                            path: URL(fileURLWithPath: path)
                        ))
                        isPresented = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}

struct NewTaskSheet: View {
    let store: Store
    let worktreePath: WorktreePath
    let cwd: URL
    @Binding var isPresented: Bool
    @State private var name: String = ""
    @State private var command: String = "/bin/zsh"
    @State private var argsString: String = "-l"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New task").font(.headline)
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
                    Task {
                        await store.dispatch(.createJob(
                            at: worktreePath,
                            name: name.isEmpty ? "task" : name,
                            kind: .shell,
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
