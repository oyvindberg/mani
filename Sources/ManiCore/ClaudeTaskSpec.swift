import Foundation

// Single source of truth for the ProcessSpec shape used to spawn `claude`.
//
// Background: claude's TUI doesn't fully reflow on SIGWINCH when launched
// directly via forkpty + execve, but DOES reflow when launched by a real
// interactive shell typing the command at its prompt. We never pinned down
// the underlying mechanism; the workaround is to spawn `/bin/zsh -l` and
// then write `claude\r` (or `claude --resume <id>\r`) into the master FD
// ~800 ms after fork — long enough for zsh to source rc files and render
// its first prompt. EffectRunner consumes `initialInput` and performs that
// scheduled write.
//
// Why centralize here:
//   1. Every place that creates a claude task funnels through .make so a
//      future format change happens in exactly one location.
//   2. The Restart button on a dead claude job re-derives via .restartSpec
//      instead of reusing the persisted `job.primary`. That severs the
//      stale-spec trap — old jobs persisted with a pre-zsh-injection spec
//      (e.g. /usr/bin/env claude) will be re-spawned with the current
//      shape regardless of what was written to events.jsonl long ago.
public enum ClaudeTaskSpec {
    // `invocation` is the prefix written into the shell, e.g. "claude"
    // or "claude --dangerously-skip-permissions". `--resume <sid>` is
    // appended automatically when `sessionId` is non-nil.
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
            pid: nil,
            initialInput: typed, restartPolicy: .never)
    }

    // For the Restart button: claude jobs always rebuild from the current
    // factory; everything else reuses the persisted spec verbatim. The
    // caller passes the project- or settings-resolved invocation so a
    // re-spawned task picks up any config change since the original
    // spawn (e.g. user enabled --dangerously-skip-permissions later).
    public static func restartSpec(for job: Job, invocation: String) -> ProcessSpec {
        if case let .claude(sessionId) = job.kind {
            return make(cwd: job.primary.cwd, sessionId: sessionId, invocation: invocation)
        }
        return job.primary
    }

    // Helper used everywhere the invocation needs to be resolved: per-
    // project override falls back to settings default; an empty or
    // whitespace-only string falls back to literal "claude".
    public static func resolveInvocation(
        project: Project?,
        settings: Settings
    ) -> String {
        let raw = project?.claudeInvocation ?? settings.claudeInvocation
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "claude" : trimmed
    }
}
