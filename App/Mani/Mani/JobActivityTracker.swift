import Foundation
import SwiftUI

// Per-claude-session activity state, keyed by Claude session id.
//
// Why a separate tracker (vs. computing on the Task struct):
//   - State decays with time (thinking → settled after silence). The
//     reducer-driven Task model isn't the right place for time-based
//     transitions; we'd otherwise need wall-clock events fired into
//     the reducer.
//   - Multiple UI surfaces (sidebar rows, top-bar pills) read the
//     same state at high frequency. A single @MainActor cache
//     republishes to all of them via @Published.
//
// Inputs:
//   - recordActivity(sid:) is called from ClaudeWatcher.onMessages
//     whenever a session's JSONL grew. That's our "bytes just
//     arrived" signal.
//   - A 1 s tick demotes thinking → idle once the silence threshold
//     is exceeded.
//
// "Ready" is NOT modeled here directly: the bar / sidebar combine
// isThinking(sid) with _Concurrency.Task.unread to decide. That keeps the source
// of truth for unread-count on the Task (where the reducer can drive
// markRead).
@MainActor
final class TaskActivityTracker: ObservableObject {
    // Promote to .idle when no bytes have arrived in this long.
    // Picked to ride through streaming gaps without lagging the
    // "ready" transition: claude's responses chunk in <0.5 s gaps
    // during streaming, then go silent for many seconds when the
    // turn is done.
    static let silenceThreshold: TimeInterval = 1.5

    // How long after a session becomes settled (thinking → not
    // thinking) the UI shows the "just became ready" emphasis pulse
    // on its pill / row.
    static let justReadyWindow: TimeInterval = 3.0

    // Sessions currently within silenceThreshold of their last
    // byte. Published so SwiftUI views rerender when transitions
    // happen.
    @Published private(set) var thinkingSessions: Set<String> = []

    // Wall-clock time the session most recently transitioned out of
    // thinking. Used to drive the brief "just became ready" pulse.
    @Published private(set) var settledAt: [String: Date] = [:]

    // Sessions whose last observed lifecycle event was claude's
    // `Stop` hook — claude finished its turn, control returned to
    // the user, no further bytes will arrive until the user types
    // a new prompt. The latch persists until claude resumes work
    // (recordActivity clears it) or the user explicitly dismisses.
    //
    // This is the "this claude is waiting for me" signal — the
    // main feature surface. Separate from unread (which clears on
    // view) and thinking (which clears on silence).
    @Published private(set) var awaitingInputSessions: Set<String> = []

    // When each awaiting-input transition happened. Lets the UI
    // sort "needs attention" rows oldest-waiting-first so the
    // session that's been hanging longest is most prominent.
    @Published private(set) var awaitingInputSince: [String: Date] = [:]

    private var lastByteAt: [String: Date] = [:]
    private var tickTask: _Concurrency.Task<Void, Never>?

    func start() {
        tickTask?.cancel()
        tickTask = _Concurrency.Task { @MainActor [weak self] in
            while !_Concurrency.Task.isCancelled {
                try? await _Concurrency.Task.sleep(nanoseconds: 1_000_000_000)
                self?.tick()
            }
        }
    }

    func stop() {
        tickTask?.cancel()
        tickTask = nil
    }

    // Called whenever ClaudeWatcher observes new bytes on a session's
    // JSONL. Idempotent: re-recording just updates the timestamp.
    //
    // Also clears the awaiting-input latch: if claude is producing
    // bytes again, it has resumed work, so any previously latched
    // "waiting for you" state is stale and should drop.
    func recordActivity(sid: String) {
        lastByteAt[sid] = Date()
        if !thinkingSessions.contains(sid) {
            thinkingSessions.insert(sid)
            // No settledAt update on entry — settledAt is the timestamp
            // of the LAST transition out of thinking, used for the
            // "just-ready" pulse window.
        }
        if awaitingInputSessions.contains(sid) {
            awaitingInputSessions.remove(sid)
            awaitingInputSince.removeValue(forKey: sid)
        }
    }

    // Called when claude's `Stop` hook fires for `sid` — the
    // assistant turn completed and control returned to the user.
    // Latches awaitingInput for this session until activity resumes.
    //
    // We deliberately do NOT also clear `thinkingSessions` here: the
    // silence-threshold tick still owns that transition. Stop and
    // the final byte often arrive within milliseconds of each other,
    // and racing the two transitions would cause flicker in the UI.
    // Letting `tick()` settle thinkingSessions on its own keeps the
    // existing "just became ready" pulse intact and adds the
    // awaiting-input latch as a separate concern.
    func markAwaitingInput(sid: String) {
        if !awaitingInputSessions.contains(sid) {
            awaitingInputSessions.insert(sid)
            awaitingInputSince[sid] = Date()
        }
    }

    // Manual clear — e.g. the user explicitly dismisses the
    // "needs attention" badge from the UI without typing a prompt.
    // Idempotent.
    func clearAwaitingInput(sid: String) {
        awaitingInputSessions.remove(sid)
        awaitingInputSince.removeValue(forKey: sid)
    }

    // Convenience for callers reading from sparse TaskKind without
    // unwrapping themselves.
    func isThinking(sid: String?) -> Bool {
        guard let sid else { return false }
        return thinkingSessions.contains(sid)
    }

    func isAwaitingInput(sid: String?) -> Bool {
        guard let sid else { return false }
        return awaitingInputSessions.contains(sid)
    }

    // Wall-clock instant the session entered the awaiting-input
    // state. Lets the UI render "waiting 3 m ago" subtitles and sort
    // a global "needs attention" list oldest-first.
    func awaitingInputSince(sid: String?) -> Date? {
        guard let sid else { return nil }
        return awaitingInputSince[sid]
    }

    // True iff the session settled within the last justReadyWindow.
    // Used by row/pill renderers to brighten the highlight briefly
    // when claude has just finished its turn.
    func justBecameReady(sid: String?) -> Bool {
        guard let sid, let when = settledAt[sid] else { return false }
        return Date().timeIntervalSince(when) < Self.justReadyWindow
    }

    // Used by ReadyClaudesBar to order pills newest-first.
    func settledAt(sid: String?) -> Date? {
        guard let sid else { return nil }
        return settledAt[sid]
    }

    private func tick() {
        let now = Date()
        let threshold = Self.silenceThreshold
        var demoted: [String] = []
        for sid in thinkingSessions {
            guard let last = lastByteAt[sid] else {
                demoted.append(sid)
                continue
            }
            if now.timeIntervalSince(last) > threshold {
                demoted.append(sid)
            }
        }
        guard !demoted.isEmpty else { return }
        for sid in demoted {
            thinkingSessions.remove(sid)
            settledAt[sid] = now
        }
    }
}
