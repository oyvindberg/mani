import Foundation
import CoreServices

// Lightweight FSEvents watcher over a single worktree path. Used by the
// Diff Workspace to auto-refresh the file list when the user edits a file
// outside Mani. Coalesces bursts via a 250 ms debounce — the kernel
// already does some coalescing on its end, this trims it further so a
// `git checkout` that touches many files doesn't trigger 50 refreshes.
//
// The callback fires on the main queue.
final class WorktreeFSWatcher {
    private let root: String
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root.path
        self.onChange = onChange
    }

    func start() {
        guard stream == nil else { return }
        let paths = [root] as CFArray
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<WorktreeFSWatcher>
                    .fromOpaque(info).takeUnretainedValue()
                watcher.scheduleRefresh()
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.25, // 250 ms latency at the kernel level
            flags
        )
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        pendingRefresh?.cancel()
        pendingRefresh = nil
    }

    private func scheduleRefresh() {
        let work = DispatchWorkItem { [weak self] in
            self?.onChange()
        }
        DispatchQueue.main.async {
            self.pendingRefresh?.cancel()
            self.pendingRefresh = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    deinit { stop() }
}
