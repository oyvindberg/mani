import Foundation
import ManiCore

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
enum ClaudeTaskSpec {
    static func make(cwd: URL, sessionId: String?) -> ProcessSpec {
        let typed: String
        if let sessionId {
            typed = "claude --resume \(sessionId)\r"
        } else {
            typed = "claude\r"
        }
        return ProcessSpec(
            command: "/bin/zsh",
            args: ["-l"],
            env: [:],
            cwd: cwd,
            pid: nil,
            initialInput: typed
        )
    }

    // For the Restart button: claude jobs always rebuild from the current
    // factory; everything else reuses the persisted spec verbatim.
    static func restartSpec(for job: Job) -> ProcessSpec {
        if case let .claude(sessionId) = job.kind {
            return make(cwd: job.primary.cwd, sessionId: sessionId)
        }
        return job.primary
    }
}
