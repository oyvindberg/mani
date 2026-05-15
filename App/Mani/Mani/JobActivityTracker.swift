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
    func recordActivity(sid: String) {
        lastByteAt[sid] = Date()
        if !thinkingSessions.contains(sid) {
            thinkingSessions.insert(sid)
            // No settledAt update on entry — settledAt is the timestamp
            // of the LAST transition out of thinking, used for the
            // "just-ready" pulse window.
        }
    }

    // Convenience for callers reading from sparse TaskKind without
    // unwrapping themselves.
    func isThinking(sid: String?) -> Bool {
        guard let sid else { return false }
        return thinkingSessions.contains(sid)
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
