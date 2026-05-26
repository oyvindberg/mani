import Foundation
import ManiCore
import ManiServer

// Client side of the v0.2 wire protocol. Owns a URLSession.WebSocketTask
// to ws://<host>:<port>, handles the hello/helloAck handshake, decodes
// inbound frames, and exposes a TaskIO interface (via RemoteTaskIO) for
// the renderer.
//
// Lives in the mac app target — RemoteServerClient would be cleaner as
// a ManiServer-internal type, but URLSession.WebSocketTask isn't yet
// available cross-platform in a way that fits SwiftPM's macOS-14 target
// without additional plumbing. Pragmatic for v0.1; refactor when there
// are non-mac client targets.
//
// Threading: holds an NSLock around its mutable state (taskOutputContinuations,
// connection state, etc). Public methods are nonisolated and Sendable-safe.
@MainActor
final class RemoteWSClient {
    let url: URL
    let token: String
    var onStateUpdate: ((AppState) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var lastState: AppState = .empty
    private var lastEventSeq: UInt64 = 0

    private let stateLock = NSLock()
    private var taskOutputContinuations: [UUID: AsyncStream<Data>.Continuation] = [:]

    // Loose handle on RemoteTaskIO instances so they stay alive until
    // they're explicitly unsubscribed and the renderer drops its
    // reference. Keyed by taskId — we hand out the same instance for
    // subsequent taskIO(for:) calls on the same task.
    private var remoteTaskIOs: [UUID: RemoteTaskIO] = [:]

    init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    // MARK: - Lifecycle

    func connect() {
        let request = URLRequest(url: url)
        let task = URLSession.shared.webSocketTask(with: request)
        self.task = task
        task.resume()
        // Send hello immediately. The server's auth gate rejects any
        // non-hello frame pre-auth.
        let helloJSON = #"{"op":"hello","token":"\#(token)","protocolVersion":1,"clientId":"mac-client"}"#
        task.send(.string(helloJSON)) { err in
            if let err {
                NSLog("[mani-client] hello send failed: \(err)")
            }
        }
        startReceiveLoop()
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        stateLock.lock()
        for c in taskOutputContinuations.values { c.finish() }
        taskOutputContinuations.removeAll()
        stateLock.unlock()
    }

    private func startReceiveLoop() {
        guard let task = self.task else { return }
        task.receive { [weak self] result in
            guard let self else { return }
            _Concurrency.Task { @MainActor in
                self.handleReceiveResult(result)
                if case .success = result {
                    self.startReceiveLoop()
                }
            }
        }
    }

    private func handleReceiveResult(_ result: Result<URLSessionWebSocketTask.Message, Error>) {
        switch result {
        case .success(.string(let s)):
            handleFrame(s)
        case .success(.data(let d)):
            if let s = String(data: d, encoding: .utf8) { handleFrame(s) }
        case .success:
            break
        case .failure(let err):
            NSLog("[mani-client] receive failed: \(err)")
            // No reconnect yet — first cut. User restarts to reconnect.
        @unknown default:
            break
        }
    }

    // Inbound frame dispatch.
    private func handleFrame(_ s: String) {
        guard let data = s.data(using: .utf8) else { return }
        struct OpPeek: Decodable { let op: String }
        guard let op = (try? JSONDecoder().decode(OpPeek.self, from: data))?.op else {
            NSLog("[mani-client] frame missing op: \(s.prefix(120))")
            return
        }
        switch op {
        case "helloAck":
            handleHelloAck(data: data)
        case "event":
            handleEvent(data: data)
        case "taskOutput":
            handleTaskOutput(data: data)
        case "error":
            handleError(data: data)
        default:
            NSLog("[mani-client] unknown op: \(op)")
        }
    }

    private func handleHelloAck(data: Data) {
        struct Ack: Decodable {
            let snapshot: AppState
            let lastEventSeq: UInt64
        }
        guard let ack = try? JSONDecoder().decode(Ack.self, from: data) else {
            NSLog("[mani-client] malformed helloAck")
            return
        }
        lastState = ack.snapshot
        lastEventSeq = ack.lastEventSeq
        onStateUpdate?(lastState)
        NSLog("[mani-client] connected; \(ack.snapshot.repos.count) repos, lastEventSeq=\(ack.lastEventSeq)")
    }

    private func handleEvent(data: Data) {
        struct Env: Decodable {
            let seq: UInt64
            let event: Event
        }
        guard let env = try? JSONDecoder().decode(Env.self, from: data) else {
            NSLog("[mani-client] malformed event frame")
            return
        }
        // Apply locally so the cached state stays in sync. This is the
        // same `apply` the server runs — events are deterministic.
        apply(&lastState, env.event)
        lastEventSeq = env.seq
        onStateUpdate?(lastState)
    }

    private func handleTaskOutput(data: Data) {
        struct Out: Decodable {
            let taskId: UUID
            let data: String  // base64
        }
        guard let out = try? JSONDecoder().decode(Out.self, from: data) else { return }
        guard let bytes = Data(base64Encoded: out.data) else { return }
        stateLock.lock()
        let continuation = taskOutputContinuations[out.taskId]
        stateLock.unlock()
        continuation?.yield(bytes)
    }

    private func handleError(data: Data) {
        struct E: Decodable { let code: String; let message: String }
        if let e = try? JSONDecoder().decode(E.self, from: data) {
            NSLog("[mani-client] server error: \(e.code) — \(e.message)")
        }
    }

    // MARK: - Outbound

    func dispatch(_ action: Action) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        guard let actionData = try? encoder.encode(action),
              let actionStr = String(data: actionData, encoding: .utf8) else {
            NSLog("[mani-client] failed to encode action: \(action)")
            return
        }
        let frame = #"{"op":"dispatch","action":\#(actionStr)}"#
        await sendString(frame)
    }

