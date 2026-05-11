import Foundation
import AppKit
import ManiCore

// Per-JobPath cache of LibGhosttyRenderer instances. Without it, every
// re-mount of TerminalPane (i.e. switching to another sidebar item and
// back) tears down libghostty's surface and replays scrollback from
// disk — slow and visible.
//
// Correctness relies on the renderer owning its PTY output subscription
// (see LibGhosttyRenderer.attachToPTY). When a new Coordinator attaches
// to a cached renderer, the renderer simply replaces its subscription;
// the OutputSubscription deinit cancels the previous one. No duplicate
// output, no fan-out across stale handler closures.
//
// Invalidation: theme / font changes blow away the cached entry. The
// renderer takes those at init; we don't have a re-theme path.
//
// Lifetime: entries for deleted jobs leak until app quit. Bounded
// (one entry per job ever opened); acceptable for a dev tool.
@MainActor
final class TerminalRendererCache {
    static let shared = TerminalRendererCache()

    private struct Entry {
        let renderer: LibGhosttyRenderer
        let themeName: String
        let fontFamily: String
        let fontSize: Int
    }
    private var entries: [JobPath: Entry] = [:]

    func renderer(
        for path: JobPath,
        themeName: String,
        fontFamily: String,
        fontSize: Int
    ) -> LibGhosttyRenderer {
        if let existing = entries[path],
           existing.themeName == themeName,
           existing.fontFamily == fontFamily,
           existing.fontSize == fontSize {
            return existing.renderer
        }
        let renderer = LibGhosttyRenderer(
            themeName: themeName,
            fontFamily: fontFamily,
            fontSize: fontSize
        )
        entries[path] = Entry(
            renderer: renderer,
            themeName: themeName,
            fontFamily: fontFamily,
            fontSize: fontSize
        )
        return renderer
    }

    func discard(_ path: JobPath) {
        entries.removeValue(forKey: path)
    }
}
