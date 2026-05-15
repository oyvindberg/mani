import SwiftUI
import AppKit
import Foundation
import ManiCore

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var activityTracker: TaskActivityTracker
    @State private var showingNewProject = false
    @State private var showingNewWorktree = false
    @State private var showingNewTask = false
    @State private var showingSearch = false

    // Selection is reducer-owned in `store.state.selectedTaskPath`.
    // These helpers expose it as the UUID-keyed view the sidebar /
    // shortcuts use, and dispatch selectTask on write.
    private var selectedJobId: UUID? {
        store.state.selectedTaskPath?.task
    }

    private func selectTask(taskId: UUID?) {
        let path: TaskPath?
        if let taskId {
            path = lookupPath(forJobId: taskId)
        } else {
            path = nil
        }
        _Concurrency.Task { await store.dispatch(.selectTask(at: path)) }
    }

    private func selectTask(at path: TaskPath?) {
        _Concurrency.Task { await store.dispatch(.selectTask(at: path)) }
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedJobId: selectedJobId,
                onSelect: { taskId in selectTask(taskId: taskId) }
            )
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
                        Text(context.worktree.displayName)
                            .foregroundStyle(SwiftUI.Color(hex: context.project.color))
                        Text("›").foregroundStyle(.secondary)
                        Text(context.task.name).bold()
                            .foregroundStyle(SwiftUI.Color(hex: context.project.color))
                        Spacer()
                        ReadyClaudesBar(onSelect: { taskId in
                            selectTask(taskId: taskId)
                        })
                        // Search scrollback. Only meaningful for tasks whose
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
                    if isExternalClaudeTask(context.task) {
                        ExternalClaudeView(
                            task: context.task,
                            taskPath: path,
                            worktreePath: WorktreePath(
                                project: path.project, worktree: path.worktree
                            )
                        )
                        .id(path)
                    } else if case .diff = context.task.kind {
                        DiffWorkspaceView(
                            task: context.task,
                            taskPath: path,
                            worktreePath: context.worktree.path
                        )
                    } else if isRunning(context.task) {
                        TerminalPane(taskPath: path)
                            .id(path)
                    } else {
                        StoppedTaskView(task: context.task, taskPath: path)
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
        .background(readyShortcuts)
        // No onAppear auto-select. The reducer-owned selection
        // already restored from state.json — if it's nil, the user
        // hasn't picked anything yet, so the empty-state is right.
        // The reducer also validates selection lookups in selectTask
        // and auto-deselects on deletion, so we don't need a dangling-
        // selection sweep here. (Boot validation lives in ManiApp.)
        .onChange(of: store.state.selectedTaskPath) { _, newPath in
            guard let newPath else { return }
            _Concurrency.Task { await store.dispatch(.markRead(at: newPath)) }
        }
        .sheet(isPresented: $showingNewProject) {
            NewProjectSheet(store: store, isPresented: $showingNewProject)
        }
        .sheet(isPresented: $showingSearch) {
            ScrollbackSearchSheet(
                sources: allScrollbackSources(),
                isPresented: $showingSearch,
                onSelectMatch: { taskPath, lineNumber in
                    selectTask(at: taskPath)
                    // The renderer rebuilds on selection change; let it
                    // mount before scrolling. 200 ms is conservative.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        TerminalRendererCache.shared
                            .rendererIfPresent(for: taskPath)?
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
                    isPresented: $showingNewTask,
                    onCreated: { id in selectTask(taskId: id) }
                )
            }
        }
    }

    // Same sort as ReadyClaudesBar so ⌘1 always matches the leftmost
    // pill, ⌘2 the next, etc. Recomputed on every body invocation —
    // SwiftUI rerenders when activityTracker or store publish, so
    // the shortcut targets stay current.
    private func readyJobIdsOrdered() -> [UUID] {
        struct Entry {
            let taskId: UUID
            let settledAt: Date?
            let createdAt: Date
        }
        var out: [Entry] = []
        for project in store.state.projects {
            for worktree in project.worktrees {
                for task in worktree.tasks {
                    guard case let .claude(sid) = task.kind, let sid else { continue }
                    if activityTracker.isThinking(sid: sid) { continue }
                    guard task.unread > 0 else { continue }
                    out.append(Entry(
                        taskId: task.id,
                        settledAt: activityTracker.settledAt[sid],
                        createdAt: task.createdAt
                    ))
                }
            }
        }
        out.sort { lhs, rhs in
            (lhs.settledAt ?? lhs.createdAt) > (rhs.settledAt ?? rhs.createdAt)
        }
        return out.map(\.taskId)
    }

    // Invisible, zero-size buttons that hold keyboard shortcuts.
    // Backgrounded onto the body so they're always part of the view
    // hierarchy regardless of which detail pane is mounted. ⌘J cycles
    // the freshest ready claude; ⌘1..⌘9 jump directly to slot N.
    @ViewBuilder
    private var readyShortcuts: some View {
        let ids = readyJobIdsOrdered()
        ZStack {
            Button("Jump to next ready Claude") {
                if let first = ids.first { selectTask(taskId: first) }
            }
            .keyboardShortcut("j", modifiers: [.command])
            .opacity(0).frame(width: 0, height: 0)
            ForEach(0..<9, id: \.self) { i in
                let key = KeyEquivalent(Character("\(i + 1)"))
                Button("Jump to ready Claude \(i + 1)") {
                    if i < ids.count { selectTask(taskId: ids[i]) }
                }
                .keyboardShortcut(key, modifiers: [.command])
                .opacity(0).frame(width: 0, height: 0)
            }
        }
        .allowsHitTesting(false)
    }

    private func scrollbackPath(for taskId: UUID) -> String {
        // Matches EffectRunner's scrollback layout:
        //   ~/Library/Application Support/Mani/tasks/<task-uuid>/scrollback.log
        let root = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
        return root
            .appendingPathComponent("Mani/tasks")
            .appendingPathComponent(taskId.uuidString)
            .appendingPathComponent("scrollback.log").path
    }

    // Every task in state becomes a search source, labeled with its
    // project › worktree › name breadcrumb. The currently-selected task
    // is sorted to the top so its scrollback is the first thing
    // ScrollbackSearchSheet scans (results stay roughly in order of
    // relevance for "I just saw this thing scroll past").
    private func allScrollbackSources() -> [ScrollbackSearchSheet.Source] {
        var sources: [ScrollbackSearchSheet.Source] = []
        let selectedId = selectedJobId
        var selectedSource: ScrollbackSearchSheet.Source?
        for project in store.state.projects {
            for worktree in project.worktrees {
                for task in worktree.tasks {
                    let label = "\(project.name) › \(worktree.displayName) › \(task.name)"
                    let src = ScrollbackSearchSheet.Source(
                        label: label,
                        taskPath: TaskPath(
                            project: project.id,
                            worktree: worktree.id,
                            task: task.id
                        ),
                        scrollbackPath: scrollbackPath(for: task.id)
                    )
                    if task.id == selectedId {
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

    // External = task created via discoverClaudeSession, i.e. claude is running
    // outside Mani. We can observe its JSONL but can't restart it.
    private func isExternalClaudeTask(_ task: Task) -> Bool {
        if case let .claude(sid) = task.kind, sid != nil,
           task.spec.command == "(external claude)" {
            return true
        }
        return false
    }

    private func breadcrumbContext() -> (project: Project, worktree: Worktree, task: Task)? {
        guard let path = selectedJobPath,
              let project = store.state.projects.first(where: { $0.id == path.project }),
              let worktree = project.worktrees.first(where: { $0.id == path.worktree }),
              let task = worktree.tasks.first(where: { $0.id == path.task })
        else { return nil }
        return (project, worktree, task)
    }

    private var selectedJobPath: TaskPath? {
        guard let id = selectedJobId else { return nil }
        return lookupPath(forJobId: id)
    }

    private func firstJobId() -> UUID? {
        store.state.projects.first?.worktrees.first?.tasks.first?.id
    }

    private func lookupPath(forJobId taskId: UUID) -> TaskPath? {
        for project in store.state.projects {
            for worktree in project.worktrees {
                if worktree.tasks.contains(where: { $0.id == taskId }) {
                    return TaskPath(project: project.id, worktree: worktree.id, task: taskId)
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
    @EnvironmentObject var sweeper: SafekeepingSweeper
    @EnvironmentObject var archiveCache: SessionArchiveCache
    @EnvironmentObject var activityTracker: TaskActivityTracker
    let selectedJobId: UUID?
    let onSelect: (UUID?) -> Void
    @State private var resumeContext: ResumeContext?
    @State private var renameContext: RenameContext?
    @State private var collapsedProjects: Set<UUID> = []
    @State private var collapsedWorktrees: Set<UUID> = []
    @State private var expandedPastSessions: Set<UUID> = []
    @State private var expandedArchivedProjects: Set<UUID> = []
    @State private var colorPickerProjectId: UUID?
    @State private var newWorktreeForProject: Project?
    @State private var claudeInvocationProjectId: UUID?

    struct ResumeContext: Identifiable {
        let id = UUID()
        let worktreePath: WorktreePath
        let cwd: URL
    }

    struct RenameContext: Identifiable {
        let id = UUID()
        let taskPath: TaskPath
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
                            ForEach(sortedProjects, id: \.id) { project in
                                projectGroup(project: project)
                                    .padding(.vertical, 4)
                            }
                        }
                        .padding(.vertical, 6)
                    }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                statusRow(icon: "eye", text: "\(watcher.sessionCount) Claude sessions tracked")
                statusRow(icon: "antenna.radiowaves.left.and.right", text: "\(hookListener.receivedCount) hook envelopes")
                if sweeper.isRunning || !archiveCache.bootstrapComplete {
                    let label = sweeper.currentScanLabel
                    let text = label.map { "Scanning Claude history… (\($0))" }
                        ?? "Scanning Claude history…"
                    statusRow(icon: "arrow.triangle.2.circlepath", text: text)
                }
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
                ),
                onCreated: { id in onSelect(id) }
            )
        }
        .sheet(item: $renameContext) { ctx in
            RenameJobSheet(
                store: store,
                taskPath: ctx.taskPath,
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
        .sheet(item: Binding(
            get: { claudeInvocationProjectId.flatMap { id in
                store.state.projects.first(where: { $0.id == id })
            } },
            set: { if $0 == nil { claudeInvocationProjectId = nil } }
        )) { project in
            ProjectClaudeInvocationSheet(
                store: store,
                project: project,
                isPresented: Binding(
                    get: { claudeInvocationProjectId != nil },
                    set: { if !$0 { claudeInvocationProjectId = nil } }
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
        Button("Claude command…") {
            claudeInvocationProjectId = project.id
        }
        Divider()
        Button(project.enabled ? "Disable project (stop all tasks)" : "Enable project") {
            _Concurrency.Task {
                await store.dispatch(.setProjectEnabled(id: project.id, enabled: !project.enabled))
            }
        }
        Divider()
        Button("Delete project", role: .destructive) {
            _Concurrency.Task { await store.dispatch(.deleteProject(id: project.id)) }
        }
    }

    @ViewBuilder
    private func worktreeMenu(project: Project, worktree: Worktree) -> some View {
        let path = WorktreePath(project: project.id, worktree: worktree.id)
        Button("New shell here") {
            _Concurrency.Task {
                await Self.spawnShell(at: path, cwd: worktree.path, store: store)
            }
        }
        Button("New Claude task") {
            _Concurrency.Task {
                await Self.spawnClaude(at: path, cwd: worktree.path, store: store)
            }
        }
        Button("Resume Claude session…") {
            resumeContext = ResumeContext(worktreePath: path, cwd: worktree.path)
        }
        Button("Open in IntelliJ") {
            Self.openInIntelliJ(worktree.path)
        }
        Divider()
        if worktree.path != project.rootDir {
            Button("Make project root") {
                _Concurrency.Task { await store.dispatch(.setProjectRootDir(at: path)) }
            }
        }
        Button(worktree.enabled ? "Disable worktree (stop tasks)" : "Enable worktree") {
            _Concurrency.Task {
                await store.dispatch(.setWorktreeEnabled(at: path, enabled: !worktree.enabled))
            }
        }
        Button("Delete worktree", role: .destructive) {
            _Concurrency.Task { await store.dispatch(.deleteWorktree(at: path)) }
        }
    }

    // User-initiated spawns. createTask's autoSelect=true makes the
    // reducer set selectedTaskPath as part of the same action, so the
    // caller doesn't need to read back the new id or wire selection
    // manually.
    static func spawnShell(at path: WorktreePath, cwd: URL, store: Store) async {
        let spec = ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:], cwd: cwd,
            initialInput: nil
        )
        await store.dispatch(.createTask(
            at: path, name: "shell", kind: .shell, spec: spec, autoSelect: true
        ))
    }

    static func spawnClaude(at path: WorktreePath, cwd: URL, store: Store) async {
        let project = store.state.projects.first(where: { $0.id == path.project })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            project: project, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil, invocation: invocation)
        await store.dispatch(.createTask(
            at: path, name: "claude", kind: .claude(sessionId: nil),
            spec: spec, autoSelect: true
        ))
    }

    static func spawnDiff(at path: WorktreePath, cwd: URL, store: Store) async {
        // Boot-time auto-spawn for git worktrees. autoSelect=false so
        // the freshly-created diff task doesn't yank focus from
        // whatever the user had selected before quitting.
        let spec = ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:], cwd: cwd,
            initialInput: nil
        )
        await store.dispatch(.createTask(
            at: path, name: "diff", kind: .diff,
            spec: spec, autoSelect: false
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
        taskPath: TaskPath,
        worktreePath: WorktreePath,
        sessionId: String,
        cwd: URL,
        currentName: String,
        wasRenamed: Bool
    ) {
        let preservedName = wasRenamed
            ? currentName
            : "claude (adopted \(sessionId.prefix(6)))"
        let project = store.state.projects.first(where: { $0.id == worktreePath.project })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            project: project, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sessionId, invocation: invocation)
        _Concurrency.Task {
            await store.dispatch(.deleteTask(at: taskPath))
            await store.dispatch(.createTask(
                at: worktreePath,
                name: preservedName,
                kind: .claude(sessionId: sessionId),
                spec: spec,
                autoSelect: true
            ))
            if wasRenamed,
               let newJob = store.state.projects
                    .first(where: { $0.id == worktreePath.project })?
                    .worktrees.first(where: { $0.id == worktreePath.worktree })?
                    .tasks.first(where: {
                        if case let .claude(s) = $0.kind, s == sessionId { return true }
                        return false
                    }) {
                let newPath = TaskPath(
                    project: worktreePath.project,
                    worktree: worktreePath.worktree,
                    task: newJob.id
                )
                await store.dispatch(.renameTask(at: newPath, name: preservedName))
            }
        }
    }

    @ViewBuilder
    private func taskMenu(project: Project, worktree: Worktree, task: Task) -> some View {
        let path = TaskPath(project: project.id, worktree: worktree.id, task: task.id)
        Button("Rename…") {
            renameContext = RenameContext(taskPath: path, currentName: task.name)
        }
        Divider()
        Button(task.enabled ? "Stop task" : "Re-enable") {
            _Concurrency.Task {
                await store.dispatch(.setTaskEnabled(at: path, enabled: !task.enabled))
            }
        }
        Button("Mark complete") {
            _Concurrency.Task { await store.dispatch(.completeTask(at: path)) }
        }
        if case .claude = task.kind, isRunning(task) {
            Divider()
            Button("Fork conversation") {
                let runner = store.runner
                _Concurrency.Task {
                    // Type `/fork\r` into the live PTY. claude executes the
                    // slash command and (per claude-code's hook contract)
                    // fires SessionStart for the new session id — the
                    // routing function in ManiCore catches that and creates
                    // a sibling Task via discoverClaudeSession. See ADR-016.
                    guard let pty = await runner.pty(for: path) else { return }
                    pty.write(Data("/fork\r".utf8))
                }
            }
        }
        if case let .claude(sid) = task.kind, let sid,
           task.spec.command == "(external claude)" {
            Divider()
            Button("Adopt into Mani") {
                adoptExternalClaude(taskPath: path, worktreePath: WorktreePath(
                    project: project.id, worktree: worktree.id
                ), sessionId: sid, cwd: task.spec.cwd, currentName: task.name,
                   wasRenamed: task.renamed)
            }
        }
        Divider()
        Button("Delete task", role: .destructive) {
            _Concurrency.Task {
                await store.dispatch(.deleteTask(at: path))
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
        let visibleTasks = project.worktrees.flatMap { $0.tasks }.filter { task in
            if case .diff = task.kind { return false }
            return true
        }
        let projectExpanded = !collapsedProjects.contains(project.id)
        let color = SwiftUI.Color(hex: project.color)
        return HStack(spacing: 0) {
            // Single continuous color bar spans the entire project
            // group (header + every worktree + archived block) so a
            // glance at the sidebar shows the project hierarchy as
            // one cohesive block.
            Rectangle()
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                ProjectHeaderRow(
                    project: project,
                    isExpanded: projectExpanded,
                    taskCount: visibleTasks.count,
                    anyChildThinking: projectAnyThinking(project),
                    anyChildReady: projectAnyReady(project),
                    anyChildJustReady: projectAnyJustReady(project)
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if projectExpanded { collapsedProjects.insert(project.id) }
                        else { collapsedProjects.remove(project.id) }
                    }
                } onContextMenu: {
                    AnyView(projectMenu(project: project))
                }
                if projectExpanded {
                    ForEach(Array(project.worktrees.enumerated()), id: \.element.id) { idx, worktree in
                        if idx > 0 {
                            Rectangle()
                                .fill(color.opacity(0.22))
                                .frame(height: 0.5)
                                .padding(.leading, 6)
                        }
                        worktreeGroup(project: project, worktree: worktree)
                    }
                    archivedWorktreesGroup(project: project)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(color.opacity(0.06))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(color.opacity(0.28), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 5)
    }

    // Sessions whose originating cwd no longer matches any current
    // worktree in the project — i.e. the worktree was removed or
    // moved off disk. Rendered inside a single collapsible group
    // grouped by originating-worktree name so the user can find
    // them under the same label they had before the cleanup.
    @ViewBuilder
    private func archivedWorktreesGroup(project: Project) -> some View {
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let worktreePaths = project.worktrees.map {
            $0.path.resolvingSymlinksInPath().path
        }.filter { $0 != homePath && $0 != "/" }
        let (_, archived) = archiveCache.entriesByPresence(
            for: project.id, worktreePaths: worktreePaths
        )
        if !archived.isEmpty {
            let isExpanded = expandedArchivedProjects.contains(project.id)
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Archived worktrees")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("(\(archived.count))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.leading, 14)
            .padding(.trailing, 10)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isExpanded { expandedArchivedProjects.remove(project.id) }
                    else { expandedArchivedProjects.insert(project.id) }
                }
            }
            if isExpanded {
                let grouped = Dictionary(grouping: archived) {
                    $0.originatingWorktreeName
                }
                let names = grouped.keys.sorted()
                ForEach(names, id: \.self) { name in
                    archivedWorktreeSection(
                        project: project,
                        worktreeName: name,
                        entries: (grouped[name] ?? []).sorted {
                            ($0.lastMessageAt ?? .distantPast)
                                > ($1.lastMessageAt ?? .distantPast)
                        }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private func archivedWorktreeSection(
        project: Project,
        worktreeName: String,
        entries: [SessionIndexEntry]
    ) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.badge.minus")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Text(worktreeName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("(\(entries.count))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.leading, 28)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        ForEach(entries, id: \.sessionId) { entry in
            ArchivedSessionRow(project: project, entry: entry)
        }
    }

    @ViewBuilder
    private func worktreeGroup(project: Project, worktree: Worktree) -> some View {
        let diffJobId = worktree.tasks.first(where: {
            if case .diff = $0.kind { return true }
            return false
        })?.id
        let worktreeExpanded = !collapsedWorktrees.contains(worktree.id)
        let visibleTasks = worktree.tasks.filter { task in
            if case .diff = task.kind { return false }
            return true
        }
        let wtPath = WorktreePath(project: project.id, worktree: worktree.id)
        VStack(alignment: .leading, spacing: 0) {
            WorktreeHeaderRow(
                project: project,
                worktree: worktree,
                isExpanded: worktreeExpanded,
                diffJobId: diffJobId,
                selectedJobId: selectedJobId,
                anyChildThinking: worktreeAnyThinking(worktree),
                anyChildReady: worktreeAnyReady(worktree),
                anyChildJustReady: worktreeAnyJustReady(worktree)
            ) {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if worktreeExpanded { collapsedWorktrees.insert(worktree.id) }
                    else { collapsedWorktrees.remove(worktree.id) }
                }
            } onSelectDiff: {
                if let diffJobId { onSelect(diffJobId) }
            } onNewShell: {
                _Concurrency.Task {
                    await Self.spawnShell(at: wtPath, cwd: worktree.path, store: store)
                }
            } onNewClaude: {
                _Concurrency.Task {
                    await Self.spawnClaude(at: wtPath, cwd: worktree.path, store: store)
                }
            } onContextMenu: {
                AnyView(worktreeMenu(project: project, worktree: worktree))
            }
            if worktreeExpanded {
                let (managed, externals) = partitionVisibleTasks(visibleTasks)
                ForEach(managed) { task in
                    TaskRow(
                        project: project,
                        task: task,
                        selected: selectedJobId == task.id
                    ) {
                        onSelect(task.id)
                    } onContextMenu: {
                        AnyView(taskMenu(project: project, worktree: worktree, task: task))
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
    }

    // Stable alphabetical (case-insensitive) project order in the
    // sidebar — independent of insertion order in state.json.
    private var sortedProjects: [Project] {
        store.state.projects.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private func claudeSid(_ task: Task) -> String? {
        if case let .claude(sid) = task.kind { return sid }
        return nil
    }

    private func worktreeAnyThinking(_ worktree: Worktree) -> Bool {
        for task in worktree.tasks {
            if activityTracker.isThinking(sid: claudeSid(task)) { return true }
        }
        return false
    }

    private func worktreeAnyReady(_ worktree: Worktree) -> Bool {
        for task in worktree.tasks {
            guard let sid = claudeSid(task) else { continue }
            if activityTracker.isThinking(sid: sid) { return false }
            if task.unread > 0 { return true }
        }
        return false
    }

    private func worktreeAnyJustReady(_ worktree: Worktree) -> Bool {
        for task in worktree.tasks {
            guard let sid = claudeSid(task), task.unread > 0 else { continue }
            if activityTracker.justBecameReady(sid: sid) { return true }
        }
        return false
    }

    private func projectAnyThinking(_ project: Project) -> Bool {
        project.worktrees.contains { worktreeAnyThinking($0) }
    }

    private func projectAnyReady(_ project: Project) -> Bool {
        // Mirror the per-worktree precedence: thinking trumps ready.
        if projectAnyThinking(project) { return false }
        return project.worktrees.contains { worktreeAnyReady($0) }
    }

    private func projectAnyJustReady(_ project: Project) -> Bool {
        project.worktrees.contains { worktreeAnyJustReady($0) }
    }

    // Split tasks into "managed" (Mani-spawned, full-row treatment) and
    // "external" (discovered claude transcripts that go under a compact
    // collapsible). External marker: command is "(external claude)".
    private func partitionVisibleTasks(_ tasks: [Task]) -> ([Task], [Task]) {
        var managed: [Task] = []
        var externals: [Task] = []
        for task in tasks {
            if task.spec.command == "(external claude)" {
                externals.append(task)
            } else {
                managed.append(task)
            }
        }
        return (managed, externals)
    }

    @ViewBuilder
    private func pastSessionsGroup(
        project: Project,
        worktree: Worktree,
        externals: [Task]
    ) -> some View {
        let isExpanded = expandedPastSessions.contains(worktree.id)
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
        .padding(.leading, 24)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
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
            ForEach(sorted) { task in
                PastSessionRow(
                    project: project,
                    task: task,
                    selected: selectedJobId == task.id
                ) {
                    onSelect(task.id)
                } onContextMenu: {
                    AnyView(taskMenu(project: project, worktree: worktree, task: task))
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

extension ManiCore.Task {
    var statusColor: SwiftUI.Color {
        switch runtime {
        case .running:   return .green
        case .neverStarted: return .gray
        case .exited:    return .gray
        case .completed: return .blue
        }
    }

    // ADR-009: status indication uses both color AND a glyph so users with
    // red/green colorblindness can distinguish without relying on hue alone.
    var statusSymbol: String {
        switch runtime {
        case .running:      return "circle.fill"
        case .neverStarted: return "circle.dotted"
        case .exited:       return "stop.circle.fill"
        case .completed:    return "checkmark.circle.fill"
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
    let task: Task
    let taskPath: TaskPath
    let worktreePath: WorktreePath
    @EnvironmentObject var store: Store
    @EnvironmentObject var watcher: ClaudeWatcher
    @EnvironmentObject var safekeepingStore: SafekeepingStore

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
        .task(id: taskPath) {
            loading = true
            detail = nil
            recent = []
            await load()
        }
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
        if case let .claude(s) = task.kind { return s }
        return nil
    }

    private var transcriptURL: URL? {
        guard let sid = sessionId else { return nil }
        // Match ClaudeHistoryScanner's slug convention.
        let cwd = task.spec.cwd.path
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
        guard let sid = sessionId else { loading = false; return }
        let projectId = taskPath.project
        let live = transcriptURL
        let archive = safekeepingStore
        await _Concurrency.Task.detached(priority: .userInitiated) {
            // Prefer the safekept gzip: it survives even if
            // claude.ai's retention deleted the original. Decompress
            // to a temp .jsonl so the existing line-stream parser
            // works unchanged. Fall back to the live source if there
            // is no archive yet (hot, first-sweep cases).
            let urlForParse: URL?
            if archive.hasTranscript(sessionId: sid, for: projectId) {
                do {
                    let data = try archive.readArchivedTranscript(
                        sessionId: sid, for: projectId
                    )
                    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("mani-archive-\(sid).jsonl")
                    try data.write(to: tmp, options: [.atomic])
                    urlForParse = tmp
                } catch {
                    urlForParse = live
                }
            } else {
                urlForParse = live
            }
            let result: (ClaudeHistoryScanner.Session, [ClaudeHistoryScanner.RecentMessage])?
            if let urlForParse {
                result = ClaudeHistoryScanner.detail(
                    jsonl: urlForParse, recentLimit: 5
                )
            } else {
                result = nil
            }
            await MainActor.run {
                if let result {
                    detail = result.0
                    recent = result.1
                } else {
                    // Transcript not on disk anywhere (claude migrated
                    // it off the slug root and we don't have a gzip
                    // copy either). Fall back to whatever summary the
                    // safekeep cache has — at minimum the firstPrompt
                    // and lastMessageAt that came out of claude's own
                    // sessions-index.json.
                    if let entry = SessionArchiveCache.shared
                        .entries(for: projectId)
                        .first(where: { $0.sessionId == sid })
                    {
                        detail = ClaudeHistoryScanner.Session(
                            id: sid,
                            path: live ?? URL(fileURLWithPath: "/dev/null"),
                            cwd: entry.originatingCwd,
                            firstUserMessage: entry.firstUserMessage,
                            lastMessageAt: entry.lastMessageAt,
                            messageCount: entry.messageCount
                        )
                        recent = []
                    }
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
        guard case let .claude(sid) = task.kind, let sid else { return }
        let cwd = task.spec.cwd
        let preservedName = task.renamed ? task.name : "claude (adopted \(sid.prefix(6)))"
        let preservedRenamed = task.renamed
        let oldPath = taskPath
        let wt = worktreePath
        let project = store.state.projects.first(where: { $0.id == wt.project })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            project: project, settings: store.state.settings
        )
        _Concurrency.Task {
            // Order matters: delete the external first so the new Task's
            // .claude(sid) doesn't trip the global uniqueness check.
            await store.dispatch(.deleteTask(at: oldPath))
            let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sid, invocation: invocation)
            await store.dispatch(.createTask(
                at: wt,
                name: preservedName,
                kind: .claude(sessionId: sid),
                spec: spec,
                autoSelect: true
            ))
            if preservedRenamed,
               let newJob = store.state.projects
                    .first(where: { $0.id == wt.project })?
                    .worktrees.first(where: { $0.id == wt.worktree })?
                    .tasks.first(where: {
                        if case let .claude(s) = $0.kind, s == sid { return true }
                        return false
                    }) {
                let newPath = TaskPath(
                    project: wt.project, worktree: wt.worktree, task: newJob.id
                )
                await store.dispatch(.renameTask(at: newPath, name: preservedName))
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

private struct StoppedTaskView: View {
    let task: Task
    let taskPath: TaskPath
    @EnvironmentObject var store: Store

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: task.statusSymbol)
                .font(.system(size: 36))
                .foregroundStyle(task.statusColor)
            Text(stoppedHeadline)
                .font(.headline)
            Text(displayCommand)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: 600)
            Button("Restart") {
                // Claude tasks always rebuild via ClaudeTaskSpec — never reuse
                // task.spec for them, since the persisted spec may be a stale
                // pre-zsh-injection invocation from an earlier Mani build.
                let project = store.state.projects.first(where: { $0.id == taskPath.project })
                let invocation = ClaudeTaskSpec.resolveInvocation(
                    project: project, settings: store.state.settings
                )
                let newSpec = ClaudeTaskSpec.restartSpec(for: task, invocation: invocation)
                let path = taskPath
                _Concurrency.Task {
                    // If the spec needs to change (claude case), persist
                    // it first so a future restart sees the new shape.
                    if newSpec != task.spec {
                        await store.dispatch(.setTaskSpec(at: path, spec: newSpec))
                    }
                    await store.dispatch(.restartTask(at: path))
                }
            }
            .keyboardShortcut("r", modifiers: [.command])
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var stoppedHeadline: String {
        switch task.runtime {
        case .neverStarted:       return "Not started"
        case .running:            return "Process not running"
        case let .exited(_, code):
            return code == 0 ? "Process exited" : "Process exited (code \(code))"
        case .completed:          return "Completed"
        }
    }

    private var displayCommand: String {
        ([task.spec.command] + task.spec.args).joined(separator: " ")
    }
}

// True iff the reducer currently believes the task's agent is alive.
// Used by views that need a quick running-vs-stopped distinction; the
// authoritative liveness check is host.isAlive, but that's async, and
// the runtime field is reconciled at boot + on every taskExited so
// it's good enough for render-time branching.
func isRunning(_ task: Task) -> Bool {
    if case .running = task.runtime { return true }
    return false
}

struct TerminalPane: NSViewRepresentable {
    let taskPath: TaskPath
    @EnvironmentObject var store: Store

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // libghostty-backed renderer (per ADR-002 v0.2 swap). Cached per
        // TaskPath so tab-switching back doesn't tear down the surface and
        // replay scrollback. The TerminalTheme is generated from the
        // project's color (both a light and a dark variant; libghostty
        // swaps automatically with the system appearance). Cache key
        // includes the color hex so a project re-coloring rebuilds the
        // renderer next time it mounts.
        let projectColor = store.state.projects
            .first(where: { $0.id == taskPath.project })?.color
            ?? "#808080"
        let theme = ProjectThemeGenerator.theme(forProjectColor: projectColor)
        let renderer = TerminalRendererCache.shared.renderer(
            for: taskPath,
            themeKey: ProjectThemeGenerator.cacheKey(forProjectColor: projectColor),
            theme: theme,
            fontFamily: store.state.settings.terminalFontFamily,
            fontSize: store.state.settings.terminalFontSize
        )
        context.coordinator.attach(renderer: renderer, store: store, taskPath: taskPath)
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
        private weak var pty: TaskIO?
        private var taskPath: TaskPath?

        func attach(renderer: LibGhosttyRenderer, store: Store, taskPath: TaskPath) {
            self.renderer = renderer
            self.taskPath = taskPath
            renderer.inputHandler = { [weak self] data in self?.pty?.write(data) }
            let runner = store.runner
            let capturedPath = taskPath
            renderer.sizeHandler = { rows, cols in
                _Concurrency.Task {
                    await runner.resize(
                        path: capturedPath,
                        rows: UInt16(rows),
                        cols: UInt16(cols)
                    )
                }
            }

            _Concurrency.Task {
                for _ in 0..<200 {
                    if let pty = await runner.pty(for: taskPath) {
                        await MainActor.run { self.bind(pty: pty) }
                        return
                    }
                    try? await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
            }
        }

        private func bind(pty: TaskIO) {
            self.pty = pty
            // Pre-feed the on-disk scrollback log so the terminal's
            // screen reflects history from prior Mani sessions BEFORE
            // we subscribe to the live stream. Without this, the
            // renderer only ever sees what the agent has buffered
            // since the last detach (often empty for idle shells),
            // and reattach looks blank. Then subscribe with
            // replayCaptured: false — the disk content already covers
            // every byte the AgentClient has captured this attach.
            if let path = taskPath, let history = readScrollback(taskId: path.task) {
                renderer?.feed(history)
                renderer?.attachToPTY(pty, replayCaptured: false)
            } else {
                renderer?.attachToPTY(pty)
            }
        }

        // Path mirrors EffectRunner's scrollback layout:
        //   ~/Library/Application Support/Mani/tasks/<task-uuid>/scrollback.log
        private func readScrollback(taskId: UUID) -> Data? {
            let root = FileManager.default
                .urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!
            let url = root
                .appendingPathComponent("Mani/tasks")
                .appendingPathComponent(taskId.uuidString)
                .appendingPathComponent("scrollback.log")
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                return nil
            }
            return data
        }
    }
}
