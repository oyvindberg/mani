import AppKit
import Foundation
import GhosttyTerminal
import GhosttyTheme

// libghostty-backed terminal renderer. Replaces SwiftTermRenderer for v0.2 of
// the renderer choice (ADR-002). Uses GhosttyTerminal's host-managed I/O
// backend (InMemoryTerminalSession): we feed PTY bytes via session.receive,
// the session calls our `write` closure when the user types, and our
// `resize` closure when the grid changes.
//
// Same TerminalRenderer protocol contract as SwiftTermRenderer so TerminalPane
// doesn't need to know which backend it has.

final class LibGhosttyRenderer: NSObject, TerminalRenderer, TerminalSurfaceViewDelegate {

    var view: NSView { terminalView }
    var inputHandler: ((Data) -> Void)? {
        get { bridge.onInput }
        set { bridge.onInput = newValue }
    }
    var sizeHandler: ((Int, Int) -> Void)? {
        get { bridge.onResize }
        set { bridge.onResize = newValue }
    }

    private let bridge: CallbackBridge
    private let session: InMemoryTerminalSession
    private let terminalView: GhosttyTerminal.TerminalView
    private let controller: TerminalController

    init(themeName: String, fontFamily: String, fontSize: Int) {
        let bridge = CallbackBridge()
        let session = InMemoryTerminalSession(
            write: { data in
                DispatchQueue.main.async { bridge.onInput?(data) }
            },
            resize: { viewport in
                let rows = Int(viewport.rows)
                let cols = Int(viewport.columns)
                DispatchQueue.main.async {
                    bridge.onResize?(rows, cols)
                }
            }
        )
        let terminalView = GhosttyTerminal.TerminalView(frame: .zero)
        let theme = GhosttyThemeCatalog.theme(named: themeName)?.toTerminalTheme()
            ?? .default
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

    func resize(rows: UInt16, cols: UInt16) {
        // Ghostty derives the grid from the view's pixel size. We don't push
        // (rows, cols) — the view's sizeChanged fires through the session's
        // `resize` closure, which we forward to our sizeHandler.
        _ = (rows, cols)
    }
}

private final class CallbackBridge: @unchecked Sendable {
    var onInput: ((Data) -> Void)?
    var onResize: ((Int, Int) -> Void)?
}
