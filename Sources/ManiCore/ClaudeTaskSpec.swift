import Foundation

// Single source of truth for the ProcessSpec used to spawn `claude`.
//
// Background: claude's TUI doesn't fully reflow on SIGWINCH when launched
// directly via forkpty + execve, but DOES reflow when launched by a real
// interactive shell typing the command at its prompt. The workaround is
// to spawn `/bin/zsh -l` and then write `claude\r` (or
// `claude --resume <id>\r`) into the master FD ~800 ms after fork — long
// enough for zsh to source rc files and render its prompt. The agent
// schedules the write internally; ProcessSpec.initialInput carries the
// bytes.
//
// Why centralize here: every place that creates a claude task funnels
// through `.make`, so a format change is local. `.restartSpec` re-derives
// the current spec rather than reusing the persisted one — that severs
// the stale-spec trap where a Restart used a pre-zsh-injection invocation
// from an old build.
public enum ClaudeTaskSpec {
    public static func make(
        cwd: URL,
        sessionId: String?,
        invocation: String
    ) -> ProcessSpec {
        let trimmed = invocation.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = trimmed.isEmpty ? "claude" : trimmed
        let typed: String
        if let sessionId {
            typed = "\(prefix) --resume \(sessionId)\r"
        } else {
            typed = "\(prefix)\r"
        }
        return ProcessSpec(
            command: "/bin/zsh",
            args: ["-l"],
            env: [:],
            cwd: cwd,
            initialInput: typed
        )
    }

    // For the Restart button: claude tasks rebuild from the current
    // factory; everything else reuses the persisted spec verbatim.
    public static func restartSpec(for task: Task, invocation: String) -> ProcessSpec {
        if case let .claude(sessionId) = task.kind {
            return make(cwd: task.spec.cwd, sessionId: sessionId, invocation: invocation)
        }
        return task.spec
    }

    // Resolve repo override → settings default → literal "claude".
    public static func resolveInvocation(
        repo: Repo?,
        settings: Settings
    ) -> String {
        let raw = repo?.claudeInvocation ?? settings.claudeInvocation
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "claude" : trimmed
    }
}
