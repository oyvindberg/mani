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
        timer.setEventHandler { [weak self] in self?.flush() }
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
        // Cheap "ring-buffer": if file exceeds 2× cap, truncate to cap by
        // rewriting the tail. Walking-skeleton, not crash-safe; replace with
        // proper rotation when file sizes start mattering.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = (attrs[.size] as? NSNumber)?.intValue, size > cap * 2 {
            truncateToCap()
        }
    }

    private func truncateToCap() {
        guard let fh = FileHandle(forReadingAtPath: path) else { return }
        defer { try? fh.close() }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.intValue,
              size > cap else { return }
        do {
            try fh.seek(toOffset: UInt64(size - cap))
            let tail = (try? fh.readToEnd()) ?? Data()
            close(fd)
            try tail.write(to: URL(fileURLWithPath: path))
            fd = open(path, O_WRONLY | O_APPEND, 0o644)
        } catch {
            // Best-effort; leave the oversized file alone if anything fails.
        }
    }

    deinit {
        flush()
        if fd >= 0 { close(fd) }
        timer?.cancel()
    }
}
