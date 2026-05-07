import SwiftUI
import SwiftTerm
import Foundation
import ManiCore

struct ContentView: View {
    @EnvironmentObject var store: Store
    @State private var selectedJobId: UUID?
    @State private var showingNewProject = false
    @State private var showingNewWorktree = false
    @State private var showingNewTask = false

    var body: some View {
        NavigationSplitView {
            SidebarView(selectedJobId: $selectedJobId)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 400)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New Project…") { showingNewProject = true }
                                .keyboardShortcut("p", modifiers: [.command, .shift])
                            Button("New Worktree…") { showingNewWorktree = true }
                                .keyboardShortcut("n", modifiers: [.command, .shift])
                                .disabled(currentProject() == nil)
                            Button("New Task…") { showingNewTask = true }
                                .keyboardShortcut("t", modifiers: [.command])
                                .disabled(currentWorktreePath() == nil)
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                }
        } detail: {
            if let path = selectedJobPath {
                TerminalPane(jobPath: path)
                    .id(path)
            } else {
                Text("Select a task in the sidebar")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selectedJobId == nil { selectedJobId = firstJobId() }
        }
        .onChange(of: store.state.projects.map(\.id)) { _, _ in
            if let id = selectedJobId, lookupPath(forJobId: id) == nil {
                selectedJobId = firstJobId()
            } else if selectedJobId == nil {
                selectedJobId = firstJobId()
            }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(store: store, isPresented: $showingNewProject)
        }
        .sheet(isPresented: $showingNewWorktree) {
            if let project = currentProject() {
                NewWorktreeSheet(
                    store: store,
                    projectId: project.id,
                    isPresented: $showingNewWorktree
                )
            }
        }
        .sheet(isPresented: $showingNewTask) {
            if let path = currentWorktreePath(), let cwd = currentWorktreeCwd() {
                NewTaskSheet(
                    store: store,
                    worktreePath: path,
                    cwd: cwd,
                    isPresented: $showingNewTask
                )
            }
        }
    }

    private func currentProject() -> Project? {
        if let path = selectedJobPath {
            return store.state.projects.first { $0.id == path.project }
        }
        return store.state.projects.first
    }

    private func currentWorktreePath() -> WorktreePath? {
        if let path = selectedJobPath {
            return path.worktreePath
        }
        guard let project = store.state.projects.first,
              let worktree = project.worktrees.first
        else { return nil }
        return WorktreePath(project: project.id, worktree: worktree.id)
    }

    private func currentWorktreeCwd() -> URL? {
        currentWorktree()?.path
    }

    private func currentWorktree() -> Worktree? {
        guard let path = currentWorktreePath() else { return nil }
        return store.state.projects.first(where: { $0.id == path.project })?
            .worktrees.first(where: { $0.id == path.worktree })
    }

    private var selectedJobPath: JobPath? {
        guard let id = selectedJobId else { return nil }
        return lookupPath(forJobId: id)
    }

    private func firstJobId() -> UUID? {
        store.state.projects.first?.worktrees.first?.jobs.first?.id
    }

    private func lookupPath(forJobId jobId: UUID) -> JobPath? {
        for project in store.state.projects {
            for worktree in project.worktrees {
                if worktree.jobs.contains(where: { $0.id == jobId }) {
                    return JobPath(project: project.id, worktree: worktree.id, job: jobId)
                }
            }
        }
        return nil
    }
}

private struct SidebarView: View {
    @EnvironmentObject var store: Store
    @Binding var selectedJobId: UUID?

    var body: some View {
        List(selection: $selectedJobId) {
            ForEach(store.state.projects) { project in
                Section {
                    ForEach(project.worktrees) { worktree in
                        Text(worktree.name)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.top, 4)
                        ForEach(worktree.jobs) { job in
                            jobRow(job: job)
                                .tag(job.id)
                        }
                    }
                } header: {
                    Text(project.name)
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func jobRow(job: Job) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(job.statusColor)
                .frame(width: 6, height: 6)
            Text(job.name)
            Spacer()
            if job.unread > 0 {
                Text("\(job.unread)")
                    .font(.caption2)
                    .padding(.horizontal, 5)
                    .background(Capsule().fill(.tint))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
        .padding(.leading, 8)
    }
}

private extension WorktreeKind {
    var symbol: String {
        switch self {
        case .git: return "arrow.triangle.branch"
        case .folder: return "folder"
        }
    }
}

private extension Job {
    var statusColor: SwiftUI.Color {
        switch status {
        case .running: return .green
        case .idle: return .yellow
        case .stopped: return .gray
        case .completed: return .blue
        case .failed: return .red
        }
    }
}

private struct TerminalPane: NSViewRepresentable {
    let jobPath: JobPath
    @EnvironmentObject var store: Store

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        let runner = store.runner
        let path = jobPath
        let coord = context.coordinator
        Task {
            for _ in 0..<200 {
                if let pty = await runner.pty(for: path) {
                    coord.attach(view: view, pty: pty)
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)
            }
            await MainActor.run { view.feed(text: "[no PTY for \(path) after 5s]\r\n") }
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var pty: ManagedPTY?

        func attach(view: TerminalView, pty: ManagedPTY) {
            self.pty = pty
            pty.onOutput = { [weak view] chunk in
                let bytes = Array(chunk)
                DispatchQueue.main.async {
                    view?.feed(byteArray: bytes[...])
                }
            }
            pty.resize(rows: 40, cols: 120)
        }

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty?.write(Data(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            pty?.resize(rows: UInt16(newRows), cols: UInt16(newCols))
        }
        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
        func scrolled(source: TerminalView, position: Double) {}
        func clipboardCopy(source: TerminalView, content: Data) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
        func bell(source: TerminalView) {}
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
