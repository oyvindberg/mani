import Foundation
import Darwin
import ManiCore

// Mani-side client for a detached mani-agent helper process.
// Owns a UNIX socket FD and speaks the AgentProtocol frame format.
// Conforms to TaskIO so the renderer + EffectRunner treat it
// identically to an in-process ManagedPTY — the agent's transparent
// byte pipe makes the substitution lossless.
final class AgentClient: TaskIO, @unchecked Sendable {
    // Inner process's pid as reported by the agent. Currently
    // unknown until we add a HELLO/info frame; defaults to 0.
    let pid: pid_t
    var onExit: ((Int32) -> Void)?

    private let socketFD: Int32
    private let readSource: DispatchSourceRead
    private let decoder = AgentFrameDecoder()
    private let writeLock = NSLock()
    private var closed = false
    // Reused per-drain buffer. Allocating 8 KB inside drainSocket()
    // on every event triggered Swift-runtime crashes under load
    // (dozens of agents draining simultaneously). One buffer per
    // client, mutated under the dispatch source's serial queue, is
    // safe and avoids the allocation churn.
    private var drainBuf = [UInt8](repeating: 0, count: 8192)

    private let outputHandlersLock = NSLock()
    private var outputHandlers: [UUID: (Data) -> Void] = [:]
    private var capturedOutput = Data()
    private let captureCap = 1_048_576

    // Shared serial queue across ALL AgentClients. With N agents
    // we previously created N separate DispatchQueues, blowing
    // through libdispatch's worker-thread budget and triggering
    // runtime traps on heavy I/O. One queue serializes the drains
    // — they're already cheap (one syscall + frame decode per
    // wake) so a single drain thread is plenty.
    private static let sharedQueue = DispatchQueue(
        label: "Mani.AgentClient", qos: .userInitiated
    )

    init(socketFD: Int32, pid: pid_t) {
        self.socketFD = socketFD
        self.pid = pid
        _ = fcntl(socketFD, F_SETFL, O_NONBLOCK)
        readSource = DispatchSource.makeReadSource(
            fileDescriptor: socketFD,
            queue: Self.sharedQueue
        )
        readSource.setEventHandler { [weak self] in
            self?.drainSocket()
        }
        readSource.activate()
    }

    deinit {
        close()
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        let frame = AgentProtocol.encode(.input, payload: data)
        sendFrame(frame)
    }

    func resize(rows: UInt16, cols: UInt16) {
        sendFrame(AgentProtocol.resizeFrame(rows: rows, cols: cols))
    }

    func terminate() {
        sendFrame(AgentProtocol.encode(.terminate, payload: Data()))
    }

    func close() {
        guard !closed else { return }
        closed = true
        readSource.cancel()
        Darwin.close(socketFD)
    }

