import AppKit
import Foundation
import GhosttyTerminal
import GhosttyTheme
import ManiServer

// libghostty-backed terminal renderer. Replaces SwiftTermRenderer for v0.2 of
// the renderer choice (ADR-002). Uses GhosttyTerminal's host-managed I/O
// backend (InMemoryTerminalSession): we feed PTY bytes via session.receive,
// the session calls our `write` closure when the user types, and our
// `resize` closure when the grid changes.
//
// Same TerminalRenderer protocol contract as SwiftTermRenderer so TerminalPane
// doesn't need to know which backend it has.

final class LibGhosttyRenderer: NSObject, TerminalRenderer, TerminalSurfaceViewDelegate, TerminalSurfaceOpenURLDelegate {

    var view: NSView { terminalView }
    var inputHandler: ((Data) -> Void)? {
        get { bridge.onInput }
        set { bridge.onInput = newValue }
    }
    var sizeHandler: ((Int, Int) -> Void)? {
        get { bridge.onResize }
        set { bridge.onResize = newValue }
    }

    // Latest viewport size the surface has reported. nil if no
    // resize callback has fired yet (very brief window between
    // renderer construction and the surface's first layout).
    var lastObservedSize: (rows: Int, cols: Int)? {
        bridge.lastSize
    }

    private let bridge: CallbackBridge
    private let session: InMemoryTerminalSession
    private let terminalView: GhosttyTerminal.TerminalView
    private let controller: TerminalController
    // PTY output subscription is OWNED by the renderer (not the SwiftUI
    // Coordinator) so that re-mounting TerminalPane on the same TaskPath
    // — which happens any time the user navigates away and back — does
    // not stack additional subscribers on the same PTY. Setting a new
    // value drops the previous one, whose deinit cancels the kernel-side
    // handler registration. See TerminalRendererCache for the caching
    // story this enables.
    private var outputSub: IOSubscription?
    // True iff this renderer has already been wired to a PTY at least
    // once. First-attach gets the captured-output replay (so the
    // initial banner / spawn output isn't lost during the brief polling
    // window between PTY spawn and renderer attach); subsequent attaches
    // skip the replay so the visible scrollback isn't duplicated.
    private var hasEverAttached: Bool = false

    init(theme: TerminalTheme, fontFamily: String, fontSize: Int) {
        let bridge = CallbackBridge()
        let session = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.main.async { bridge.onInput?(data) }
            },
            resize: { viewport in
                let rows = Int(viewport.rows)
                let cols = Int(viewport.columns)
                DispatchQueue.main.async {
                    bridge.lastSize = (rows, cols)
                    bridge.onResize?(rows, cols)
                }
            }
        )
        let terminalView = GhosttyTerminal.TerminalView(frame: .zero)
        var config = TerminalConfiguration()
        if !fontFamily.isEmpty {
            config = config.fontFamily(fontFamily)
        }
        config = config.fontSize(Float(fontSize))
        let controller = TerminalController(
            theme: theme,
            terminalConfiguration: config
        )
        self.bridge = bridge
        self.session = session
        self.terminalView = terminalView
        self.controller = controller
        super.init()
        terminalView.delegate = self
        terminalView.controller = controller
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(session)
        )
    }

    func feed(_ data: Data) {
        session.receive(data)
    }

    // Subscribe (or re-subscribe) to a PTY's output stream. The renderer
    // holds the resulting OutputSubscription, so assigning a new one
    // cancels the previous registration via its deinit — no risk of
    // duplicate feeds when a fresh Coordinator attaches to a cached
    // renderer instance.
    func attachToPTY(_ pty: TaskIO) {
        let replay = !hasEverAttached
        attachToPTY(pty, replayCaptured: replay)
    }

    // Same as attachToPTY but force the captured-replay decision. The
    // Coordinator uses this when it has just pre-fed the on-disk
    // scrollback log: disk content already covers everything the
    // AgentClient has captured this attach, so a captured-replay
    // would duplicate what's on screen.
    func attachToPTY(_ pty: TaskIO, replayCaptured: Bool) {
        outputSub = pty.addOutputHandler(replayCaptured: replayCaptured) { [weak self] data in
            DispatchQueue.main.async { self?.feed(data) }
        }
        hasEverAttached = true
    }

    // Invoke a named libghostty binding action on the surface. Action names
    // follow Ghostty's keybind config syntax — e.g. "scroll_to_top",
    // "scroll_to_bottom", "scroll_page_lines:N", "copy_to_clipboard".
    // Returns true when the action dispatched.
    @discardableResult
    func performBindingAction(_ name: String) -> Bool {
        terminalView.performBindingAction(name)
    }

    // Convenience: scroll the viewport so the line at `lineFromTop`
    // (1-indexed, counted from the OLDEST line in the scrollback) lands
    // near the top of the visible grid. Implemented as scroll_to_top +
    // scroll_page_lines:N. We can't query libghostty for the total
    // scrollback length so this assumes the file-line count is a good
    // proxy — it isn't always (PTY output uses cursor positioning that
    // doesn't translate 1:1 to grid lines), but it gets within a screen
    // for most plain-text scrollbacks.
    func scrollToLine(fromTop lineFromTop: Int) {
        performBindingAction("scroll_to_top")
        let offset = max(0, lineFromTop - 1)
        if offset > 0 {
            performBindingAction("scroll_page_lines:\(offset)")
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        // Ghostty derives the grid from the view's pixel size. We don't push
        // (rows, cols) — the view's sizeChanged fires through the session's
        // `resize` closure, which we forward to our sizeHandler.
        _ = (rows, cols)
    }

    // MARK: TerminalSurfaceOpenURLDelegate

    func terminalDidRequestOpenURL(_ url: String, kind: TerminalOpenURLKind) {
        // OSC 8 hyperlinks (cmd-click) and recognized plain URLs both route
        // here. Hand off to Launch Services. Filter to http(s)/file/mailto so
        // a malicious sequence can't fire `tel:`/custom schemes silently.
        guard let nsURL = URL(string: url) else { return }
        let scheme = nsURL.scheme?.lowercased() ?? ""
        let allowed: Set<String> = ["http", "https", "file", "mailto"]
        guard allowed.contains(scheme) else { return }
        NSWorkspace.shared.open(nsURL)
    }
}

private final class CallbackBridge: @unchecked Sendable {
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
    // Latest size we've seen the surface report. Cached so the
    // Coordinator can push it to a freshly-bound PTY whose backing
    // process may still think it's at the (stale) spawn size.
    var lastSize: (rows: Int, cols: Int)?
}
