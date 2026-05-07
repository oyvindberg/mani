import AppKit
import SwiftTerm

// docs/terminal.md § "TerminalRenderer protocol".
// Thin seam between Mani's UI and the concrete terminal renderer (SwiftTerm
// today, libghostty later). Keep it minimal — grow only as a real consumer
// shows up. Search, themes, OSC 8 etc. are deferred until v0.1 needs them.

protocol TerminalRenderer: AnyObject {
    var view: NSView { get }
    func feed(_ data: Data)
    func resize(rows: UInt16, cols: UInt16)
    var inputHandler: ((Data) -> Void)? { get set }
    var sizeHandler: ((Int, Int) -> Void)? { get set }
}

final class SwiftTermRenderer: NSObject, TerminalRenderer, TerminalViewDelegate {
    private let terminal: SwiftTerm.TerminalView

    var view: NSView { terminal }
    var inputHandler: ((Data) -> Void)?
    var sizeHandler: ((Int, Int) -> Void)?

    override init() {
        self.terminal = TerminalView(frame: .zero)
        super.init()
        self.terminal.terminalDelegate = self
    }

    func feed(_ data: Data) {
        let bytes = Array(data)
        terminal.feed(byteArray: bytes[...])
    }

    func resize(rows: UInt16, cols: UInt16) {
        // SwiftTerm exposes resize via the delegate's sizeChanged callback;
        // direct programmatic resize isn't part of the public API, so leave
        // a hook here that becomes meaningful once we wire grid sizing.
        _ = (rows, cols)
    }

    // MARK: TerminalViewDelegate

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        inputHandler?(Data(data))
    }
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        sizeHandler?(newRows, newCols)
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func clipboardCopy(source: TerminalView, content: Data) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {}
    func bell(source: TerminalView) {}
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
}
