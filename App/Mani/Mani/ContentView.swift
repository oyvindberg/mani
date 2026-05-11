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
    @State private var showingSearch = false

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
                        // Search scrollback. Only meaningful for jobs whose
                        // PTY writes a scrollback log — the diff workspace
                        // does too, and search there is occasionally handy
                        // (find a previous diff command), so we don't gate
                        // on kind.
                        Button {
                            showingSearch = true
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .keyboardShortcut("f", modifiers: [.command])
                        .help("Search scrollback (⌘F)")
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
                    } else if case .diff = context.job.kind {
                        DiffWorkspaceView(
                            job: context.job,
                            jobPath: path,
                            worktreePath: context.worktree.path
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
        .sheet(isPresented: $showingSearch) {
            ScrollbackSearchSheet(
                sources: allScrollbackSources(),
                isPresented: $showingSearch,
                onSelectMatch: { jobPath, lineNumber in
                    selectedJobId = jobPath.job
                    // The renderer rebuilds on selection change; let it
                    // mount before scrolling. 200 ms is conservative.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        TerminalRendererCache.shared
                            .rendererIfPresent(for: jobPath)?
                            .scrollToLine(fromTop: lineNumber)
                    }
                }
            )
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

    private func scrollbackPath(for jobId: UUID) -> String {
        // Matches EffectRunner's scrollback layout:
        //   ~/Library/Application Support/Mani/tasks/<job-uuid>/scrollback.log
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return root
            .appendingPathComponent("Mani/tasks")
            .appendingPathComponent(jobId.uuidString)
            .appendingPathComponent("scrollback.log").path
    }

    // Every job in state becomes a search source, labeled with its
    // project › worktree › name breadcrumb. The currently-selected job
    // is sorted to the top so its scrollback is the first thing
    // ScrollbackSearchSheet scans (results stay roughly in order of
    // relevance for "I just saw this thing scroll past").
    private func allScrollbackSources() -> [ScrollbackSearchSheet.Source] {
        var sources: [ScrollbackSearchSheet.Source] = []
        let selectedId = selectedJobId
        var selectedSource: ScrollbackSearchSheet.Source?
        for project in store.state.projects {
            for worktree in project.worktrees {
                for job in worktree.jobs {
                    let label = "\(project.name) › \(worktree.name) › \(job.name)"
                    let src = ScrollbackSearchSheet.Source(
                        label: label,
                        jobPath: JobPath(
                            project: project.id,
                            worktree: worktree.id,
                            job: job.id
                        ),
                        scrollbackPath: scrollbackPath(for: job.id)
                    )
                    if job.id == selectedId {
                        selectedSource = src
                    } else {
                        sources.append(src)
                    }
                }
            }
        }
        if let selectedSource { sources.insert(selectedSource, at: 0) }
        return sources
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

struct SidebarView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var watcher: ClaudeWatcher
    @EnvironmentObject var hookListener: HookListenerService
    @Binding var selectedJobId: UUID?
    @State private var resumeContext: ResumeContext?
    @State private var renameContext: RenameContext?
    @State private var collapsedProjects: Set<UUID> = []
    @State private var collapsedWorktrees: Set<UUID> = []
    @State private var expandedPastSessions: Set<UUID> = []
    @State private var colorPickerProjectId: UUID?
    @State private var newWorktreeForProject: Project?

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
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(store.state.projects.enumerated()), id: \.element.id) { idx, project in
                                projectGroup(project: project)
                                if idx < store.state.projects.count - 1 {
                                    Divider()
                                        .padding(.vertical, 4)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                    }
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
        .sheet(item: Binding(
            get: { colorPickerProjectId.flatMap { id in
                store.state.projects.first(where: { $0.id == id })
            } },
            set: { if $0 == nil { colorPickerProjectId = nil } }
        )) { project in
            ProjectColorSheet(
                store: store,
                project: project,
                isPresented: Binding(
                    get: { colorPickerProjectId != nil },
                    set: { if !$0 { colorPickerProjectId = nil } }
                )
            )
        }
        .sheet(item: $newWorktreeForProject) { project in
            NewWorktreeSheet(
                store: store,
                projectId: project.id,
                isPresented: Binding(
                    get: { newWorktreeForProject != nil },
                    set: { if !$0 { newWorktreeForProject = nil } }
                )
            )
        }
    }

    @ViewBuilder
    private func projectMenu(project: Project) -> some View {
        Button("Add worktree…") {
            newWorktreeForProject = project
        }
        Button("Change color…") {
            colorPickerProjectId = project.id
        }
        Divider()
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
        if !worktree.primary {
            Button("Make primary") {
                Task { await store.dispatch(.setWorktreePrimary(at: path)) }
            }
        }
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

    static func spawnDiff(at path: WorktreePath, cwd: URL, store: Store) async {
        // The diff workspace is backed by a long-lived /bin/zsh -l. The view
        // writes delta pipelines into the PTY when the user selects a file —
        // no respawn per click. See DiffWorkspaceView. Called on launch by
        // ManiApp.ensureDiffJobsForGitWorktrees for every .git worktree that
        // doesn't already have one, so the workspace is a fixture of the
        // worktree rather than something the user has to spawn.
        let spec = ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:], cwd: cwd, pid: nil,
            initialInput: nil, restartPolicy: .never
        )
        await store.dispatch(.createJob(
            at: path, name: "diff", kind: .diff,
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

    @ViewBuilder
    private func projectGroup(project: Project) -> some View {
        let visibleJobs = project.worktrees.flatMap { $0.jobs }.filter { job in
            if case .diff = job.kind { return false }
            return true
        }
        let projectExpanded = !collapsedProjects.contains(project.id)
        ProjectHeaderRow(
            project: project,
            isExpanded: projectExpanded,
            jobCount: visibleJobs.count
        ) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if projectExpanded { collapsedProjects.insert(project.id) }
                else { collapsedProjects.remove(project.id) }
            }
        } onContextMenu: {
            AnyView(projectMenu(project: project))
        }
        if projectExpanded {
            ForEach(project.worktrees) { worktree in
                worktreeGroup(project: project, worktree: worktree)
            }
        }
    }

    @ViewBuilder
    private func worktreeGroup(project: Project, worktree: Worktree) -> some View {
        let diffJobId = worktree.jobs.first(where: {
            if case .diff = $0.kind { return true }
            return false
        })?.id
        let worktreeExpanded = !collapsedWorktrees.contains(worktree.id)
        let visibleJobs = worktree.jobs.filter { job in
            if case .diff = job.kind { return false }
            return true
        }
        let wtPath = WorktreePath(project: project.id, worktree: worktree.id)
        WorktreeHeaderRow(
            project: project,
            worktree: worktree,
            isExpanded: worktreeExpanded,
            diffJobId: diffJobId,
            selectedJobId: selectedJobId
        ) {
            withAnimation(.easeInOut(duration: 0.15)) {
                if worktreeExpanded { collapsedWorktrees.insert(worktree.id) }
                else { collapsedWorktrees.remove(worktree.id) }
            }
        } onSelectDiff: {
            if let diffJobId { selectedJobId = diffJobId }
        } onNewShell: {
            Task { await Self.spawnShell(at: wtPath, cwd: worktree.path, store: store) }
        } onNewClaude: {
            Task { await Self.spawnClaude(at: wtPath, cwd: worktree.path, store: store) }
        } onContextMenu: {
            AnyView(worktreeMenu(project: project, worktree: worktree))
        }
        if worktreeExpanded {
            let (managed, externals) = partitionVisibleJobs(visibleJobs)
            ForEach(managed) { job in
                JobRow(
                    project: project,
                    job: job,
                    selected: selectedJobId == job.id
                ) {
                    selectedJobId = job.id
                } onContextMenu: {
                    AnyView(jobMenu(project: project, worktree: worktree, job: job))
                }
            }
            if !externals.isEmpty {
                pastSessionsGroup(
                    project: project,
                    worktree: worktree,
                    externals: externals
                )
            }
        }
    }

    // Split jobs into "managed" (Mani-spawned, full-row treatment) and
    // "external" (discovered claude transcripts that go under a compact
    // collapsible). External marker: command is "(external claude)".
    private func partitionVisibleJobs(_ jobs: [Job]) -> ([Job], [Job]) {
        var managed: [Job] = []
        var externals: [Job] = []
        for job in jobs {
            if job.primary.command == "(external claude)" {
                externals.append(job)
            } else {
                managed.append(job)
            }
        }
        return (managed, externals)
    }

    @ViewBuilder
    private func pastSessionsGroup(
        project: Project,
        worktree: Worktree,
        externals: [Job]
    ) -> some View {
        let isExpanded = expandedPastSessions.contains(worktree.id)
        HStack(spacing: 0) {
            Rectangle()
                .fill(SwiftUI.Color(hex: project.color))
                .frame(width: 3)
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Past sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("(\(externals.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.leading, 22)
            .padding(.trailing, 10)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded { expandedPastSessions.remove(worktree.id) }
                else { expandedPastSessions.insert(worktree.id) }
            }
        }
        if isExpanded {
            // Sort externals newest-first by lastMessageAt (from the
            // info cache); fall back to UUID order otherwise.
            let cache = ExternalSessionInfoCache.shared
            let sorted = externals.sorted { a, b in
                let aSid: String? = {
                    if case let .claude(s) = a.kind { return s }
                    return nil
                }()
                let bSid: String? = {
                    if case let .claude(s) = b.kind { return s }
                    return nil
                }()
                let aWhen = aSid.flatMap { cache.entries[$0]?.lastMessageAt }
                    ?? .distantPast
                let bWhen = bSid.flatMap { cache.entries[$0]?.lastMessageAt }
                    ?? .distantPast
                return aWhen > bWhen
            }
            ForEach(sorted) { job in
                PastSessionRow(
                    project: project,
                    job: job,
                    selected: selectedJobId == job.id
                ) {
                    selectedJobId = job.id
                } onContextMenu: {
                    AnyView(jobMenu(project: project, worktree: worktree, job: job))
                }
            }
        }
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

extension Job {
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
        case .diff: return "doc.text.below.ecg"
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

    @State private var loading = true
    @State private var detail: ClaudeHistoryScanner.Session?
    @State private var recent: [ClaudeHistoryScanner.RecentMessage] = []

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                summary
                if !recent.isEmpty {
                    Divider()
                    recentMessagesSection
                }
                if appearsActive {
                    Text("⚠︎ This session looks active (a message arrived in the last minute). Close the external claude first — two processes resuming the same session id will conflict.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(SwiftUI.Color.orange.opacity(0.12))
                        )
                }
                HStack {
                    Spacer()
                    Button("Adopt into Mani") { adopt() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task { await load() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("External Claude session")
                    .font(.title3.weight(.semibold))
                Text("Discovered on disk — Mani isn't running this one. You can adopt it to take over (Mani spawns claude --resume <sid>).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let sid = sessionId { labelled("Session", sid) }
            if let cwd = detail?.cwd ?? watcher.sessions[sessionId ?? ""]?.cwd {
                labelled("cwd", cwd)
            }
            if let count = detail?.messageCount ?? watcher.sessions[sessionId ?? ""]?.messageCount {
                labelled("Messages", "\(count)")
            }
            if let last = detail?.lastMessageAt ?? watcher.sessions[sessionId ?? ""]?.lastMessageAt {
                labelled("Last activity", Self.relativeFormatter.localizedString(
                    for: last, relativeTo: Date()
                ))
            }
            if let first = detail?.firstUserMessage {
                VStack(alignment: .leading, spacing: 3) {
                    Text("First user message")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Text(first)
                        .font(.system(.body, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(SwiftUI.Color.secondary.opacity(0.08))
                        )
                }
                .padding(.top, 6)
            }
            if loading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading transcript…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recentMessagesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recent messages")
                .font(.headline)
            ForEach(recent) { msg in
                HStack(alignment: .top, spacing: 8) {
                    Text(roleBadge(msg.role))
                        .font(.caption2.weight(.bold).monospaced())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(roleColor(msg.role))
                        )
                    Text(msg.text)
                        .font(.system(.body, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(SwiftUI.Color.secondary.opacity(0.06))
                )
            }
        }
    }

    private func roleBadge(_ role: String) -> String {
        switch role {
        case "user": return "YOU"
        case "assistant": return "CLAUDE"
        default: return role.uppercased()
        }
    }

    private func roleColor(_ role: String) -> SwiftUI.Color {
        switch role {
        case "user": return .blue
        case "assistant": return .orange
        default: return .gray
        }
    }

    private var sessionId: String? {
        if case let .claude(s) = job.kind { return s }
        return nil
    }

    private var transcriptURL: URL? {
        guard let sid = sessionId else { return nil }
        // Match ClaudeHistoryScanner's slug convention.
        let cwd = job.primary.cwd.path
        let trimmed = cwd.hasSuffix("/") ? String(cwd.dropLast()) : cwd
        let slug = "-" + trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
            .appendingPathComponent(slug)
            .appendingPathComponent("\(sid).jsonl")
    }

    private func load() async {
        guard let url = transcriptURL else { loading = false; return }
        await Task.detached(priority: .userInitiated) { [url] in
            let result = ClaudeHistoryScanner.detail(jsonl: url, recentLimit: 5)
            await MainActor.run {
                if let result {
                    detail = result.0
                    recent = result.1
                }
                loading = false
            }
        }.value
    }

    private var appearsActive: Bool {
        guard let last = detail?.lastMessageAt
                ?? watcher.sessions[sessionId ?? ""]?.lastMessageAt
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

struct TerminalPane: NSViewRepresentable {
    let jobPath: JobPath
    @EnvironmentObject var store: Store

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // libghostty-backed renderer (per ADR-002 v0.2 swap). Cached per
        // JobPath so tab-switching back doesn't tear down the surface and
        // replay scrollback. The TerminalTheme is generated from the
        // project's color (both a light and a dark variant; libghostty
        // swaps automatically with the system appearance). Cache key
        // includes the color hex so a project re-coloring rebuilds the
        // renderer next time it mounts.
        let projectColor = store.state.projects
            .first(where: { $0.id == jobPath.project })?.color
            ?? "#808080"
        let theme = ProjectThemeGenerator.theme(forProjectColor: projectColor)
        let renderer = TerminalRendererCache.shared.renderer(
            for: jobPath,
            themeKey: ProjectThemeGenerator.cacheKey(forProjectColor: projectColor),
            theme: theme,
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

    @MainActor
    final class Coordinator {
        private var renderer: LibGhosttyRenderer?
        private weak var pty: ManagedPTY?

        func attach(renderer: LibGhosttyRenderer, store: Store, jobPath: JobPath) {
            self.renderer = renderer
            // Wire input + size to whichever PTY this Coordinator finds.
            // (Re-)assigned per attach; the previous coordinator's closure
            // is replaced atomically before the renderer's UI fires.
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
            // Hand the subscription to the renderer. The renderer owns it
            // and drops the old one (if any) on assignment, so re-attach
            // never produces duplicate feeds.
            renderer?.attachToPTY(pty)
            pty.resize(rows: 40, cols: 120)
        }
    }
}
