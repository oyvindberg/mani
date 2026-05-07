import SwiftUI
import SwiftTerm
import Foundation
import ManiCore

// Walking-skeleton UI: shows the first job's terminal pane. The real sidebar +
// tabs come later; what's important here is that the rendering binds to the
// EffectRunner's ManagedPTY rather than spawning its own child.

struct ContentView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        Group {
            if let path = firstJobPath() {
                TerminalPane(jobPath: path)
                    .id(path)
            } else {
                ProgressView("Starting…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func firstJobPath() -> JobPath? {
        guard let project = store.state.projects.first,
              let worktree = project.worktrees.first,
              let job = worktree.jobs.first
        else { return nil }
        return JobPath(project: project.id, worktree: worktree.id, job: job.id)
    }
}

private struct TerminalPane: NSViewRepresentable {
    let jobPath: JobPath
    @EnvironmentObject var store: Store

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TerminalView {
        let view = TerminalView(frame: .zero)
        view.terminalDelegate = context.coordinator
        let runner = store.runner
        let path = jobPath
        let coord = context.coordinator
        Task {
            // Wait until the EffectRunner has spawned the PTY for this jobPath.
            // The spawn is dispatched as a side effect of jobCreated → spawn,
            // typically completes within a few ms but can race with view setup.
            for _ in 0..<200 {
                if let pty = await runner.pty(for: path) {
                    coord.attach(view: view, pty: pty)
                    return
                }
                try? await Task.sleep(nanoseconds: 25_000_000)  // 25 ms
            }
            // Give up after 5 s.
            await MainActor.run { view.feed(text: "[no PTY for \(path) after 5s]\r\n") }
        }
        return view
    }

    func updateNSView(_ nsView: TerminalView, context: Context) {}

    final class Coordinator: NSObject, TerminalViewDelegate {
        private weak var pty: ManagedPTY?

        func attach(view: TerminalView, pty: ManagedPTY) {
            self.pty = pty
            pty.onOutput = { [weak view] chunk in
                let bytes = Array(chunk)
                DispatchQueue.main.async {
                    view?.feed(byteArray: bytes[...])
                }
            }
            pty.resize(rows: 40, cols: 120)
        }

        // MARK: TerminalViewDelegate

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            pty?.write(Data(data))
        }

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            pty?.resize(rows: UInt16(newRows), cols: UInt16(newCols))
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
}
