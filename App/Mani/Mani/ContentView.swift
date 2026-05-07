import SwiftUI
import SwiftTerm
import Foundation

// Walking-skeleton terminal pane: ManagedPTY (our spawn/PTY layer) feeds bytes
// into SwiftTerm's renderer-only TerminalView. Replaces the spike's
// LocalProcessTerminalView, which bundled spawning into the renderer; we keep
// those concerns separated so v0.1 can swap the renderer behind a protocol later.

struct ContentView: View {
    var body: some View {
        ManagedTerminalView()
            .ignoresSafeArea()
    }
}

private struct ManagedTerminalView: NSViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        context.coordinator.attach(view: view)
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        private var pty: ManagedPTY?
        private weak var view: TerminalView?

        func attach(view: TerminalView) {
            self.view = view
            do {
                var env = ProcessInfo.processInfo.environment
                env["TERM"] = "xterm-256color"
                let pty = try ManagedPTY(
                    executable: "/bin/zsh",
                    args: ["-l"],
                    env: env,
                    rawMode: false
                )
                self.pty = pty
                pty.onOutput = { [weak view] chunk in
                    let bytes = Array(chunk)
                    DispatchQueue.main.async {
                        view?.feed(byteArray: bytes[...])
                    }
                }
                pty.onExit = { [weak view] _ in
                    DispatchQueue.main.async {
                        view?.feed(text: "\r\n[process exited]\r\n")
                    }
                }
                // Initial size — refined when the host emits sizeChanged.
                pty.resize(rows: 40, cols: 120)
            } catch {
                view.feed(text: "failed to spawn /bin/zsh: \(error)\r\n")
            }
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty?.write(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            pty?.resize(rows: UInt16(newRows), cols: UInt16(newCols))
        }

        func setTerminalTitle(source: TerminalView, title: String) {
            // Reflected in the window's title bar later. No-op for the skeleton.
        }

        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            // OSC 7 — used later to track shell cwd for snapshot purposes.
        }

        func scrolled(source: TerminalView, position: Double) {}

        func clipboardCopy(source: TerminalView, content: Data) {
            // Default copy is built into TerminalView; this hook just observes.
        }

        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}

        func requestOpenLink(source: TerminalView, link: String, params: [String : String]) {
            // OSC 8 hyperlinks; deferred to v0.2+.
        }

        func bell(source: TerminalView) {}

        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    }
}
