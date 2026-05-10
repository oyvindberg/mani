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
                        ExternalClaudeView(
                            job: context.job,
                            jobPath: path,
                            worktreePath: WorktreePath(
                                project: path.project, worktree: path.worktree
                            )
                        )
                    } else if context.job.primary.pid == nil {
                        StoppedJobView(job: context.job, jobPath: path)
                    } else {
                        TerminalPane(jobPath: path)
                            .id(path)
                    }
                }
            } else {
                if store.state.projects.isEmpty {
                    VStack(spacing: 14) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Create your first project")
                            .font(.headline)
                        Button("New Project…") { showingNewProject = true }
                            .keyboardShortcut("p", modifiers: [.command, .shift])
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text("Select a task in the sidebar")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
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
    @State private var resumeContext: ResumeContext?
    @State private var renameContext: RenameContext?

    struct ResumeContext: Identifiable {
        let id = UUID()
        let worktreePath: WorktreePath
        let cwd: URL
    }

    struct RenameContext: Identifiable {
        let id = UUID()
        let jobPath: JobPath
        let currentName: String
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
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
                if store.state.projects.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No projects yet")
                            .font(.headline)
                        Text("Use the + button in the toolbar\nto create your first project.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                    .allowsHitTesting(false)
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                statusRow(icon: "eye", text: "\(watcher.sessions.count) Claude sessions tracked")
                statusRow(icon: "antenna.radiowaves.left.and.right", text: "\(hookListener.receivedCount) hook envelopes")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
        .sheet(item: $resumeContext) { ctx in
            ResumeClaudeSheet(
                store: store,
                worktreePath: ctx.worktreePath,
                cwd: ctx.cwd,
                isPresented: Binding(
                    get: { resumeContext != nil },
                    set: { if !$0 { resumeContext = nil } }
                )
            )
        }
        .sheet(item: $renameContext) { ctx in
            RenameJobSheet(
                store: store,
                jobPath: ctx.jobPath,
                currentName: ctx.currentName,
                isPresented: Binding(
                    get: { renameContext != nil },
                    set: { if !$0 { renameContext = nil } }
                )
            )
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
        Button("New shell here") {
            Task { await Self.spawnShell(at: path, cwd: worktree.path, store: store) }
        }
        Button("New Claude task") {
            Task { await Self.spawnClaude(at: path, cwd: worktree.path, store: store) }
        }
        Button("Resume Claude session…") {
            resumeContext = ResumeContext(worktreePath: path, cwd: worktree.path)
        }
        Button("Open in IntelliJ") {
            Self.openInIntelliJ(worktree.path)
        }
        Divider()
        Button(worktree.enabled ? "Disable worktree (stop tasks)" : "Enable worktree") {
            Task {
                await store.dispatch(.setWorktreeEnabled(at: path, enabled: !worktree.enabled))
            }
        }
        Button("Delete worktree", role: .destructive) {
            Task { await store.dispatch(.deleteWorktree(at: path)) }
        }
    }

    private static func spawnShell(at path: WorktreePath, cwd: URL, store: Store) async {
        let spec = ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:], cwd: cwd, pid: nil,
            initialInput: nil, restartPolicy: .never)
        await store.dispatch(.createJob(
            at: path, name: "shell", kind: .shell, primary: spec, auxiliary: []
        ))
    }

    private static func spawnClaude(at path: WorktreePath, cwd: URL, store: Store) async {
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil)
        await store.resetForNewClaudeTask()
        await store.dispatch(.createJob(
            at: path, name: "claude", kind: .claude(sessionId: nil),
            primary: spec, auxiliary: []
        ))
    }

    private static func openInIntelliJ(_ folder: URL) {
        // Prefer JetBrains' `idea` CLI if it's on the augmented PATH; otherwise
        // fall back to Launch Services (`open -a "IntelliJ IDEA"`).
        let extras = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin"
        let pathString = extras + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "")
        let ideaPath = pathString.split(separator: ":").lazy
            .map { String($0) + "/idea" }
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })

        let task = Process()
        if let ideaPath {
            task.executableURL = URL(fileURLWithPath: ideaPath)
            task.arguments = [folder.path]
        } else {
            task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            task.arguments = ["-a", "IntelliJ IDEA", folder.path]
        }
        try? task.run()
    }

    private func adoptExternalClaude(
        jobPath: JobPath,
        worktreePath: WorktreePath,
        sessionId: String,
        cwd: URL,
        currentName: String,
        wasRenamed: Bool
    ) {
        let preservedName = wasRenamed
            ? currentName
            : "claude (adopted \(sessionId.prefix(6)))"
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sessionId)
        Task {
            await store.dispatch(.deleteJob(at: jobPath))
            await store.dispatch(.createJob(
                at: worktreePath,
                name: preservedName,
                kind: .claude(sessionId: sessionId),
                primary: spec,
                auxiliary: []
            ))
            if wasRenamed,
               let newJob = store.state.projects
                    .first(where: { $0.id == worktreePath.project })?
                    .worktrees.first(where: { $0.id == worktreePath.worktree })?
                    .jobs.first(where: {
                        if case let .claude(s) = $0.kind, s == sessionId { return true }
                        return false
                    }) {
                let newPath = JobPath(
                    project: worktreePath.project,
                    worktree: worktreePath.worktree,
                    job: newJob.id
                )
                await store.dispatch(.renameJob(at: newPath, name: preservedName))
            }
        }
    }

    @ViewBuilder
    private func jobMenu(project: Project, worktree: Worktree, job: Job) -> some View {
        let path = JobPath(project: project.id, worktree: worktree.id, job: job.id)
        Button("Rename…") {
            renameContext = RenameContext(jobPath: path, currentName: job.name)
        }
        Divider()
        Button(job.enabled ? "Stop task" : "Re-enable") {
            Task {
                await store.dispatch(.setJobEnabled(at: path, enabled: !job.enabled))
            }
        }
        Button("Mark complete") {
            Task { await store.dispatch(.completeJob(at: path)) }
        }
        if case .claude = job.kind, job.primary.pid != nil {
            Divider()
            Button("Fork conversation") {
                let runner = store.runner
                Task {
                    // Type `/fork\r` into the live PTY. claude executes the
                    // slash command and (per claude-code's hook contract)
                    // fires SessionStart for the new session id — the
                    // routing function in ManiCore catches that and creates
                    // a sibling Job via discoverClaudeSession. See ADR-016.
                    guard let pty = await runner.pty(for: path) else { return }
                    pty.write(Data("/fork\r".utf8))
                }
            }
        }
        if case let .claude(sid) = job.kind, let sid,
           job.primary.command == "(external claude)" {
            Divider()
            Button("Adopt into Mani") {
                adoptExternalClaude(jobPath: path, worktreePath: WorktreePath(
                    project: project.id, worktree: worktree.id
                ), sessionId: sid, cwd: job.primary.cwd, currentName: job.name,
                   wasRenamed: job.renamed)
            }
        }
        Divider()
        Button("Delete task", role: .destructive) {
            Task {
                await store.dispatch(.deleteJob(at: path))
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
                Image(systemName: job.kindSymbol)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11))
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

    // Per-kind icon shown alongside the (user-editable) name in the sidebar.
    // The name is freely renameable; the icon keeps the kind legible at a
    // glance even when names diverge from the default "shell"/"claude".
    var kindSymbol: String {
        switch kind {
        case .shell: return "terminal"
        case .claude: return "sparkle"
        case .custom: return "puzzlepiece.extension"
        }
    }
}

