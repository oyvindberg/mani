import SwiftUI
import ManiCore
import Foundation

// Minimal v0.1 creation dialogs. Color picking, swatch palette, branch
// dropdown for git projects, etc. come later — see docs/ui.md.

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
            Text("The repo root anchors `git project add` and shows as the repo's main workspace. Additional projects can be added after creation.")
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
                        // existing ~/.claude/projects sessions for
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
        case git = "Git project"
        var id: String { rawValue }
    }

    @State private var name: String = ""
    @State private var path: String = NSHomeDirectory()
    @State private var kind: Kind = .folder
    @State private var branch: String = ""
    @State private var baseRef: String = "origin/main"
    @State private var addShellTask: Bool = true
    // Tracks whether the user has manually edited the branch field.
    // Managed-mode auto-derives the branch from the slug as the user
    // types, but only until they override it explicitly.
    @State private var branchEdited: Bool = false
    @State private var baseRefAutoResolved: Bool = false

    private var repo: Repo? {
        store.state.repos.first(where: { $0.id == repoId })
    }

    private var isManaged: Bool {
        repo?.worktreeMode == .managed
    }

    private var slug: String {
        slugifyProjectName(name)
    }

    private var managedTargetPath: URL? {
        guard let repo else { return nil }
        return repo.managedWorktreesDir.appendingPathComponent(slug)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isManaged ? "New managed project" : "New project")
                .font(.headline)
            if isManaged {
                managedForm
            } else {
                manualForm
            }
            Text("A project is a unit of intent — name it for what you're working on.")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { onCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreateDisabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .task {
            // Resolve the repo's actual default branch lazily —
            // depends on git config (origin/main, origin/master,
            // origin/trunk, etc.). Don't clobber a value the user
            // has already typed.
            guard !baseRefAutoResolved else { return }
            baseRefAutoResolved = true
            if let resolved = await Self.resolveDefaultBranch(repo: repo) {
                if baseRef == "origin/main" || baseRef == "main" {
                    baseRef = resolved
                }
            }
        }
    }

    // Async git probe for `origin/HEAD`. Off-main via Process so
    // the sheet doesn't block during typical 10-100ms exec.
    private static func resolveDefaultBranch(repo: Repo?) async -> String? {
        guard let repo else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                task.currentDirectoryURL = repo.rootDir
                task.arguments = ["symbolic-ref", "--short", "refs/remotes/origin/HEAD"]
                let out = Pipe()
                task.standardOutput = out
                task.standardError = Pipe()
                do {
                    try task.run()
                    task.waitUntilExit()
                    guard task.terminationStatus == 0 else {
                        cont.resume(returning: nil); return
                    }
                    let data = (try? out.fileHandleForReading.readToEnd()) ?? Data()
                    let s = String(data: data, encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    cont.resume(returning: (s?.isEmpty ?? true) ? nil : s)
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: Managed form

    @ViewBuilder
    private var managedForm: some View {
        Form {
            TextField("Name", text: $name)
            TextField("Branch", text: Binding(
                get: {
                    branchEdited ? branch : (name.isEmpty ? "" : slug)
                },
                set: { newValue in
                    branch = newValue
                    branchEdited = true
                }
            ))
            TextField("Base ref", text: $baseRef, prompt: Text("origin/main"))
            Toggle("Add a default shell task", isOn: $addShellTask)
        }
        if let target = managedTargetPath {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                Text(target.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if FileManager.default.fileExists(atPath: target.path) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text("A directory already exists at this path — git worktree add will fail.")
                        .font(.caption)
                }
                .foregroundStyle(.orange)
            }
        }
    }

    // MARK: Manual form (legacy path, unchanged)

    @ViewBuilder
    private var manualForm: some View {
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
    }

    private var isCreateDisabled: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if isManaged {
            return trimmedName.isEmpty
        }
        return path.isEmpty || (kind == .git && branch.isEmpty)
    }

    // MARK: Create dispatch

    private func onCreate() {
        if isManaged {
            createManaged()
        } else {
            createManual()
        }
    }

    private func createManaged() {
        guard let repo,
              let target = managedTargetPath
        else { return }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "wip" : trimmedName
        let chosenBranch = branchEdited
            ? branch.trimmingCharacters(in: .whitespacesAndNewlines)
            : slug
        let chosenBase = baseRef.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseOrDefault = chosenBase.isEmpty ? "origin/main" : chosenBase
        let workspaceKind: WorkspaceKind = .gitWorktree(
            branch: chosenBranch.isEmpty ? slug : chosenBranch,
            baseRef: baseOrDefault,
            managed: true
        )
        let workspace = Workspace(path: target, kind: workspaceKind, missing: false)
        let wantShell = addShellTask
        let repoId = repo.id
        let cwd = target
        // @MainActor: the trailing isPresented = false has to land
        // on main for SwiftUI to pick up the binding change and
        // dismiss the sheet. A bare `Task { … }` runs on the global
        // executor by default; the binding write from there is a
        // silent no-op.
        // Close the sheet immediately — the actual creation work
        // continues in the background Task below. If `git worktree
        // add` fails, the EffectRunner surfaces a user notification
        // with the git error; the sheet has already gone away.
        isPresented = false
        let storeRef = store
        let sweeperRef = sweeper
        _Concurrency.Task { @MainActor in
            await storeRef.dispatch(.createProject(
                repoId: repoId, name: finalName, workspace: workspace
            ))
            guard let repo = storeRef.state.repos.first(where: { $0.id == repoId }),
                  let project = repo.projects.last else { return }
            // The createGitWorktree effect dispatches as a detached
            // Task — dispatch returns before `git worktree add`
            // finishes. Spawning shell/diff tasks before the
            // worktree dir exists makes the agent's chdir fail and
            // the shell starts in `/`. Poll for the dir's `.git`
            // marker, which appears as soon as `git worktree add`
            // has registered the worktree.
            let ready = await Self.waitForManagedWorktreeReady(
                at: cwd, timeoutSeconds: 8.0
            )
            guard ready else {
                NSLog("[mani] managed worktree didn't materialise at \(cwd.path) within 8s")
                return
            }
            let wtPath = ProjectPath(repo: repoId, project: project.id)
            if wantShell {
                let spec = ProcessSpec(
                    command: "/bin/zsh", args: ["-l"], env: [:],
                    cwd: cwd, initialInput: nil
                )
                await storeRef.dispatch(.createTask(
                    at: wtPath, name: "shell", kind: .shell,
                    spec: spec, autoSelect: true
                ))
            }
            // Managed worktrees are always git checkouts → spawn diff.
            await SidebarView.spawnDiff(at: wtPath, cwd: cwd, store: storeRef)
            await sweeperRef.runOnce()
        }
    }

    // Block until the freshly-requested worktree at `path` is on
    // disk, or until the timeout. The probe is the `.git` marker
    // inside the worktree — `git worktree add` creates that file
    // synchronously when it registers the new worktree, even
    // before all checked-out files have been written. That's the
    // earliest point at which a shell can safely chdir there.
    private static func waitForManagedWorktreeReady(
        at path: URL, timeoutSeconds: Double
    ) async -> Bool {
        let marker = path.appendingPathComponent(".git")
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            try? await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    private func createManual() {
        let worktreeKind: WorkspaceKind = (kind == .git)
            ? .gitWorktree(
                branch: branch.isEmpty ? "main" : branch,
                baseRef: baseRef.isEmpty ? nil : baseRef,
                managed: false
            )
            : .folder
        let pathURL = URL(fileURLWithPath: path)
        let wantShell = addShellTask
        let repoId = repoId
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmedName.isEmpty ? "wip" : trimmedName
        _Concurrency.Task {
            await store.dispatch(.createProject(
                repoId: repoId,
                name: finalName,
                workspace: Workspace(
                    path: pathURL,
                    kind: worktreeKind,
                    missing: false
                )
            ))
            guard let repo = store.state.repos.first(where: { $0.id == repoId }),
                  let project = repo.projects.last else {
                isPresented = false
                return
            }
            let wtPath = ProjectPath(
                repo: repoId, project: project.id
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
            if ManiApp.isGitCheckout(at: pathURL) {
                await SidebarView.spawnDiff(
                    at: wtPath, cwd: pathURL, store: store
                )
            }
            await sweeper.runOnce()
            isPresented = false
        }
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

// MARK: - New project from existing PR

// Right-click on a repo → "New project from PR…" surfaces this.
// Shells `gh pr list` in the repo's rootDir, lets the user pick an
// open PR, then materialises it as a managed-style git worktree
// checked out at the PR's headRefName. Fork PRs are surfaced but
// disabled (v1 limitation — fork branches aren't on `origin`).
struct NewProjectFromPRSheet: View {
    let store: Store
    let repoId: UUID
    @Binding var isPresented: Bool
    @EnvironmentObject var sweeper: SafekeepingSweeper

    struct PullRequest: Identifiable, Hashable {
        let number: Int
        let title: String
        let headRefName: String
        let authorLogin: String
        let updatedAt: Date?
        let isCrossRepository: Bool
        var id: Int { number }
    }

    enum LoadState {
        case loading
        case loaded([PullRequest])
        case error(String)
    }

    @State private var loadState: LoadState = .loading
    @State private var selectedNumber: Int?
    @State private var projectName: String = ""
    @State private var nameEdited: Bool = false
    @State private var creating: Bool = false

    private var repo: Repo? {
        store.state.repos.first(where: { $0.id == repoId })
    }

    private var selectedPR: PullRequest? {
        guard let selectedNumber, case let .loaded(prs) = loadState else { return nil }
        return prs.first(where: { $0.number == selectedNumber })
    }

    private var derivedName: String {
        guard let pr = selectedPR else { return "" }
        return "pr-\(pr.number)-\(slugifyProjectName(pr.title))"
    }

    private var effectiveName: String {
        nameEdited ? projectName : derivedName
    }

    private var managedTargetPath: URL? {
        guard let repo else { return nil }
        let slug = slugifyProjectName(effectiveName)
        guard !slug.isEmpty else { return nil }
        return repo.managedWorktreesDir.appendingPathComponent(slug)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New project from PR").font(.headline)
            switch loadState {
            case .loading:
                loadingView
            case .error(let message):
                errorView(message: message)
            case .loaded(let prs):
                loadedView(prs: prs)
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Button(creating ? "Creating…" : "Create") { onCreate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isCreateDisabled)
            }
        }
        .padding(20)
        .frame(width: 620, height: 480)
        .task { await loadPRs() }
    }

    @ViewBuilder
    private var loadingView: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("Loading open PRs via `gh`…")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Couldn't load PRs").font(.subheadline.weight(.semibold))
            }
            Text(message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("Mani uses the `gh` CLI. Install it with `brew install gh` and run `gh auth login`.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func loadedView(prs: [PullRequest]) -> some View {
        if prs.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("No open PRs found.")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            prList(prs: prs)
            Divider()
            Form {
                TextField("Project name", text: Binding(
                    get: { nameEdited ? projectName : derivedName },
                    set: { newValue in projectName = newValue; nameEdited = true }
                ))
            }
            if let target = managedTargetPath {
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(target.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if FileManager.default.fileExists(atPath: target.path) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                        Text("A directory already exists at this path — git worktree add will fail.")
                            .font(.caption)
                    }
                    .foregroundStyle(.orange)
                }
            }
        }
    }

    @ViewBuilder
    private func prList(prs: [PullRequest]) -> some View {
        List(prs, selection: $selectedNumber) { pr in
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(pr.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text(pr.title).lineLimit(1)
                    if pr.isCrossRepository {
                        Text("(fork — not supported yet)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 8) {
                    Text(pr.headRefName)
                        .font(.system(.caption2, design: .monospaced))
                    Text("by \(pr.authorLogin)").font(.caption2)
                    if let updated = pr.updatedAt {
                        Text(updated, style: .relative).font(.caption2)
                    }
                }
                .foregroundStyle(.secondary)
            }
            .tag(pr.number)
            .contentShape(Rectangle())
        }
        .frame(maxHeight: .infinity)
    }

    private var isCreateDisabled: Bool {
        if creating { return true }
        guard let pr = selectedPR, !pr.isCrossRepository else { return true }
        let trimmed = effectiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty
    }

    private func onCreate() {
        guard let repo, let pr = selectedPR, !pr.isCrossRepository,
              let target = managedTargetPath else { return }
        let finalName = effectiveName.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = pr.headRefName
        let managed = repo.worktreeMode == .managed
        let workspace = Workspace(
            path: target,
            kind: .gitWorktree(branch: branch, baseRef: nil, managed: managed),
            missing: false
        )
        let repoRoot = repo.rootDir
        let repoId = repo.id
        creating = true
        let storeRef = store
        let sweeperRef = sweeper
        _Concurrency.Task { @MainActor in
            // Fetch the PR branch into refs/remotes/origin/<branch>
            // so that `git worktree add <path> <branch>` can DWIM a
            // local tracking branch. Failure here is non-fatal —
            // the user may have a stale checkout but the branch
            // may already be local; let `git worktree add` decide.
            _ = await Self.runGitFetch(repoRoot: repoRoot, branch: branch)
            await storeRef.dispatch(.createProject(
                repoId: repoId, name: finalName, workspace: workspace
            ))
            isPresented = false
            guard let updatedRepo = storeRef.state.repos.first(where: { $0.id == repoId }),
                  let project = updatedRepo.projects.last else { return }
            let ready = await Self.waitForWorktreeReady(
                at: target, timeoutSeconds: 8.0
            )
            guard ready else {
                NSLog("[mani] PR worktree didn't materialise at \(target.path) within 8s")
                return
            }
            let projectPath = ProjectPath(repo: repoId, project: project.id)
            let shellSpec = ProcessSpec(
                command: "/bin/zsh", args: ["-l"], env: [:],
                cwd: target, initialInput: nil
            )
            await storeRef.dispatch(.createTask(
                at: projectPath, name: "shell", kind: .shell,
                spec: shellSpec, autoSelect: true
            ))
            await SidebarView.spawnDiff(at: projectPath, cwd: target, store: storeRef)
            await sweeperRef.runOnce()
        }
    }

    private static func waitForWorktreeReady(
        at path: URL, timeoutSeconds: Double
    ) async -> Bool {
        let marker = path.appendingPathComponent(".git")
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: marker.path) {
                return true
            }
            try? await _Concurrency.Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    // MARK: gh + git probes

    private func loadPRs() async {
        guard let repo else {
            loadState = .error("Repo not found.")
            return
        }
        guard let ghPath = Self.locateGh() else {
            loadState = .error(
                "Couldn't find the `gh` executable. Checked /opt/homebrew/bin, /usr/local/bin, /opt/local/bin."
            )
            return
        }
        let result = await Self.runProcess(
            executable: ghPath,
            args: [
                "pr", "list",
                "--state", "open",
                "--limit", "100",
                "--json", "number,title,headRefName,author,updatedAt,isCrossRepository"
            ],
            cwd: repo.rootDir
        )
        guard result.exit == 0 else {
            loadState = .error(result.stderr.isEmpty
                ? "gh exited with status \(result.exit)."
                : result.stderr)
            return
        }
        do {
            let prs = try Self.parsePRs(jsonText: result.stdout)
            loadState = .loaded(prs)
        } catch {
            loadState = .error("Failed to parse `gh` output: \(error.localizedDescription)")
        }
    }

    private static func parsePRs(jsonText: String) throws -> [PullRequest] {
        struct AuthorRaw: Decodable { let login: String? }
        struct PRRaw: Decodable {
            let number: Int
            let title: String
            let headRefName: String
            let author: AuthorRaw?
            let updatedAt: String?
            let isCrossRepository: Bool?
        }
        let data = jsonText.data(using: .utf8) ?? Data()
        let decoder = JSONDecoder()
        let raw = try decoder.decode([PRRaw].self, from: data)
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let isoNoFrac = ISO8601DateFormatter()
        isoNoFrac.formatOptions = [.withInternetDateTime]
        return raw.map { r in
            let updated: Date? = r.updatedAt.flatMap { s in
                iso.date(from: s) ?? isoNoFrac.date(from: s)
            }
            return PullRequest(
                number: r.number,
                title: r.title,
                headRefName: r.headRefName,
                authorLogin: r.author?.login ?? "?",
                updatedAt: updated,
                isCrossRepository: r.isCrossRepository ?? false
            )
        }
    }

    private static func locateGh() -> String? {
        let candidates = [
            "/opt/homebrew/bin/gh",
            "/usr/local/bin/gh",
            "/opt/local/bin/gh"
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func runGitFetch(repoRoot: URL, branch: String) async -> Int32 {
        let refspec = "+\(branch):refs/remotes/origin/\(branch)"
        let result = await runProcess(
            executable: "/usr/bin/git",
            args: ["fetch", "origin", refspec],
            cwd: repoRoot
        )
        if result.exit != 0 {
            NSLog("[mani] git fetch origin \(refspec) failed exit=\(result.exit) stderr=\(result.stderr)")
        }
        return result.exit
    }

    private static func runProcess(
        executable: String, args: [String], cwd: URL
    ) async -> (exit: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(exit: Int32, stdout: String, stderr: String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: executable)
                task.currentDirectoryURL = cwd
                task.arguments = args
                let outPipe = Pipe()
                let errPipe = Pipe()
                task.standardOutput = outPipe
                task.standardError = errPipe
                do {
                    try task.run()
                    task.waitUntilExit()
                    let outData = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    let errData = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    cont.resume(returning: (
                        task.terminationStatus,
                        String(data: outData, encoding: .utf8) ?? "",
                        String(data: errData, encoding: .utf8) ?? ""
                    ))
                } catch {
                    cont.resume(returning: (-1, "", "\(error)"))
                }
            }
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

struct RenameRepoSheet: View {
    let store: Store
    let repoId: UUID
    let currentName: String
    @Binding var isPresented: Bool
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename repo").font(.headline)
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
            await store.dispatch(.renameRepo(id: repoId, name: final))
            isPresented = false
        }
    }
}

struct RenameProjectSheet: View {
    let store: Store
    let projectPath: ProjectPath
    let currentName: String
    @Binding var isPresented: Bool
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename project").font(.headline)
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
            await store.dispatch(.renameProject(at: projectPath, name: final))
            isPresented = false
        }
    }
}

struct ResumeClaudeSheet: View {
    let store: Store
    let projectPath: ProjectPath
    let cwd: URL
    @Binding var isPresented: Bool
    var onCreated: ((UUID) -> Void)?
    @EnvironmentObject var archiveCache: SessionArchiveCache

    // Filter the repo-wide cache down to sessions whose
    // originating cwd matches this project. Cheap — the cache is
    // already in memory after boot's bootstrap + first sweep, so no
    // disk scan on open.
    private var sessions: [SessionIndexEntry] {
        let cwdPath = cwd.path
        let cwdPrefix = cwdPath + "/"
        return archiveCache.entries(for: projectPath.repo)
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
        let repo = store.state.repos.first(where: { $0.id == projectPath.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: sessionId, invocation: invocation)
        _Concurrency.Task {
            await store.dispatch(.createTask(
                at: projectPath,
                name: "claude (resumed \(sessionId.prefix(6)))",
                kind: .claude(sessionId: sessionId),
                spec: spec,
                autoSelect: true
            ))
            if let id = store.state.repos
                .first(where: { $0.id == projectPath.repo })?
                .projects.first(where: { $0.id == projectPath.project })?
                .tasks.last?.id
            {
                onCreated?(id)
            }
            isPresented = false
        }
    }

    private func startFresh() {
        let repo = store.state.repos.first(where: { $0.id == projectPath.repo })
        let invocation = ClaudeTaskSpec.resolveInvocation(
            repo: repo, settings: store.state.settings
        )
        let spec = ClaudeTaskSpec.make(cwd: cwd, sessionId: nil, invocation: invocation)
        _Concurrency.Task {
            await store.dispatch(.createTask(
                at: projectPath, name: "claude",
                kind: .claude(sessionId: nil),
                spec: spec,
                autoSelect: true
            ))
            if let id = store.state.repos
                .first(where: { $0.id == projectPath.repo })?
                .projects.first(where: { $0.id == projectPath.project })?
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
    let projectPath: ProjectPath
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
                    let claudeRepo = store.state.repos.first(where: { $0.id == projectPath.repo })
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
                            at: projectPath,
                            name: taskName,
                            kind: taskKind,
                            spec: spec,
                            autoSelect: true
                        ))
                        if let id = store.state.repos
                            .first(where: { $0.id == projectPath.repo })?
                            .projects.first(where: { $0.id == projectPath.project })?
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