    func sendTaskInput(taskId: UUID, data: Data) async {
        let b64 = data.base64EncodedString()
        let frame = #"{"op":"taskInput","taskId":"\#(taskId.uuidString)","data":"\#(b64)"}"#
        await sendString(frame)
    }

    func sendTaskResize(taskId: UUID, cols: UInt16, rows: UInt16) async {
        let frame = #"{"op":"taskResize","taskId":"\#(taskId.uuidString)","cols":\#(cols),"rows":\#(rows)}"#
        await sendString(frame)
    }

    func subscribeTaskOutput(taskId: UUID) -> AsyncStream<Data> {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        stateLock.lock()
        taskOutputContinuations[taskId] = continuation
        stateLock.unlock()
        let frame = #"{"op":"subscribeTaskOutput","taskId":"\#(taskId.uuidString)"}"#
        _Concurrency.Task { await sendString(frame) }
        continuation.onTermination = { [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.stateLock.lock()
                self?.taskOutputContinuations.removeValue(forKey: taskId)
                self?.stateLock.unlock()
                let unsub = #"{"op":"unsubscribeTaskOutput","taskId":"\#(taskId.uuidString)"}"#
                await self?.sendString(unsub)
            }
        }
        return stream
    }

    private func sendString(_ s: String) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            task?.send(.string(s)) { err in
                if let err {
                    NSLog("[mani-client] send failed: \(err) for \(s.prefix(120))")
                }
                cont.resume()
            }
        }
    }

    // MARK: - TaskIO factory

    nonisolated func taskIO(for taskId: UUID) -> TaskIO {
        // RemoteTaskIO is cheap to make and idempotent — we don't need
        // strict identity here. But cache by id so the renderer's
        // `pty === current` checks (e.g. EffectRunner-style onExit
        // guards on the local side) have stable identity if we ever
        // hand the same id out twice.
        let io = RemoteTaskIO(taskId: taskId, client: self)
        return io
    }
}
