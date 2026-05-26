import SwiftUI
import AppKit
import Foundation
import ManiServer
import ManiCore

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var activityTracker: TaskActivityTracker
    @State private var showingNewRepo = false
    @State private var showingNewWorktree = false
    @State private var showingNewTask = false
    @State private var showingSearch = false
    // Selecting an external convo in the sidebar opens its detail
    // view (with an Adopt button). Mutually exclusive with task
    // selection — picking one clears the other. View-local for now;
    // can be promoted to reducer state later if needed.
    @State private var selectedExternalConvoId: UUID?

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
        selectedExternalConvoId = nil
        _Concurrency.Task { await store.dispatch(.selectTask(at: path)) }
    }

    private func selectTask(at path: TaskPath?) {
        selectedExternalConvoId = nil
        _Concurrency.Task { await store.dispatch(.selectTask(at: path)) }
    }

    private func selectExternalConvo(_ convoId: UUID?) {
        selectedExternalConvoId = convoId
        if convoId != nil {
            _Concurrency.Task { await store.dispatch(.selectTask(at: nil)) }
        }
    }

    // Find the (repo, convo) for the currently-selected external
    // convo id. Returns nil if the id no longer exists in state
    // (the convo was dismissed or adopted).
    private func selectedExternalConvo() -> (Repo, ExternalConvo)? {
        guard let id = selectedExternalConvoId else { return nil }
        for repo in store.state.repos {
            if let convo = repo.externalConvos.first(where: { $0.id == id }) {
                return (repo, convo)
            }
        }
        return nil
    }

    // First repo whose tasks include a thinking claude session.
    // Drives the soft top-of-window ambient gradient — the whole
    // app "breathes" the color of whatever's currently working.
    // If multiple repos have thinking tasks, the iteration order
    // wins; cheap to evaluate (most repos have 0–few claudes).
    private var ambientThinkingColor: SwiftUI.Color? {
        for repo in store.state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    if case let .claude(sid) = task.kind,
                       let sid,
                       activityTracker.isThinking(sid: sid) {
                        return SwiftUI.Color(hex: repo.color)
                    }
                }
            }
        }
        return nil
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedJobId: selectedJobId,
                selectedExternalConvoId: selectedExternalConvoId,
                onSelect: { taskId in selectTask(taskId: taskId) },
                onSelectConvo: { convoId in selectExternalConvo(convoId) }
            )
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 420)
                .scrollContentBackground(.hidden)
                .background(
                    VisualEffectView(
                        material: .underWindowBackground,
                        blendingMode: .behindWindow
                    )
                    .ignoresSafeArea()
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New Repo…") { showingNewRepo = true }
                                .keyboardShortcut("p", modifiers: [.command, .shift])
                            Button("New Project…") { showingNewWorktree = true }
                                .keyboardShortcut("n", modifiers: [.command, .shift])
                                .disabled(currentRepo() == nil)
                            Button("New Task…") { showingNewTask = true }
                                .keyboardShortcut("t", modifiers: [.command])
                                .disabled(currentProjectPath() == nil)
                        } label: {
                            Label("Add", systemImage: "plus")
                        }
                    }
                }
        } detail: {
            if let (repo, convo) = selectedExternalConvo() {
                VStack(spacing: 0) {
                    let repoColor = SwiftUI.Color(hex: repo.color)
                    Rectangle()
                        .fill(repoColor)
                        .frame(height: 1.5)
                    HStack(spacing: 6) {
                        BreadcrumbSegment(
                            text: repo.name,
                            tint: repoColor,
                            weight: .medium
                        )
                        BreadcrumbDivider()
                        Text("external convo")
                            .font(.system(.title3, design: .serif).italic())
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    Divider().opacity(0.4)
                    ExternalConvoView(repo: repo, convo: convo, onAdopted: {
                        selectedExternalConvoId = nil
                    })
                    .id(convo.id)
                }
            } else if let path = selectedJobPath, let context = breadcrumbContext() {
                VStack(spacing: 0) {
                    let repoColor = SwiftUI.Color(hex: context.repo.color)
                    Rectangle()
                        .fill(repoColor)
                        .frame(height: 1.5)
                    HStack(spacing: 6) {
                        BreadcrumbSegment(
                            text: context.repo.name,
                            tint: repoColor,
                            weight: .medium
                        )
                        BreadcrumbDivider()
                        BreadcrumbSegment(
                            text: context.project.name,
                            tint: repoColor,
                            weight: .medium
                        )
                        BreadcrumbDivider()
                        BreadcrumbSegment(
                            text: context.task.name,
                            tint: repoColor,
                            weight: .semibold
                        )
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
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                    WorkspaceInfoBar(
                        repo: context.repo,
                        project: context.project
                    )
                    Divider().opacity(0.4)
                    if isExternalClaudeTask(context.task) {
                        ExternalClaudeView(
                            task: context.task,
                            taskPath: path,
                            projectPath: ProjectPath(
                                repo: path.repo, project: path.project
                            )
                        )
                        .id(path)
                    } else if case .diff = context.task.kind {
                        DiffWorkspaceView(
                            task: context.task,
                            taskPath: path,
                            projectPath: context.project.workspace.path
                        )
                    } else if isRunning(context.task) {
                        TerminalPane(taskPath: path)
                            .id(path)
                    } else {
                        StoppedTaskView(task: context.task, taskPath: path)
                    }
                }
            } else {
                if store.state.repos.isEmpty {
                    VStack(spacing: 18) {
                        Image(systemName: "rectangle.stack.badge.plus")
                            .font(.system(size: 52, weight: .light))
                            .foregroundStyle(.tertiary)
                        VStack(spacing: 6) {
                            Text("No repos yet")
                                .font(.system(.largeTitle, design: .serif).weight(.semibold))
                                .tracking(-0.5)
                                .foregroundStyle(.secondary)
                            Text("⇧⌘P  to add one")
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        Button("New Repo…") { showingNewRepo = true }
                            .keyboardShortcut("p", modifiers: [.command, .shift])
                            .controlSize(.large)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "sidebar.left")
                            .font(.system(size: 36, weight: .light))
                            .foregroundStyle(.quaternary)
                        Text("Select a task")
                            .font(.system(.largeTitle, design: .serif).weight(.medium))
                            .tracking(-0.5)
                            .foregroundStyle(.secondary)
                        Text("pick one from the sidebar to get started")
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .overlay(alignment: .top) {
            // Ambient activity tint: when any task is thinking, a
            // soft gradient in that repo's color hangs at the top
            // edge of the window. The app subtly "breathes" the
            // color of whatever's currently working. Pure
            // atmosphere — doesn't gate interaction.
            if let activeColor = ambientThinkingColor {
                LinearGradient(
                    colors: [activeColor.opacity(0.18), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 120)
                .allowsHitTesting(false)
                .ignoresSafeArea(edges: .top)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: ambientThinkingColor)
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
        .sheet(isPresented: $showingNewRepo) {
            NewProjectSheet(store: store, isPresented: $showingNewRepo)
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
            if let repo = currentRepo() {
                NewWorktreeSheet(
                    store: store,
                    repoId: repo.id,
                    isPresented: $showingNewWorktree
                )
            }
        }
        .sheet(isPresented: $showingNewTask) {
            if let path = currentProjectPath(), let cwd = currentProjectCwd() {
                NewTaskSheet(
                    store: store,
                    projectPath: path,
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
        for repo in store.state.repos {
            for project in repo.projects {
                for task in project.tasks {
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
    // repo › project › name breadcrumb. The currently-selected task
    // is sorted to the top so its scrollback is the first thing
    // ScrollbackSearchSheet scans (results stay roughly in order of
    // relevance for "I just saw this thing scroll past").
    private func allScrollbackSources() -> [ScrollbackSearchSheet.Source] {
        var sources: [ScrollbackSearchSheet.Source] = []
        let selectedId = selectedJobId
        var selectedSource: ScrollbackSearchSheet.Source?
        for repo in store.state.repos {
            for project in repo.projects {
                for task in project.tasks {
                    let label = "\(repo.name) › \(project.name) › \(task.name)"
                    let src = ScrollbackSearchSheet.Source(
                        label: label,
                        taskPath: TaskPath(
                            repo: repo.id,
                            project: project.id,
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

    private func currentRepo() -> Repo? {
        if let path = selectedJobPath {
            return store.state.repos.first { $0.id == path.repo }
        }
        return store.state.repos.first
    }

    private func currentProjectPath() -> ProjectPath? {
        if let path = selectedJobPath {
            return path.projectPath
        }
        guard let repo = store.state.repos.first,
              let project = repo.projects.first
        else { return nil }
        return ProjectPath(repo: repo.id, project: project.id)
    }

    private func currentProjectCwd() -> URL? {
        currentProject()?.workspace.path
    }

    private func currentProject() -> Project? {
        guard let path = currentProjectPath() else { return nil }
        return store.state.repos.first(where: { $0.id == path.repo })?
            .projects.first(where: { $0.id == path.project })
    }

    // External = task created via discoverExternalConvo, i.e. claude is running
    // outside Mani. We can observe its JSONL but can't restart it.
    private func isExternalClaudeTask(_ task: Task) -> Bool {
        if case let .claude(sid) = task.kind, sid != nil,
           task.spec.command == "(external claude)" {
            return true
        }
        return false
    }

    private func breadcrumbContext() -> (repo: Repo, project: Project, task: Task)? {
        guard let path = selectedJobPath,
              let repo = store.state.repos.first(where: { $0.id == path.repo }),
              let project = repo.projects.first(where: { $0.id == path.project }),
              let task = project.tasks.first(where: { $0.id == path.task })
        else { return nil }
        return (repo, project, task)
    }

    private var selectedJobPath: TaskPath? {
        guard let id = selectedJobId else { return nil }
        return lookupPath(forJobId: id)
    }

    private func firstJobId() -> UUID? {
        store.state.repos.first?.projects.first?.tasks.first?.id
    }

    private func lookupPath(forJobId taskId: UUID) -> TaskPath? {
        for repo in store.state.repos {
            for project in repo.projects {
                if project.tasks.contains(where: { $0.id == taskId }) {
                    return TaskPath(repo: repo.id, project: project.id, task: taskId)
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
    let selectedExternalConvoId: UUID?
    let onSelect: (UUID?) -> Void
    let onSelectConvo: (UUID?) -> Void
    @State private var resumeContext: ResumeContext?
    @State private var renameContext: RenameContext?
    @State private var renameProjectContext: RenameProjectContext?
    @State private var renameRepoContext: RenameRepoContext?
    @State private var collapsedRepos: Set<UUID> = []
    // External convo folders default-collapsed too, mirroring projects.
    @State private var expandedExternalConvoFolders: Set<UUID> = []
    @State private var expandedFinishedFolders: Set<UUID> = []
    // Projects are collapsed by default. Empty set = none expanded =
    // every project starts closed. The user opens what they're
    // actively touching.
    @State private var expandedProjects: Set<UUID> = []
    @State private var expandedArchivedProjects: Set<UUID> = []
    @State private var colorPickerProjectId: UUID?
    @State private var finishProjectContext: FinishProjectContext?
    // Currently-dragged task. Set by TaskRow on .onDrag; read by
    // WorktreeHeaderRow to colour itself green (valid drop) or
    // red (mismatched workspace). Cleared by the drop handler.
    @State private var sidebarDragInfo: SidebarDragInfo?
    @State private var newWorktreeForRepo: Repo?
    @State private var newProjectFromPRForRepo: Repo?
    @State private var claudeInvocationProjectId: UUID?

    struct ResumeContext: Identifiable {
        let id = UUID()
        let projectPath: ProjectPath
        let cwd: URL
    }

    struct RenameContext: Identifiable {
        let id = UUID()
        let taskPath: TaskPath
        let currentName: String
    }

    struct RenameProjectContext: Identifiable {
        let id = UUID()
        let projectPath: ProjectPath
        let currentName: String
    }

    struct RenameRepoContext: Identifiable {
        let id = UUID()
        let repoId: UUID
        let currentName: String
    }

    struct FinishProjectContext: Identifiable {
        let id = UUID()
        let repoColor: SwiftUI.Color
        let repoName: String
        let projectName: String
        let projectPath: ProjectPath
        let workspace: Workspace
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if store.state.repos.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("No repos yet")
                            .font(.headline)
                        Text("Use the + button in the toolbar\nto create your first repo.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(sortedProjects, id: \.id) { repo in
                                    repoGroup(repo: repo)
                                        .padding(.vertical, 4)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        // Bring the selected task into view whenever
                        // selection changes — covers ⌘1-9 jumps, the
                        // Standing-by overlay's Enter activation, and
                        // any other path that updates selectedJobId.
                        //
                        // Two steps: (1) expand whatever the row is
                        // hidden inside (collapsed repo or collapsed
                        // project) so the LazyVStack actually
                        // renders it, then (2) scroll. A short
                        // post-layout wait lets SwiftUI settle the
                        // newly-expanded geometry before the scroll
                        // runs — scrolling to an unrendered id is a
                        // silent no-op.
                        .onChange(of: selectedJobId) { _, newId in
                            guard let newId,
                                  let (repoId, projectId) = containingPath(taskId: newId)
                            else { return }
                            if collapsedRepos.contains(repoId) {
                                collapsedRepos.remove(repoId)
                            }
                            if !expandedProjects.contains(projectId) {
                                expandedProjects.insert(projectId)
                            }
                            _Concurrency.Task { @MainActor in
                                try? await _Concurrency.Task.sleep(
                                    nanoseconds: 60_000_000  // 60 ms
                                )
                                withAnimation(.easeOut(duration: 0.22)) {
                                    proxy.scrollTo(newId, anchor: .center)
                                }
                            }
                        }
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
                projectPath: ctx.projectPath,
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
        .sheet(item: $renameProjectContext) { ctx in
            RenameProjectSheet(
                store: store,
                projectPath: ctx.projectPath,
                currentName: ctx.currentName,
                isPresented: Binding(
                    get: { renameProjectContext != nil },
                    set: { if !$0 { renameProjectContext = nil } }
                )
            )
        }
        .sheet(item: $renameRepoContext) { ctx in
            RenameRepoSheet(
                store: store,
                repoId: ctx.repoId,
                currentName: ctx.currentName,
                isPresented: Binding(
                    get: { renameRepoContext != nil },
                    set: { if !$0 { renameRepoContext = nil } }
                )
            )
        }
        .sheet(item: $finishProjectContext) { ctx in
            FinishProjectSheet(
                store: store,
                repoColor: ctx.repoColor,
                repoName: ctx.repoName,
                projectName: ctx.projectName,
                projectPath: ctx.projectPath,
                workspace: ctx.workspace,
                isPresented: Binding(
                    get: { finishProjectContext != nil },
                    set: { if !$0 { finishProjectContext = nil } }
                )
            )
        }
        .sheet(item: Binding(
            get: { colorPickerProjectId.flatMap { id in
                store.state.repos.first(where: { $0.id == id })
            } },
            set: { if $0 == nil { colorPickerProjectId = nil } }
        )) { repo in
            RepoColorSheet(
                store: store,
                repo: repo,
                isPresented: Binding(
                    get: { colorPickerProjectId != nil },
                    set: { if !$0 { colorPickerProjectId = nil } }
                )
            )
        }
        .sheet(item: $newWorktreeForRepo) { repo in
            NewWorktreeSheet(
                store: store,
                repoId: repo.id,
                isPresented: Binding(
                    get: { newWorktreeForRepo != nil },
                    set: { if !$0 { newWorktreeForRepo = nil } }
                )
            )
        }
        .sheet(item: $newProjectFromPRForRepo) { repo in
            NewProjectFromPRSheet(
                store: store,
                repoId: repo.id,
                isPresented: Binding(
                    get: { newProjectFromPRForRepo != nil },
                    set: { if !$0 { newProjectFromPRForRepo = nil } }
                )
            )
        }
        .sheet(item: Binding(
            get: { claudeInvocationProjectId.flatMap { id in
                store.state.repos.first(where: { $0.id == id })
            } },
            set: { if $0 == nil { claudeInvocationProjectId = nil } }
        )) { repo in
            RepoClaudeInvocationSheet(
                store: store,
                repo: repo,
                isPresented: Binding(
                    get: { claudeInvocationProjectId != nil },
                    set: { if !$0 { claudeInvocationProjectId = nil } }
                )
            )
        }
    }

    @ViewBuilder
    private func repoMenu(repo: Repo) -> some View {
        Button("Add project…") {
            newWorktreeForRepo = repo
        }
        Button("New project from PR…") {
            newProjectFromPRForRepo = repo
        }
        Button("Change color…") {
            colorPickerProjectId = repo.id
        }
        Button("Claude command…") {
            claudeInvocationProjectId = repo.id
        }
        Divider()
        Menu("Worktree mode") {
            Button {
                _Concurrency.Task {
                    await store.dispatch(.setRepoWorktreeMode(
                        id: repo.id, mode: .manual
                    ))
                }
            } label: {
                Label(
                    "Manual",
                    systemImage: repo.worktreeMode == .manual ? "checkmark" : ""
                )
            }
            Button {
                _Concurrency.Task {
                    await store.dispatch(.setRepoWorktreeMode(
                        id: repo.id, mode: .managed
                    ))
                }
            } label: {
                Label(
                    "Managed (Mani creates / removes worktrees)",
                    systemImage: repo.worktreeMode == .managed ? "checkmark" : ""
                )
            }
        }
        Button(repo.enabled ? "Disable repo (stop all tasks)" : "Enable repo") {
            _Concurrency.Task {
                await store.dispatch(.setRepoEnabled(id: repo.id, enabled: !repo.enabled))
            }
        }
        Divider()
        Button("Delete repo", role: .destructive) {
            _Concurrency.Task { await store.dispatch(.deleteRepo(id: repo.id)) }
        }
    }

    @ViewBuilder
    private func projectMenu(repo: Repo, project: Project) -> some View {
        let path = ProjectPath(repo: repo.id, project: project.id)
        Button("Rename project…") {
            renameProjectContext = RenameProjectContext(
                projectPath: path, currentName: project.name
            )
        }
        Divider()
        Button("New shell here") {
            _Concurrency.Task {
                await Self.spawnShell(at: path, cwd: project.workspace.path, store: store)
            }
        }
        Button("New Claude task") {
            _Concurrency.Task {
                await Self.spawnClaude(at: path, cwd: project.workspace.path, store: store)
            }
        }
        Button("Resume Claude session…") {
            resumeContext = ResumeContext(projectPath: path, cwd: project.workspace.path)
        }
        Button("Open in IntelliJ") {
            Self.openInIntelliJ(project.workspace.path)
        }
        Divider()
        if project.workspace.path != repo.rootDir {
            Button("Make repo root") {
                _Concurrency.Task { await store.dispatch(.setRepoRootDir(at: path)) }
            }
        }
        if project.isArchived {
            Button("Unarchive project") {
                _Concurrency.Task { await store.dispatch(.unarchiveProject(at: path)) }
            }
        } else {
            Button("Archive project (stop tasks)") {
                _Concurrency.Task { await store.dispatch(.archiveProject(at: path)) }
            }
            Button("Finish project…") {
                finishProjectContext = FinishProjectContext(
                    repoColor: SwiftUI.Color(hex: repo.color),
                    repoName: repo.name,
                    projectName: project.name,
                    projectPath: path,
                    workspace: project.workspace
                )
            }
        }
        Button("Delete project", role: .destructive) {
            _Concurrency.Task { await store.dispatch(.deleteProject(at: path)) }
        }
    }

    // User-initiated spawns. createTask's autoSelect=true makes the
    // reducer set selectedTaskPath as part of the same action, so the
    // caller doesn't need to read back the new id or wire selection
    // manually.
    static func spawnShell(at path: ProjectPath, cwd: URL, store: Store) async {
        let spec = ProcessSpec(
            command: "/bin/zsh", args: ["-l"],
            env: [:], cwd: cwd,
            initialInput: nil
        )
        await store.dispatch(.createTask(
            at: path, name: "shell", kind: .shell, spec: spec, autoSelect: true
        ))
    }

    static func spawnClaude(at path: ProjectPath, cwd: URL, store: Store) async {
        let repo = store.state.repos.first(where: { $0.id == path.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil, invocation: invocation)
        await store.dispatch(.createTask(
            at: path, name: "claude", kind: .claude(sessionId: nil),
            spec: spec, autoSelect: true
        ))
    }

    static func spawnDiff(at path: ProjectPath, cwd: URL, store: Store) async {
        // Boot-time auto-spawn for git projects. autoSelect=false so
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
        projectPath: ProjectPath,
        sessionId: String,
        cwd: URL,
        currentName: String,
        wasRenamed: Bool
    ) {
        let preservedName = wasRenamed
            ? currentName
            : "claude (adopted \(sessionId.prefix(6)))"
        let repo = store.state.repos.first(where: { $0.id == projectPath.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sessionId, invocation: invocation)
        _Concurrency.Task {
            await store.dispatch(.deleteTask(at: taskPath))
            await store.dispatch(.createTask(
                at: projectPath,
                name: preservedName,
                kind: .claude(sessionId: sessionId),
                spec: spec,
                autoSelect: true
            ))
            if wasRenamed,
               let newJob = store.state.repos
                    .first(where: { $0.id == projectPath.repo })?
                    .projects.first(where: { $0.id == projectPath.project })?
                    .tasks.first(where: {
                        if case let .claude(s) = $0.kind, s == sessionId { return true }
                        return false
                    }) {
                let newPath = TaskPath(
                    repo: projectPath.repo,
                    project: projectPath.project,
                    task: newJob.id
                )
                await store.dispatch(.renameTask(at: newPath, name: preservedName))
            }
        }
    }

    @ViewBuilder
    private func taskMenu(repo: Repo, project: Project, task: Task) -> some View {
        let path = TaskPath(repo: repo.id, project: project.id, task: task.id)
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
                let storeRef = store
                _Concurrency.Task { @MainActor in
                    // Type `/fork\r` into the live PTY. claude executes the
                    // slash command and (per claude-code's hook contract)
                    // fires SessionStart for the new session id — the
                    // routing function in ManiCore catches that and creates
                    // a sibling Task via discoverExternalConvo. See ADR-016.
                    guard let pty = await storeRef.taskIO(for: path.task) else { return }
                    pty.write(Data("/fork\r".utf8))
                }
            }
        }
        if case let .claude(sid) = task.kind, let sid,
           task.spec.command == "(external claude)" {
            Divider()
            Button("Adopt into Mani") {
                adoptExternalClaude(taskPath: path, projectPath: ProjectPath(
                    repo: repo.id, project: project.id
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
    private func repoGroup(repo: Repo) -> some View {
        let visibleTasks = repo.projects.flatMap { $0.tasks }.filter { task in
            if case .diff = task.kind { return false }
            return true
        }
        let repoExpanded = !collapsedRepos.contains(repo.id)
        let color = SwiftUI.Color(hex: repo.color)
        return HStack(spacing: 0) {
            // Single continuous color bar spans the entire repo
            // group (header + every project + archived block) so a
            // glance at the sidebar shows the repo hierarchy as
            // one cohesive block.
            Rectangle()
                .fill(color)
                .frame(width: 4)
            VStack(alignment: .leading, spacing: 0) {
                RepoHeaderRow(
                    repo: repo,
                    isExpanded: repoExpanded,
                    taskCount: visibleTasks.count,
                    anyChildThinking: repoAnyThinking(repo),
                    anyChildReady: repoAnyReady(repo),
                    anyChildJustReady: repoAnyJustReady(repo)
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if repoExpanded { collapsedRepos.insert(repo.id) }
                        else { collapsedRepos.remove(repo.id) }
                    }
                } onRename: {
                    renameRepoContext = RenameRepoContext(
                        repoId: repo.id, currentName: repo.name
                    )
                } onContextMenu: {
                    AnyView(repoMenu(repo: repo))
                }
                if repoExpanded {
                    let active = repo.projects.filter { !$0.isArchived }
                    let archived = repo.projects.filter { $0.isArchived }
                    ForEach(Array(active.enumerated()), id: \.element.id) { idx, project in
                        if idx > 0 {
                            Rectangle()
                                .fill(color.opacity(0.22))
                                .frame(height: 0.5)
                                .padding(.leading, 6)
                        }
                        worktreeGroup(repo: repo, project: project)
                    }
                    // Workspace dirs left over from archived
                    // manual-worktree projects. Sit at the repo
                    // level as candidates for starting a new
                    // project without re-picking the path.
                    //
                    // In .managed mode, filter out entries that
                    // don't live under the managed worktrees
                    // namespace — those came from a previous
                    // life as manual workspaces and aren't useful
                    // candidates for the managed flow. They stay
                    // in state.json (so flipping back to .manual
                    // resurrects them); only the UI hides them.
                    ForEach(visibleAvailableWorktrees(for: repo)) { wt in
                        AvailableWorktreeRow(
                            repo: repo,
                            worktree: wt,
                            onClick: {
                                // Click opens the New Project sheet
                                // for this repo. The user can fill
                                // in the path manually; pre-fill
                                // requires plumbing initial values
                                // into NewWorktreeSheet and is a
                                // small follow-up.
                                newWorktreeForRepo = repo
                            },
                            onContextMenu: {
                                AnyView(availableWorktreeMenu(repo: repo, worktree: wt))
                            }
                        )
                    }
                    // Orphan external convos: cwd doesn't fall inside
                    // any current project's workspace. Surface at
                    // repo level so they're not lost.
                    let orphans = orphanConvos(repo: repo)
                    if !orphans.isEmpty {
                        externalConvosFolder(
                            repo: repo,
                            folderId: repo.id,
                            title: "External convos (no matching workspace)",
                            convos: orphans,
                            indent: 12
                        )
                    }
                    if !archived.isEmpty {
                        finishedProjectsFolder(repo: repo, archived: archived)
                    }
                    archivedWorktreesGroup(repo: repo)
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
    // project in the repo — i.e. the project was removed or
    // moved off disk. Rendered inside a single collapsible group
    // grouped by originating-project name so the user can find
    // them under the same label they had before the cleanup.
    @ViewBuilder
    private func archivedWorktreesGroup(repo: Repo) -> some View {
        let homePath = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath().path
        let worktreePaths = repo.projects.map {
            $0.workspace.path.resolvingSymlinksInPath().path
        }.filter { $0 != homePath && $0 != "/" }
        let (_, archived) = archiveCache.entriesByPresence(
            for: repo.id, worktreePaths: worktreePaths
        )
        if !archived.isEmpty {
            let isExpanded = expandedArchivedProjects.contains(repo.id)
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 10)
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Archived projects")
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
                    if isExpanded { expandedArchivedProjects.remove(repo.id) }
                    else { expandedArchivedProjects.insert(repo.id) }
                }
            }
            if isExpanded {
                let grouped = Dictionary(grouping: archived) {
                    $0.originatingWorktreeName
                }
                let names = grouped.keys.sorted()
                ForEach(names, id: \.self) { name in
                    archivedWorktreeSection(
                        repo: repo,
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
        repo: Repo,
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
            ArchivedSessionRow(repo: repo, entry: entry)
        }
    }

    @ViewBuilder
    private func worktreeGroup(repo: Repo, project: Project) -> some View {
        let diffJobId = project.tasks.first(where: {
            if case .diff = $0.kind { return true }
            return false
        })?.id
        let worktreeExpanded = expandedProjects.contains(project.id)
        let visibleTasks = project.tasks.filter { task in
            if case .diff = task.kind { return false }
            return true
        }
        let wtPath = ProjectPath(repo: repo.id, project: project.id)
        VStack(alignment: .leading, spacing: 0) {
            WorktreeHeaderRow(
                repo: repo,
                project: project,
                isExpanded: worktreeExpanded,
                diffJobId: diffJobId,
                selectedJobId: selectedJobId,
                anyChildThinking: worktreeAnyThinking(project),
                anyChildReady: worktreeAnyReady(project),
                anyChildJustReady: worktreeAnyJustReady(project),
                onToggle: {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if worktreeExpanded { expandedProjects.remove(project.id) }
                        else { expandedProjects.insert(project.id) }
                    }
                },
                onRename: {
                    renameProjectContext = RenameProjectContext(
                        projectPath: wtPath, currentName: project.name
                    )
                },
                onSelectDiff: {
                    if let diffJobId { onSelect(diffJobId) }
                },
                onNewShell: {
                    _Concurrency.Task {
                        await Self.spawnShell(at: wtPath, cwd: project.workspace.path, store: store)
                    }
                },
                onNewClaude: {
                    _Concurrency.Task {
                        await Self.spawnClaude(at: wtPath, cwd: project.workspace.path, store: store)
                    }
                },
                onContextMenu: {
                    projectMenu(repo: repo, project: project)
                },
                dragInfo: $sidebarDragInfo,
                onMoveTaskHere: { sourceTaskPath in
                    _Concurrency.Task {
                        await store.dispatch(.moveTask(from: sourceTaskPath, to: wtPath))
                    }
                }
            )
            if worktreeExpanded {
                ForEach(visibleTasks) { task in
                    let thisTaskPath = TaskPath(
                        repo: repo.id, project: project.id, task: task.id
                    )
                    TaskRow(
                        repo: repo,
                        task: task,
                        taskPath: thisTaskPath,
                        workspacePath: project.workspace.path,
                        selected: selectedJobId == task.id,
                        onTap: { onSelect(task.id) },
                        onRename: {
                            renameContext = RenameContext(
                                taskPath: thisTaskPath, currentName: task.name
                            )
                        },
                        onContextMenu: {
                            AnyView(taskMenu(repo: repo, project: project, task: task))
                        },
                        dragInfo: $sidebarDragInfo
                    )
                    // Anchor for ScrollViewReader.scrollTo when this
                    // task gets selected (e.g. via ⌘⇧M Enter).
                    .id(task.id)
                }
                // External convos whose cwd falls inside THIS project's
                // workspace: render here so they live with the project
                // they came from. Top padding sets it apart from the
                // task rows above so it doesn't read as a child of the
                // last task.
                let inProject = convosForProject(repo: repo, project: project)
                if !inProject.isEmpty {
                    externalConvosFolder(
                        repo: repo,
                        folderId: project.id,
                        title: "External convos",
                        convos: inProject,
                        indent: 24
                    )
                    .padding(.top, 6)
                }
            }
        }
    }

    // Stable alphabetical (case-insensitive) repo order in the
    // sidebar — independent of insertion order in state.json.
    private var sortedProjects: [Repo] {
        store.state.repos.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // (repoId, projectId) for the project that owns a given task.
    // Used by the ScrollViewReader handler to expand the path to
    // the selected row before scrolling into view.
    private func containingPath(taskId: UUID) -> (UUID, UUID)? {
        for repo in store.state.repos {
            for project in repo.projects {
                if project.tasks.contains(where: { $0.id == taskId }) {
                    return (repo.id, project.id)
                }
            }
        }
        return nil
    }

    private func claudeSid(_ task: Task) -> String? {
        if case let .claude(sid) = task.kind { return sid }
        return nil
    }

    private func worktreeAnyThinking(_ project: Project) -> Bool {
        for task in project.tasks {
            if activityTracker.isThinking(sid: claudeSid(task)) { return true }
        }
        return false
    }

    private func worktreeAnyReady(_ project: Project) -> Bool {
        for task in project.tasks {
            guard let sid = claudeSid(task) else { continue }
            if activityTracker.isThinking(sid: sid) { return false }
            if task.unread > 0 { return true }
        }
        return false
    }

    private func worktreeAnyJustReady(_ project: Project) -> Bool {
        for task in project.tasks {
            guard let sid = claudeSid(task), task.unread > 0 else { continue }
            if activityTracker.justBecameReady(sid: sid) { return true }
        }
        return false
    }

    private func repoAnyThinking(_ repo: Repo) -> Bool {
        repo.projects.contains { worktreeAnyThinking($0) }
    }

    private func repoAnyReady(_ repo: Repo) -> Bool {
        // Mirror the per-project precedence: thinking trumps ready.
        if repoAnyThinking(repo) { return false }
        return repo.projects.contains { worktreeAnyReady($0) }
    }

    private func repoAnyJustReady(_ repo: Repo) -> Bool {
        repo.projects.contains { worktreeAnyJustReady($0) }
    }

    // External convos whose cwd falls inside the given project's
    // workspace (or any descendant directory). Used to nest the convo
    // rows under the project they originated from.
    // AvailableWorktrees the sidebar should render for a repo.
    // - .manual: all of them (legacy behavior).
    // - .managed: only those inside `<repo>/<namespace>/`. Entries
    //   from a prior manual life (e.g. the repo root itself, or a
    //   sibling dir) are silently hidden — they're meaningless in
    //   the managed flow but stay in state.json in case the user
    //   flips the mode back.
    private func visibleAvailableWorktrees(for repo: Repo) -> [AvailableWorktree] {
        switch repo.worktreeMode {
        case .manual:
            return repo.availableWorktrees
        case .managed:
            let nsPrefix = repo.managedWorktreesDir.standardizedFileURL.path
            return repo.availableWorktrees.filter { wt in
                let p = wt.path.standardizedFileURL.path
                return p == nsPrefix || p.hasPrefix(nsPrefix + "/")
            }
        }
    }

    private func convosForProject(repo: Repo, project: Project) -> [ExternalConvo] {
        let wsPath = project.workspace.path.resolvingSymlinksInPath().path
        return repo.externalConvos.filter { convo in
            let cwdPath = convo.cwd.resolvingSymlinksInPath().path
            return cwdPath == wsPath || cwdPath.hasPrefix(wsPath + "/")
        }
    }

    // External convos whose cwd matches NO current project workspace.
    // Rendered at the repo level so a convo from a removed worktree
    // (or one never tracked) doesn't vanish.
    private func orphanConvos(repo: Repo) -> [ExternalConvo] {
        let workspacePaths = repo.projects.map {
            $0.workspace.path.resolvingSymlinksInPath().path
        }
        return repo.externalConvos.filter { convo in
            let cwdPath = convo.cwd.resolvingSymlinksInPath().path
            return !workspacePaths.contains { wsPath in
                cwdPath == wsPath || cwdPath.hasPrefix(wsPath + "/")
            }
        }
    }

    // Collapsible folder of ExternalConvoRows. Used by both the
    // in-project nesting (matched convos) and the repo-level
    // orphan group.
    @ViewBuilder
    private func externalConvosFolder(
        repo: Repo,
        folderId: UUID,
        title: String,
        convos: [ExternalConvo],
        indent: CGFloat
    ) -> some View {
        let isExpanded = expandedExternalConvoFolders.contains(folderId)
        // Section-label styling rather than list-row styling so the
        // folder reads as a group heading, not as another peer of the
        // tasks above it. Macros: smaller, uppercase, dimmer; the
        // chevron stays for the collapse affordance.
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text("\(convos.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary.opacity(0.7))
            Spacer()
        }
        .padding(.leading, indent)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded { expandedExternalConvoFolders.remove(folderId) }
                else { expandedExternalConvoFolders.insert(folderId) }
            }
        }
        if isExpanded {
            // Sort newest-first by the info-cache lastMessageAt.
            let cache = ExternalSessionInfoCache.shared
            let sorted = convos.sorted { a, b in
                let aWhen = cache.entries[a.sessionId]?.lastMessageAt ?? .distantPast
                let bWhen = cache.entries[b.sessionId]?.lastMessageAt ?? .distantPast
                return aWhen > bWhen
            }
            ForEach(sorted) { convo in
                ExternalConvoRow(
                    repo: repo,
                    convo: convo,
                    selected: selectedExternalConvoId == convo.id,
                    onTap: { onSelectConvo(convo.id) },
                    onContextMenu: {
                        AnyView(externalConvoMenu(repo: repo, convo: convo))
                    },
                    indent: indent + 8
                )
            }
        }
    }

    // Collapsible folder of archived (finished) projects under a
    // repo. Same shape as externalConvosFolder but the rows are
    // regular project rows so the user can still drill in to read
    // task scrollback or unarchive.
    @ViewBuilder
    private func finishedProjectsFolder(repo: Repo, archived: [Project]) -> some View {
        let isExpanded = expandedFinishedFolders.contains(repo.id)
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 10)
            Text("Finished")
                .font(.system(size: 10, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.6)
                .foregroundStyle(.tertiary)
            Text("\(archived.count)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary.opacity(0.7))
            Spacer()
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .padding(.vertical, 3)
        .padding(.top, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isExpanded { expandedFinishedFolders.remove(repo.id) }
                else { expandedFinishedFolders.insert(repo.id) }
            }
        }
        if isExpanded {
            // Newest-archived first so the recently-finished item is
            // at the top of the section.
            let sorted = archived.sorted {
                ($0.archivedAt ?? .distantPast) > ($1.archivedAt ?? .distantPast)
            }
            ForEach(sorted) { project in
                worktreeGroup(repo: repo, project: project)
                    .padding(.leading, 12)
                    .opacity(0.7)
            }
        }
    }

    @ViewBuilder
    private func externalConvoMenu(repo: Repo, convo: ExternalConvo) -> some View {
        Button("Dismiss") {
            let path = ExternalConvoPath(repo: repo.id, convo: convo.id)
            _Concurrency.Task {
                await store.dispatch(.dismissExternalConvo(at: path))
            }
        }
    }

    @ViewBuilder
    private func availableWorktreeMenu(
        repo: Repo, worktree: AvailableWorktree
    ) -> some View {
        Button("New project here…") {
            newWorktreeForRepo = repo
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([worktree.path])
        }
        Divider()
        Button("Remove from list", role: .destructive) {
            _Concurrency.Task {
                await store.dispatch(.removeAvailableWorktree(
                    repoId: repo.id, id: worktree.id
                ))
            }
        }
    }
}

private extension WorkspaceKind {
    var symbol: String {
        switch self {
        case .gitWorktree: return "arrow.triangle.branch"
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
    let projectPath: ProjectPath
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
        let repoId = taskPath.repo
        let live = transcriptURL
        let archive = safekeepingStore
        await _Concurrency.Task.detached(priority: .userInitiated) {
            // Prefer the safekept gzip: it survives even if
            // claude.ai's retention deleted the original. Decompress
            // to a temp .jsonl so the existing line-stream parser
            // works unchanged. Fall back to the live source if there
            // is no archive yet (hot, first-sweep cases).
            let urlForParse: URL?
            if archive.hasTranscript(sessionId: sid, for: repoId) {
                do {
                    let data = try archive.readArchivedTranscript(
                        sessionId: sid, for: repoId
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
                        .entries(for: repoId)
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
        let wt = projectPath
        let repo = store.state.repos.first(where: { $0.id == wt.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
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
               let newJob = store.state.repos
                    .first(where: { $0.id == wt.repo })?
                    .projects.first(where: { $0.id == wt.project })?
                    .tasks.first(where: {
                        if case let .claude(s) = $0.kind, s == sid { return true }
                        return false
                    }) {
                let newPath = TaskPath(
                    repo: wt.repo, project: wt.project, task: newJob.id
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
                let repo = store.state.repos.first(where: { $0.id == taskPath.repo })
                let invocation = ClaudeTaskSpec.resolveInvocation(
                    repo: repo, settings: store.state.settings
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
        // repo's color (both a light and a dark variant; libghostty
        // swaps automatically with the system appearance). Cache key
        // includes the color hex so a repo re-coloring rebuilds the
        // renderer next time it mounts.
        let repoColor = store.state.repos
            .first(where: { $0.id == taskPath.repo })?.color
            ?? "#808080"
        let theme = RepoThemeGenerator.theme(forProjectColor: repoColor)
        let renderer = TerminalRendererCache.shared.renderer(
            for: taskPath,
            themeKey: RepoThemeGenerator.cacheKey(forProjectColor: repoColor),
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
        // Strong reference in remote mode — the RemoteTaskIO is created
        // on demand and only this Coordinator holds it. Local AgentClient
        // / ManagedPTY survive via EffectRunner.ptys so a weak ref would
        // also work, but the strong ref is simpler + works for both modes.
        private var pty: TaskIO?
        private var taskPath: TaskPath?
        private var keyMonitor: Any?
        // Cached so bind(pty:) can push the renderer's last-known
        // size to the freshly-bound PTY (re-attach SIGWINCH fix).
        private var store: Store?

        deinit {
            if let monitor = keyMonitor { NSEvent.removeMonitor(monitor) }
        }

        func attach(renderer: LibGhosttyRenderer, store: Store, taskPath: TaskPath) {
            self.renderer = renderer
            self.taskPath = taskPath
            self.store = store
            renderer.inputHandler = { [weak self] data in self?.pty?.write(data) }
            let capturedTaskId = taskPath.task
            renderer.sizeHandler = { rows, cols in
                _Concurrency.Task { @MainActor in
                    guard let pty = await store.taskIO(for: capturedTaskId) else { return }
                    pty.resize(rows: UInt16(rows), cols: UInt16(cols))
                }
            }
            installKeyMonitor()

            _Concurrency.Task { [weak self] in
                for _ in 0..<200 {
                    if let pty = await store.taskIO(for: capturedTaskId) {
                        await MainActor.run { self?.bind(pty: pty) }
                        return
                    }
                    try? await _Concurrency.Task.sleep(nanoseconds: 25_000_000)
                }
            }
        }

        // fn+Up / fn+Down → scroll the terminal's scrollback instead
        // of forwarding PageUp/PageDown to the inner shell. macOS
        // delivers fn+Up as `specialKey == .pageUp` with the
        // `.function` modifier set — we gate on the modifier so a
        // bare PageUp (from a keyboard with a dedicated PgUp key)
        // still reaches the inner process.
        private func installKeyMonitor() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self,
                      let renderer = self.renderer,
                      event.window?.firstResponder === renderer.view,
                      event.modifierFlags.contains(.function)
                else { return event }
                switch event.specialKey {
                case .pageUp:
                    renderer.performBindingAction("scroll_page_up")
                    return nil
                case .pageDown:
                    renderer.performBindingAction("scroll_page_down")
                    return nil
                default:
                    return event
                }
            }
        }

        private func bind(pty: TaskIO) {
            self.pty = pty
            guard let renderer else { return }
            // Attach with replayCaptured: true so the agent's
            // in-memory PTY buffer is replayed through the async
            // data callback (DispatchQueue.main.async → feed). This
            // is the SAME path live PTY output uses, and it has
            // never hung.
            //
            // We do NOT pre-feed the on-disk scrollback.log: that
            // path goes through renderer.feed() synchronously,
            // which calls into libghostty's ghostty_surface_write_buffer.
            // That FFI parks the caller on a Zig futex waiting for
            // the renderer's kqueue consumer to drain, but in
            // practice the consumer thread misses the wakeup and
            // sits in kevent64 forever — locking the main thread.
            // Observed twice now (27 MB scrollback hang; then again
            // even with 512 KB chunked to 64 KB). The replay path
            // gives us reattach context without the synchronous FFI.
            //
            // Trade-off: long-term on-disk history isn't shown on
            // reattach; only what the agent has buffered since the
            // last detach. Acceptable until we can either replace
            // the renderer or understand libghostty's wakeup bug.
            renderer.attachToPTY(pty, replayCaptured: true)
            // Re-attach to a cached renderer often doesn't fire a
            // libghostty resize callback (the surface's own size
            // hasn't changed), but the underlying PTY's running
            // TUI may have lost layout since last attach. To force
            // a SIGWINCH we jiggle the size — one row off, then
            // back. Sending the same size as the kernel already
            // has is a no-op; the change is what triggers
            // TIOCSWINSZ → SIGWINCH → redraw. The jiggle is
            // imperceptible because the second resize lands on the
            // very next runloop tick.
            if let size = renderer.lastObservedSize {
                let realRows = UInt16(size.rows)
                let realCols = UInt16(size.cols)
                let jiggleRows = realRows > 1 ? realRows - 1 : realRows + 1
                let ptyRef = pty
                _Concurrency.Task { @MainActor in
                    ptyRef.resize(rows: jiggleRows, cols: realCols)
                    try? await _Concurrency.Task.sleep(nanoseconds: 30_000_000)  // 30ms
                    ptyRef.resize(rows: realRows, cols: realCols)
                }
            }
        }

    }
}

// MARK: - Workspace info bar

// Thin info strip below the breadcrumb. Surfaces the things that
// used to clutter the sidebar — workspace path, current git branch,
// ahead/behind, dirty marker. Click the path to reveal the workspace
// in Finder.
// NSVisualEffectView bridged to SwiftUI so we can give the sidebar
// a richer material than the default NavigationSplitView column
// background. The .underWindowBackground material is darker and
// more atmospheric than .sidebar — it sits "below" the window,
// reading as an excavated panel rather than a layered surface.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        view.isEmphasized = true
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

// One name segment in the detail-pane masthead. New York serif —
// same editorial face used by the sidebar rows, so the masthead
// reads as a continuation of the sidebar's typographic system
// rather than its own visual world.
private struct BreadcrumbSegment: View {
    let text: String
    let tint: SwiftUI.Color
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .font(.system(.title3, design: .serif).weight(weight))
            .tracking(-0.2)
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}

// Mono slash between breadcrumb segments. Chevrons read as
// navigation arrows ("click here to go back"); slashes read as
// path delimiters, which is what they are here.
private struct BreadcrumbDivider: View {
    var body: some View {
        Text("/")
            .font(.system(.title3, design: .monospaced))
            .foregroundStyle(.tertiary.opacity(0.6))
    }
}

private struct WorkspaceInfoBar: View {
    let repo: Repo
    let project: Project
    @ObservedObject private var statsCache = WorktreeStatsCache.shared

    var body: some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [project.workspace.path]
                )
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                    Text(displayPath)
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder — \(project.workspace.path.path)")
            if project.workspace.path == repo.rootDir {
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.yellow.opacity(0.85))
                    .help("Repo root")
            }
            if project.workspace.missing {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("missing")
                        .font(.system(size: 11, design: .rounded))
                }
                .foregroundStyle(.orange)
            }
            if let stats = statsCache.stats[project.id] {
                if let branch = stats.branch {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.branch")
                            .font(.system(size: 10))
                        Text(branch)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let d = stats.defaultBranch {
                            Text("vs \(d)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                if stats.insertions > 0 || stats.deletions > 0 {
                    HStack(spacing: 6) {
                        if stats.insertions > 0 {
                            Text("+\(stats.insertions)")
                                .font(.system(size: 11, design: .monospaced).weight(.medium))
                                .foregroundStyle(SwiftUI.Color.green.opacity(0.85))
                        }
                        if stats.deletions > 0 {
                            Text("−\(stats.deletions)")
                                .font(.system(size: 11, design: .monospaced).weight(.medium))
                                .foregroundStyle(SwiftUI.Color.red.opacity(0.85))
                        }
                    }
                    .help("Lines changed vs \(stats.defaultBranch ?? "default branch")")
                }
                if stats.ahead > 0 {
                    Text("↑\(stats.ahead)")
                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                        .foregroundStyle(.green.opacity(0.85))
                        .help("Commits ahead of \(stats.defaultBranch ?? "default branch")")
                }
                if stats.behind > 0 {
                    Text("↓\(stats.behind)")
                        .font(.system(size: 11, design: .monospaced).weight(.medium))
                        .foregroundStyle(.orange.opacity(0.85))
                        .help("Commits behind \(stats.defaultBranch ?? "default branch")")
                }
                if stats.hasConflicts {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .font(.system(size: 10))
                        Text("conflicts")
                            .font(.system(size: 11, design: .rounded).weight(.medium))
                    }
                    .foregroundStyle(.red.opacity(0.95))
                    .help("Unresolved conflicts in this workspace")
                }
                if stats.hasUncommitted {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil.tip")
                            .font(.system(size: 10))
                        Text("dirty")
                            .font(.system(size: 11, design: .rounded))
                    }
                    .foregroundStyle(.yellow.opacity(0.9))
                    .help("Uncommitted changes")
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    // Show the path tilde-collapsed if it's under $HOME — easier to
    // scan than a full absolute path for the usual case.
    private var displayPath: String {
        let raw = project.workspace.path.path
        let home = NSHomeDirectory()
        if raw == home { return "~" }
        if raw.hasPrefix(home + "/") {
            return "~" + raw.dropFirst(home.count)
        }
        return raw
    }
}

// MARK: - External convo detail view

// Shown in the detail pane when an external convo is selected in the
// sidebar. Surfaces the session metadata from the FSEvents-watcher
// cache and offers an Adopt button. Adoption spawns a Mani-managed
// `claude --resume <sid>` against a target project and removes the
// convo from the external list.
private struct ExternalConvoView: View {
    let repo: Repo
    let convo: ExternalConvo
    let onAdopted: () -> Void
    @EnvironmentObject var store: Store
    @EnvironmentObject var watcher: ClaudeWatcher
    @ObservedObject private var infoCache = ExternalSessionInfoCache.shared

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
                HStack {
                    Spacer()
                    Button("Adopt into Mani") { adopt() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(adoptTargetProject() == nil)
                }
                if adoptTargetProject() == nil {
                    Text("No project in this repo to adopt into. Create one first.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
            .frame(maxWidth: 760)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("External Claude session")
                    .font(.title3.weight(.semibold))
                Text("Discovered on disk — Mani isn't running this one. Adopt it to take over (Mani spawns `claude --resume <sid>` against the matching project).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var summary: some View {
        let info = infoCache.entries[convo.sessionId]
        let session = watcher.sessions[convo.sessionId]
        let messageCount = info?.messageCount ?? session?.messageCount
        let lastMessageAt = info?.lastMessageAt ?? session?.lastMessageAt
        VStack(alignment: .leading, spacing: 4) {
            labelled("Session", convo.sessionId)
            labelled("cwd", convo.cwd.path)
            labelled("First seen", Self.relativeFormatter.localizedString(
                for: convo.firstSeenAt, relativeTo: Date()
            ))
            if let messageCount {
                labelled("Messages", "\(messageCount)")
            }
            if let lastMessageAt {
                labelled("Last activity", Self.relativeFormatter.localizedString(
                    for: lastMessageAt, relativeTo: Date()
                ))
            }
            if let first = info?.firstUserMessage, !first.isEmpty {
                labelled("First user message", first)
            }
            if let target = adoptTargetProject() {
                labelled("Adopt into", target.name)
            }
        }
    }

    private func labelled(_ key: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(key).font(.caption).foregroundStyle(.secondary).frame(width: 130, alignment: .trailing)
            Text(value).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            Spacer()
        }
    }

    // Prefer a project whose workspace path contains the convo's cwd
    // (or equals it). Falls back to the first project so adoption is
    // possible even if the convo lives in a now-orphaned directory.
    private func adoptTargetProject() -> Project? {
        let cwdPath = convo.cwd.resolvingSymlinksInPath().path
        if let match = repo.projects.first(where: { project in
            let p = project.workspace.path.resolvingSymlinksInPath().path
            return cwdPath == p || cwdPath.hasPrefix(p + "/")
        }) {
            return match
        }
        return repo.projects.first
    }

    private func adopt() {
        guard let target = adoptTargetProject() else { return }
        let convoPath = ExternalConvoPath(repo: repo.id, convo: convo.id)
        let projectPath = ProjectPath(repo: repo.id, project: target.id)
        let suffix = String(convo.sessionId.prefix(6))
        let name = "claude (adopted \(suffix))"
        _Concurrency.Task {
            await store.dispatch(.adoptExternalConvo(
                at: convoPath, into: projectPath, name: name
            ))
            await MainActor.run { onAdopted() }
        }
    }
}
