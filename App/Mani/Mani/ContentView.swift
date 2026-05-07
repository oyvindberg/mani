import SwiftUI
import AppKit
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
            if let path = selectedJobPath, let context = breadcrumbContext() {
                VStack(spacing: 0) {
                    Rectangle()
                        .fill(SwiftUI.Color(hex: context.project.color))
                        .frame(height: 7)
                    HStack(spacing: 4) {
                        Text(context.project.name)
                            .foregroundStyle(SwiftUI.Color(hex: context.project.color))
                        Text("›").foregroundStyle(.secondary)
                        Text(context.worktree.name)
                            .foregroundStyle(SwiftUI.Color(hex: context.project.color))
                        Text("›").foregroundStyle(.secondary)
                        Text(context.job.name).bold()
                            .foregroundStyle(SwiftUI.Color(hex: context.project.color))
                        Spacer()
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    Divider()
                    if isExternalClaudeJob(context.job) {
                        ExternalClaudeView(job: context.job)
                    } else if context.job.primary.pid == nil {
                        StoppedJobView(job: context.job, jobPath: path)
                    } else {
                        TerminalPane(jobPath: path)
                            .id(path)
                    }
                }
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
        .onChange(of: selectedJobId) { _, newId in
            guard let newId, let path = lookupPath(forJobId: newId) else { return }
            Task { await store.dispatch(.markRead(at: path)) }
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

    // External = job created via discoverClaudeSession, i.e. claude is running
    // outside Mani. We can observe its JSONL but can't restart it.
    private func isExternalClaudeJob(_ job: Job) -> Bool {
        if case let .claude(sid) = job.kind, sid != nil,
           job.primary.command == "(external claude)" {
            return true
        }
        return false
    }

    private func breadcrumbContext() -> (project: Project, worktree: Worktree, job: Job)? {
        guard let path = selectedJobPath,
              let project = store.state.projects.first(where: { $0.id == path.project }),
              let worktree = project.worktrees.first(where: { $0.id == path.worktree }),
              let job = worktree.jobs.first(where: { $0.id == path.job })
        else { return nil }
        return (project, worktree, job)
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
    @EnvironmentObject var watcher: ClaudeWatcher
    @EnvironmentObject var hookListener: HookListenerService
    @Binding var selectedJobId: UUID?

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selectedJobId) {
                ForEach(store.state.projects) { project in
                    Section {
                        ForEach(project.worktrees) { worktree in
                            worktreeHeader(project: project, worktree: worktree)
                            ForEach(worktree.jobs) { job in
                                jobRow(project: project, worktree: worktree, job: job)
                                    .tag(job.id)
                            }
                        }
                    } header: {
                        Text(project.name)
                            .opacity(project.enabled ? 1 : 0.5)
                            .contextMenu {
                                projectMenu(project: project)
                            }
                    }
                }
            }
            .listStyle(.sidebar)
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                statusRow(icon: "eye", text: "\(watcher.sessions.count) Claude sessions tracked")
                statusRow(icon: "antenna.radiowaves.left.and.right", text: "\(hookListener.receivedCount) hook envelopes")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func projectMenu(project: Project) -> some View {
        Button(project.enabled ? "Disable project (stop all tasks)" : "Enable project") {
            Task {
                await store.dispatch(.setProjectEnabled(id: project.id, enabled: !project.enabled))
            }
        }
        Divider()
        Button("Delete project", role: .destructive) {
            Task { await store.dispatch(.deleteProject(id: project.id)) }
        }
    }

    @ViewBuilder
    private func worktreeMenu(project: Project, worktree: Worktree) -> some View {
        let path = WorktreePath(project: project.id, worktree: worktree.id)
        Button(worktree.enabled ? "Disable worktree (stop tasks)" : "Enable worktree") {
            Task {
                await store.dispatch(.setWorktreeEnabled(at: path, enabled: !worktree.enabled))
            }
        }
        Divider()
        Button("Delete worktree", role: .destructive) {
            Task { await store.dispatch(.deleteWorktree(at: path)) }
        }
    }

    @ViewBuilder
    private func jobMenu(project: Project, worktree: Worktree, job: Job) -> some View {
        let path = JobPath(project: project.id, worktree: worktree.id, job: job.id)
        Button(job.enabled ? "Stop task" : "Re-enable") {
            Task {
                await store.dispatch(.setJobEnabled(at: path, enabled: !job.enabled))
            }
        }
        Button("Mark complete") {
            Task { await store.dispatch(.completeJob(at: path)) }
        }
        Divider()
        Button("Delete task (also stops it)", role: .destructive) {
            Task {
                await store.dispatch(.setJobEnabled(at: path, enabled: false))
            }
        }
    }

    private func statusRow(icon: String, text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func worktreeHeader(project: Project, worktree: Worktree) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
            Text(worktree.name)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.leading, 6)
                .padding(.top, 4)
                .opacity(worktree.enabled ? 1 : 0.5)
        }
        .contextMenu { worktreeMenu(project: project, worktree: worktree) }
    }

    private func jobRow(project: Project, worktree: Worktree, job: Job) -> some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
            HStack(spacing: 6) {
                Image(systemName: job.statusSymbol)
                    .foregroundStyle(job.statusColor)
                    .font(.system(size: 9))
                Text(job.name)
                    .strikethrough(!job.enabled)
                Spacer()
                if job.unread > 0 {
                    Text("\(job.unread)")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .background(Capsule().fill(.tint))
                        .foregroundStyle(.white)
                }
            }
            .padding(.leading, 8)
            .opacity(job.enabled ? 1 : 0.5)
        }
        .contentShape(Rectangle())
        .contextMenu { jobMenu(project: project, worktree: worktree, job: job) }
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

    // ADR-009: status indication uses both color AND a glyph so users with
    // red/green colorblindness can distinguish without relying on hue alone.
    var statusSymbol: String {
        switch status {
        case .running: return "circle.fill"
        case .idle: return "pause.circle.fill"
        case .stopped: return "stop.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }
}

private struct ExternalClaudeView: View {
    let job: Job
    @EnvironmentObject var watcher: ClaudeWatcher

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("External Claude session")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                if case let .claude(sid) = job.kind, let sid {
                    labelled("Session", sid)
                    if let detected = watcher.sessions[sid] {
                        if let cwd = detected.cwd { labelled("cwd", cwd) }
                        labelled("messages", "\(detected.messageCount)")
                        labelled("transcript", detected.path)
                    }
                }
            }
            .font(.system(.caption, design: .monospaced))
            .frame(maxWidth: 540, alignment: .leading)
            Text("This claude was started outside Mani. Mani is watching its\ntranscript on disk; it can't restart or attach a renderer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func labelled(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .textSelection(.enabled)
        }
    }
}

