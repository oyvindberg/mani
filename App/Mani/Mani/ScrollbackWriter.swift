import Foundation

// Tier 1 of docs/persistence.md: per-task scrollback, written from the same
// PTY byte stream the renderer consumes. Buffered: flushes on cap or every
// 250 ms via a timer. Walking-skeleton scope: flat append, no ring-buffer
// rotation yet (will add when total size grows).

final class ScrollbackWriter {

    let path: String
    private let cap: Int
    private let flushInterval: TimeInterval = 0.25
    private let flushSize: Int = 64 * 1024

    private let queue = DispatchQueue(label: "ScrollbackWriter")
    private var buffer = Data()
    private var fd: Int32 = -1
    private var timer: DispatchSourceTimer?

    init(path: String, capBytes: Int) {
        self.path = path
        self.cap = capBytes
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + flushInterval, repeating: flushInterval)
        // Timer fires on `queue`, so call flushLocked directly. flush() does
        // queue.sync and would self-deadlock — libdispatch traps that.
        timer.setEventHandler { [weak self] in self?.flushLocked() }
        timer.resume()
        self.timer = timer
    }

    func append(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.buffer.append(data)
            if self.buffer.count >= self.flushSize {
                self.flushLocked()
            }
        }
    }

    func flush() {
        queue.sync { self.flushLocked() }
    }

    private func flushLocked() {
        guard fd >= 0, !buffer.isEmpty else { return }
        buffer.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = buffer.count
            var ptr = base
            while remaining > 0 {
                let n = write(fd, ptr, remaining)
                if n <= 0 { break }
                remaining -= Int(n)
                ptr = ptr.advanced(by: Int(n))
            }
        }
        buffer.removeAll(keepingCapacity: true)
        // When the live log exceeds 2× cap, rotate it to a timestamped sibling
        // (no compression yet — the rotated files are bounded in size and
        // accumulating one per ring-fill is acceptable for v0.2). Old behavior
        // (truncate + drop head bytes) was lossy; rotation preserves history.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > cap * 2 {
            rotateAndContinue()
        }
    }

    private func rotateAndContinue() {
        let stamp = Int(Date().timeIntervalSince1970)
        let archivePath = (path as NSString)
            .deletingLastPathComponent
            .appending("/scrollback-\(stamp).log")
        // Close current fd, rename file to archive, reopen a fresh
        // scrollback.log for ongoing writes. fsync the directory so the
        // rename is durable. If rename fails we just keep writing to the
        // existing path — the next flush will retry.
        close(fd)
        if rename(path, archivePath) == 0 {
            let dir = (path as NSString).deletingLastPathComponent
            let dirFD = open(dir, O_RDONLY)
            if dirFD >= 0 {
                _ = fsync(dirFD)
                close(dirFD)
            }
        }
        fd = open(path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
    }

    deinit {
        flush()
        if fd >= 0 { close(fd) }
        timer?.cancel()
    }
}
