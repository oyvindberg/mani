import Foundation
import ManiCore

// The only place I/O happens. Owns the live ManagedPTY instances keyed by
// JobPath, drives PersistenceStore, and dispatches actions back to the
// Store via the closure passed in.
//
// docs/architecture.md § "The effect runner".

actor EffectRunner {
    private let persistence: PersistenceStore
    private var ptys: [JobPath: ManagedPTY] = [:]
    private var scrollbacks: [JobPath: ScrollbackWriter] = [:]
    private var scrollbackSubscriptions: [JobPath: ManagedPTY.OutputSubscription] = [:]

    init(persistence: PersistenceStore) {
        self.persistence = persistence
    }

    private var scrollbackRoot: URL {
        persistence.rootDir.appendingPathComponent("tasks")
    }

    func pty(for path: JobPath) -> ManagedPTY? {
        ptys[path]
    }

    func run(_ effect: Effect, dispatch: @escaping (Action) async -> Void) async {
        switch effect {

        case let .persistEvents(events):
            for event in events {
                try? persistence.appendEvent(event)
            }

        case .writeSnapshot:
            // The runner doesn't know AppState; the Store hands it to us
            // explicitly via `compact(_:)`. Treating .writeSnapshot as a
            // no-op here keeps the effect→runner protocol clean.
            break

        case let .spawn(path, index, spec):
            do {
                var env = ProcessInfo.processInfo.environment
                for (k, v) in spec.env { env[k] = v }
                env["TERM"] = "xterm-256color"
                env["COLORTERM"] = "truecolor"
                // Terminal.app and iTerm advertise themselves via TERM_PROGRAM;
                // some TUIs (claude code's UI library among them) gate
                // full-repaint-on-resize on the presence of a recognized value.
                // Setting it lets claude believe it's in a smart terminal.
                // Pose as ghostty so TUIs that special-case ghostty's
                // capabilities (claude code's full-redraw-on-SIGWINCH path
                // among them) take that branch. The renderer IS libghostty,
                // so this isn't a lie — just an honest advertisement.
                env["TERM_PROGRAM"] = "ghostty"
                // Strip env vars that leak in from whichever shell launched
                // Mani (e.g. Terminal.app via `open`). A stale TERM_SESSION_ID
                // or TERM_PROGRAM_VERSION from another terminal confuses TUIs
                // that key off them.
                for k in ["TERM_PROGRAM_VERSION", "TERM_SESSION_ID",
                          "ITERM_SESSION_ID", "ITERM_PROFILE",
                          "LC_TERMINAL", "LC_TERMINAL_VERSION"] {
                    env.removeValue(forKey: k)
                }
                // App-launched processes inherit a stripped PATH from launchd
                // that doesn't include user-installed binary directories, so
                // `env claude` (and any other tool not in /usr/bin) fails with
                // ENOENT. Prepend the conventional user bin paths.
                let homeBin = "\(NSHomeDirectory())/.local/bin"
                let extraPath = "\(homeBin):/opt/homebrew/bin:/usr/local/bin"
                let existing = env["PATH"] ?? "/usr/bin:/bin"
                env["PATH"] = "\(extraPath):\(existing)"
                // rawMode=true if any of the args mention claude. The user's
                // manual flow (typing claude at zsh prompt) leaves termios
                // in ZLE's raw mode when claude starts; reproducing that at
                // exec time appears to be what claude's full-redraw branch
                // is actually keying on.
                let mentionsClaude = spec.args.contains(where: { $0.contains("claude") })
                let pty = try ManagedPTY(
                    executable: spec.command,
                    args: spec.args,
                    env: env,
                    cwd: spec.cwd.path,
                    rawMode: mentionsClaude
                )
                ptys[path] = pty
                pty.onExit = { code in
                    Task { await dispatch(.processExited(at: path, index: index, code: code)) }
                }

                // Tier 1 scrollback: tee the same byte stream the renderer uses
                // into ~/Library/Application Support/Mani/tasks/<job-id>/scrollback.log.
                let scrollbackPath = scrollbackRoot
                    .appendingPathComponent(path.job.uuidString)
                    .appendingPathComponent("scrollback.log").path
                let writer = ScrollbackWriter(path: scrollbackPath, capBytes: 32 * 1024 * 1024)
                let sub = pty.addOutputHandler { data in writer.append(data) }
                scrollbacks[path] = writer
                scrollbackSubscriptions[path] = sub

                await dispatch(.processStarted(at: path, index: index, pid: pty.pid))
            } catch {
                await dispatch(.processExited(at: path, index: index, code: -1))
            }

        case let .terminate(pid, escalate):
            // Find the PTY by pid. ManagedPTY.terminate blocks until the child
            // has been reaped, so wrap in Task.detached to avoid wedging the actor.
            for pty in ptys.values where pty.pid == pid {
                let captured = pty
                Task.detached { captured.terminate(escalateAfter: escalate) }
                break
            }

        case let .userNotification(title, body):
            NotificationService.shared.post(title: title, body: body)

        case let .createGitWorktree(_, repoRoot, branch, path, baseRef):
            await Self.runGitWorktreeAdd(
                repoRoot: repoRoot,
                branch: branch,
                path: path,
                baseRef: baseRef
            )

        case .archive, .watchClaudeProjects:
            // Not implemented yet; archive = task completion → compress &
            // rotate scrollback. watchClaudeProjects is a hint for the
            // ClaudeWatcher service which is started directly from ManiApp.
            break
        }
    }

    // Returns nothing; caller pattern is fire-and-forget. Errors are NSLog'd.
    private static func runGitWorktreeAdd(
        repoRoot: URL,
        branch: String,
        path: URL,
        baseRef: String?
    ) async {
        // Prune stale metadata first so a previously-deleted same-path worktree
        // doesn't block this add. See docs/git-worktree.md case 3.
        _ = await runGit(args: ["worktree", "prune"], cwd: repoRoot)

        var addArgs = ["worktree", "add", path.path]
        if let baseRef {
            addArgs.append(contentsOf: ["-b", branch, baseRef])
        } else {
            addArgs.append(branch)
        }
        let result = await runGit(args: addArgs, cwd: repoRoot)
        if result.exit != 0 {
            NSLog("[mani] git worktree add failed exit=\(result.exit) stderr=\(result.stderr)")
            return
        }

        // If the new worktree contains submodules, init them so the user gets
        // a usable checkout. See docs/git-worktree.md case 5.
        let gitmodules = path.appendingPathComponent(".gitmodules")
        if FileManager.default.fileExists(atPath: gitmodules.path) {
            _ = await runGit(args: ["submodule", "update", "--init", "--recursive"], cwd: path)
        }
    }

    private static func runGit(args: [String], cwd: URL) async -> (exit: Int32, stdout: String, stderr: String) {
        await withCheckedContinuation { (cont: CheckedContinuation<(exit: Int32, stdout: String, stderr: String), Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
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

    func compact(_ state: AppState) async {
        try? persistence.compact(state)
    }

    func recover() throws -> AppState {
        try persistence.recover().state
    }
}