private struct StoppedJobView: View {
    let job: Job
    let jobPath: JobPath
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: job.statusSymbol)
                .font(.system(size: 36))
                .foregroundStyle(job.statusColor)
            Text("Process not running")
                .font(.headline)
            Text(displayCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 600)
            Button("Restart") {
                let runner = store.runner
                let spec = job.primary
                let path = jobPath
                Task {
                    await runner.run(
                        .spawn(at: path, index: 0, spec),
                        dispatch: { action in await store.dispatch(action) }
                    )
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayCommand: String {
        ([job.primary.command] + job.primary.args).joined(separator: " ")
    }
}

private struct TerminalPane: NSViewRepresentable {
    let jobPath: JobPath
    @EnvironmentObject var store: Store

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let renderer: TerminalRenderer = SwiftTermRenderer()
        context.coordinator.attach(renderer: renderer, store: store, jobPath: jobPath)
        // Steal first-responder so the user can type immediately on
        // navigate-here. Without this, keystrokes go to the navigation split
        // view (which ignores them) until the user clicks the terminal.
        DispatchQueue.main.async { [weak view = renderer.view] in
            view?.window?.makeFirstResponder(view)
        }
        return renderer.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Coordinator {
        private var renderer: TerminalRenderer?
        private weak var pty: ManagedPTY?
        private var outputSub: ManagedPTY.OutputSubscription?

        func attach(renderer: TerminalRenderer, store: Store, jobPath: JobPath) {
            self.renderer = renderer
            renderer.inputHandler = { [weak self] data in self?.pty?.write(data) }
            renderer.sizeHandler = { [weak self] rows, cols in
                self?.pty?.resize(rows: UInt16(rows), cols: UInt16(cols))
            }

            let runner = store.runner
            Task {
                for _ in 0..<200 {
                    if let pty = await runner.pty(for: jobPath) {
                        await MainActor.run { self.bind(pty: pty) }
                        return
                    }
                    try? await Task.sleep(nanoseconds: 25_000_000)
                }
            }
        }

        private func bind(pty: ManagedPTY) {
            self.pty = pty
            outputSub = pty.addOutputHandler { [weak self] chunk in
                DispatchQueue.main.async { self?.renderer?.feed(chunk) }
            }
            pty.resize(rows: 40, cols: 120)
        }
    }
}