private struct ExternalClaudeView: View {
    let job: Job
    let jobPath: JobPath
    let worktreePath: WorktreePath
    @EnvironmentObject var store: Store
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
            if appearsActive {
                Text("⚠︎ This session looks active (a message arrived in the last minute). Close the external claude first — two processes resuming the same session id will conflict.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 540)
            }
            Button("Adopt into Mani") { adopt() }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var appearsActive: Bool {
        guard case let .claude(sid) = job.kind, let sid,
              let detected = watcher.sessions[sid],
              let last = detected.lastMessageAt
        else { return false }
        return Date().timeIntervalSince(last) < 60
    }

    private func adopt() {
        guard case let .claude(sid) = job.kind, let sid else { return }
        let cwd = job.primary.cwd
        let preservedName = job.renamed ? job.name : "claude (adopted \(sid.prefix(6)))"
        let preservedRenamed = job.renamed
        let oldPath = jobPath
        let wt = worktreePath
        Task {
            // Order matters: delete the external first so the new Job's
            // .claude(sid) doesn't trip the global uniqueness check.
            await store.dispatch(.deleteJob(at: oldPath))
            let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sid)
            await store.dispatch(.createJob(
                at: wt,
                name: preservedName,
                kind: .claude(sessionId: sid),
                primary: spec,
                auxiliary: []
            ))
            if preservedRenamed,
               let newJob = store.state.projects
                    .first(where: { $0.id == wt.project })?
                    .worktrees.first(where: { $0.id == wt.worktree })?
                    .jobs.first(where: {
                        if case let .claude(s) = $0.kind, s == sid { return true }
                        return false
                    }) {
                let newPath = JobPath(
                    project: wt.project, worktree: wt.worktree, job: newJob.id
                )
                await store.dispatch(.renameJob(at: newPath, name: preservedName))
            }
        }
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
                // Claude jobs always rebuild via ClaudeTaskSpec — never reuse
                // job.primary, since that may be a stale pre-zsh-injection spec
                // persisted from an earlier Mani build.
                let runner = store.runner
                let spec = ClaudeTaskSpec.restartSpec(for: job)
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
        // libghostty-backed renderer (per ADR-002 v0.2 swap). To fall back to
        // SwiftTerm during a regression hunt, replace with `SwiftTermRenderer()`.
        let renderer: TerminalRenderer = LibGhosttyRenderer(
            themeName: store.state.settings.terminalTheme,
            fontFamily: store.state.settings.terminalFontFamily,
            fontSize: store.state.settings.terminalFontSize
        )
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
