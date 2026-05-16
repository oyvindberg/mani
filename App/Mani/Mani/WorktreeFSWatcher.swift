import Foundation
import CoreServices

// Lightweight FSEvents watcher over a single project path. Used by the
// Diff Workspace to auto-refresh the file list when the user edits a
// file outside Mani.
//
// Two pieces of debounce:
//   - Kernel-level latency in FSEventStreamCreate (1.0 s) coalesces
//     rapid bursts before we ever see them.
//   - Per-fire we inspect the event paths and SKIP if every path is
//     inside `.git/` — that prevents the self-reinforcing loop where
//     running `git status` itself touches index.lock and re-triggers
//     the watcher (the source of an 800 % CPU pegging in the field).
//   - User-space 1.0 s additional debounce on a serial queue.
final class WorktreeFSWatcher {
    private let root: String
    private let dotGitPrefix: String
    private let onChange: () -> Void
    private var stream: FSEventStreamRef?
    private var pendingRefresh: DispatchWorkItem?

    init(root: URL, onChange: @escaping () -> Void) {
        self.root = root.path
        self.dotGitPrefix = root.appendingPathComponent(".git").path
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
            { _, info, numEvents, eventPaths, _, _ in
                guard let info else { return }
                let watcher = Unmanaged<WorktreeFSWatcher>
                    .fromOpaque(info).takeUnretainedValue()
                guard let cfArray = Unmanaged<CFArray>
                    .fromOpaque(eventPaths).takeUnretainedValue() as? [String]
                else {
                    watcher.scheduleRefresh()
                    return
                }
                let prefix = watcher.dotGitPrefix
                let allInGit = cfArray.allSatisfy { path in
                    path == prefix || path.hasPrefix(prefix + "/")
                }
                if allInGit { return }
                watcher.scheduleRefresh()
                _ = numEvents
            },
            &context,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            1.0, // 1 s kernel-level coalescing
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
        }
    }

    deinit { stop() }
}