    private func sendFrame(_ frame: Data) {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !closed else { return }
        var offset = 0
        frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            while offset < frame.count {
                let n = Darwin.write(socketFD, base.advanced(by: offset), frame.count - offset)
                if n > 0 { offset += n }
                else if n < 0 && (errno == EAGAIN || errno == EINTR) {
                    usleep(1_000)
                } else { return }
            }
        }
    }

    private func drainSocket() {
        // drainBuf is an instance var; serial queue means no
        // re-entrance, so this is safe.
        while true {
            let n = drainBuf.withUnsafeMutableBufferPointer {
                Darwin.read(socketFD, $0.baseAddress, $0.count)
            }
            if n > 0 {
                decoder.append(Data(bytes: drainBuf, count: n))
                while let frame = decoder.next() {
                    handleFrame(frame)
                }
            } else if n == 0 {
                NSLog("[mani] AgentClient drainSocket: read returned 0 (peer EOF) fd=%d", socketFD)
                readSource.cancel()  // stop the source firing for a closed FD
                fireExit(code: -1)
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                let err = String(cString: strerror(errno))
                NSLog("[mani] AgentClient drainSocket: read errno=%d %@ fd=%d", errno, err, socketFD)
                readSource.cancel()
                fireExit(code: -1)
                return
            }
        }
    }

    private func handleFrame(_ frame: AgentFrameDecoder.Frame) {
        switch frame.type {
        case .output:
            // Capture for late-subscriber replay (same semantics as
            // ManagedPTY), then fan out to handlers.
            outputHandlersLock.lock()
            let totalAfter = capturedOutput.count + frame.payload.count
            if totalAfter > captureCap {
                let drop = totalAfter - captureCap
                // Wrap with Data(...) to force a fresh 0-indexed
                // copy. `dropFirst(_:)` returns a slice that
                // shares storage and reports a non-zero
                // startIndex, which makes subsequent
                // `subdata(in: 0..<n)` consumers trap.
                capturedOutput = Data(capturedOutput.dropFirst(drop))
            }
            capturedOutput.append(frame.payload)
            let handlers = Array(outputHandlers.values)
            outputHandlersLock.unlock()
            for h in handlers { h(frame.payload) }
        case .exit:
            let code = AgentProtocol.decodeExit(frame.payload) ?? -1
            fireExit(code: code)
        case .input, .resize, .terminate:
            // Client-bound frames shouldn't arrive on the receive
            // side; agent doesn't send these.
            break
        }
    }

    private var firedExit = false
    private func fireExit(code: Int32) {
        if firedExit { return }
        firedExit = true
        let cb = onExit
        DispatchQueue.main.async { cb?(code) }
    }

    func addOutputHandler(_ handler: @escaping (Data) -> Void) -> IOSubscription {
        addOutputHandler(replayCaptured: true, handler)
    }

    func addOutputHandler(
        replayCaptured: Bool,
        _ handler: @escaping (Data) -> Void
    ) -> IOSubscription {
        let id = UUID()
        outputHandlersLock.lock()
        // Force a contiguous Data with startIndex == 0. The
        // capture-cap path reassigns capturedOutput via
        // `dropFirst(...) + Data()`, which leaves Data with a
        // non-zero startIndex. `subdata(in: 0..<n)` on a slice
        // like that traps in Data._Representation.subscript
        // (EXC_BREAKPOINT brk 1). Re-wrapping with Data(...)
        // copies into a fresh allocation that's 0-indexed.
        let snapshot = replayCaptured ? Data(capturedOutput) : Data()
        outputHandlers[id] = handler
        outputHandlersLock.unlock()
        if !snapshot.isEmpty {
            Self.scheduleReplay(snapshot: snapshot, into: handler)
        }
        return IOSubscription { [weak self] in
            guard let self else { return }
            self.outputHandlersLock.lock()
            self.outputHandlers.removeValue(forKey: id)
            self.outputHandlersLock.unlock()
        }
    }

    // Replay a captured snapshot into a fresh handler without
    // tying up the main thread.
    //
    // The naive approach — call handler(snapshot) once — passes a
    // multi-100KB buffer into libghostty's surface_write_buffer
    // in a single shot, and the writer parks on a Zig futex
    // because the renderer's libxev consumer doesn't drain fast
    // enough. Even chunking + calling handler in a tight loop
    // doesn't help: the loop synchronously enqueues N main-async
    // blocks, all of which then drain back-to-back, and the
    // first overwhelmed feed still blocks.
    //
    // What does work is *spacing* the dispatches: each chunk
    // arrives at main on its own runloop tick, so between
    // arrivals the runloop services other events (including
    // libghostty's renderer wakeups). asyncAfter with a small
    // per-chunk delay gives the consumer time to drain between
    // feeds and matches the cadence of normal live PTY data
    // arriving via the agent socket.
    private static func scheduleReplay(
        snapshot: Data,
        into handler: @escaping (Data) -> Void
    ) {
        let chunkSize = 4096
        let perChunkDelay: TimeInterval = 0.002  // 2 ms
        // Use startIndex/endIndex rather than 0/count so this
        // stays correct even if a future caller passes a Data
        // slice. Defensive — addOutputHandler already normalises
        // its snapshot, but a stray slice escaping here would
        // re-introduce the brk-1 bounds trap.
        var offset = snapshot.startIndex
        var delay: TimeInterval = 0
        while offset < snapshot.endIndex {
            let end = Swift.min(offset + chunkSize, snapshot.endIndex)
            let chunk = snapshot.subdata(in: offset..<end)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                handler(chunk)
            }
            delay += perChunkDelay
            offset = end
        }
    }
}
