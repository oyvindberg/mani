import Foundation

// Decoded `Stop` hook payload from Claude Code. Claude fires Stop
// the moment an assistant turn completes — control is about to
// return to the user, no further bytes will arrive until the user
// types a new prompt (or runs a slash command).
//
// This is the precise signal for "claude is at the prompt, waiting
// for input." Unlike unread-count (which clears as soon as the user
// views the row) or the thinking pulse (which clears as soon as
// claude goes silent for ~1.5 s), `Stop` latches an explicit
// awaiting-input state that only resolves when claude resumes work.
//
// Payload comes from `~/.claude/settings.json`'s Stop hook, routed
// via HookShim → AF_UNIX → HookListenerService. We need only the
// session_id to map back to a Task; the other fields are kept for
// future use (e.g. correlating stop reasons across forks).

public struct StopPayload: Equatable {
    public let sessionId: String
    public let transcriptPath: String?
    // claude sets this true on its own re-entries (running a hook
    // chain). UI may want to ignore those — a user-visible "waiting"
    // state shouldn't blink during a hook-driven Stop loop.
    public let stopHookActive: Bool

    public init(
        sessionId: String,
        transcriptPath: String?,
        stopHookActive: Bool
    ) {
        self.sessionId = sessionId
        self.transcriptPath = transcriptPath
        self.stopHookActive = stopHookActive
    }
}
