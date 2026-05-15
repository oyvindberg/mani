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
                capturedOutput = capturedOutput.dropFirst(drop) + Data()
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
        let snapshot = replayCaptured ? capturedOutput : Data()
        outputHandlers[id] = handler
        outputHandlersLock.unlock()
        if !snapshot.isEmpty { handler(snapshot) }
        return IOSubscription { [weak self] in
            guard let self else { return }
            self.outputHandlersLock.lock()
            self.outputHandlers.removeValue(forKey: id)
            self.outputHandlersLock.unlock()
        }
    }
}
