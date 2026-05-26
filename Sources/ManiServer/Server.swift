import Foundation
import ManiCore
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

// Public entry point for the mani-server transport. Wraps a swift-nio
// HTTP→WebSocket server. Caller supplies:
//
//   - an EventBus that the runtime publishes Events to (the server
//     forwards them as EventEnvelopes to subscribed clients).
//   - a snapshotProvider that returns the current AppState on demand
//     (the server calls it inside helloAck, holding nothing about the
//     runtime itself).
//
// The Server holds nothing it shouldn't — no Store, no EffectRunner,
// no persistence handles. That keeps it embeddable in the mac app
// without sprouting tendrils through the rest of the app architecture.
// Subscribe to a task's PTY byte stream. Returns a cancel closure
// (drop it / invoke it to unsubscribe), or nil if the task doesn't
// exist. The handler closure will be called with raw PTY bytes —
// including any captured backlog from before subscription if the
// underlying TaskIO supports replay, and live bytes thereafter.
public typealias TaskOutputSubscriber =
    @Sendable (UUID, @escaping @Sendable (Data) -> Void) async -> (@Sendable () -> Void)?

// Write bytes to a task's PTY stdin. No-op if the task isn't live.
public typealias TaskInputHandler = @Sendable (UUID, Data) async -> Void

// Notify a task's PTY of a new terminal size (TIOCSWINSZ via the
// agent). No-op if the task isn't live.
public typealias TaskResizeHandler = @Sendable (UUID, UInt16, UInt16) async -> Void

public final class Server: @unchecked Sendable {
    private let bus: EventBus
    private let snapshotProvider: @Sendable () async -> AppState
    private let actionDispatcher: @Sendable (Action) async -> Void
    private let taskOutputSubscriber: TaskOutputSubscriber
    private let taskInputHandler: TaskInputHandler
    private let taskResizeHandler: TaskResizeHandler
    private let serverVersion: String
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(
        bus: EventBus,
        serverVersion: String,
        snapshotProvider: @escaping @Sendable () async -> AppState,
        actionDispatcher: @escaping @Sendable (Action) async -> Void,
        taskOutputSubscriber: @escaping TaskOutputSubscriber,
        taskInputHandler: @escaping TaskInputHandler,
        taskResizeHandler: @escaping TaskResizeHandler
    ) {
        self.bus = bus
        self.serverVersion = serverVersion
        self.snapshotProvider = snapshotProvider
        self.actionDispatcher = actionDispatcher
        self.taskOutputSubscriber = taskOutputSubscriber
        self.taskInputHandler = taskInputHandler
        self.taskResizeHandler = taskResizeHandler
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func start(host: String, port: Int) throws -> Channel {
        let bus = self.bus
        let snapshotProvider = self.snapshotProvider
        let actionDispatcher = self.actionDispatcher
        let taskOutputSubscriber = self.taskOutputSubscriber
        let taskInputHandler = self.taskInputHandler
        let taskResizeHandler = self.taskResizeHandler
        let serverVersion = self.serverVersion

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel, _) -> EventLoopFuture<HTTPHeaders?> in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel, _) -> EventLoopFuture<Void> in
                channel.pipeline.addHandler(WebSocketConnectionHandler(
                    bus: bus,
                    serverVersion: serverVersion,
                    snapshotProvider: snapshotProvider,
                    actionDispatcher: actionDispatcher,
                    taskOutputSubscriber: taskOutputSubscriber,
                    taskInputHandler: taskInputHandler,
                    taskResizeHandler: taskResizeHandler
                ))
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let httpHandler = HTTPFallbackHandler()
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    }
                )
                return channel.pipeline.configureHTTPServerPipeline(withServerUpgrade: config)
                    .flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let ch = try bootstrap.bind(host: host, port: port).wait()
        self.channel = ch
        return ch
    }

    public func stop() throws {
        try channel?.close().wait()
        try group.syncShutdownGracefully()
    }
}

// MARK: - HTTP fallback
// Non-WebSocket requests get 426 Upgrade Required. Real production
// could serve a small status page or redirect to docs; not the spike's
// concern.
final class HTTPFallbackHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = self.unwrapInboundIn(data)
        guard case .end = part else { return }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Length", value: "0")
        let head = HTTPResponseHead(version: .http1_1, status: .upgradeRequired, headers: headers)
        context.write(self.wrapOutboundOut(.head(head)), promise: nil)
        context.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }
}

// MARK: - WebSocket handler
// One per connection. The first inbound text frame triggers helloAck
// (the spike ignores the client's payload for now). After that, the
// handler subscribes to the EventBus and forwards every published
// SequencedEvent as an EventEnvelope text frame.
final class WebSocketConnectionHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let bus: EventBus
    private let serverVersion: String
    private let snapshotProvider: @Sendable () async -> AppState
    private let actionDispatcher: @Sendable (Action) async -> Void
    private let taskOutputSubscriber: TaskOutputSubscriber
    private let taskInputHandler: TaskInputHandler
    private let taskResizeHandler: TaskResizeHandler
    private var greeted = false
    private var forwardingTask: _Concurrency.Task<Void, Never>?

    // Per-connection map of taskId → cancel closure for active
    // subscribeTaskOutput subscriptions. Accessed from both the NIO
    // event loop (channelRead / channelInactive) and detached async
    // Tasks (the subscriber returns its cancel asynchronously) — the
    // lock makes mutations safe across executors.
    private let stateLock = NSLock()
    private var taskOutputCancels: [UUID: @Sendable () -> Void] = [:]

    init(
        bus: EventBus,
        serverVersion: String,
        snapshotProvider: @escaping @Sendable () async -> AppState,
        actionDispatcher: @escaping @Sendable (Action) async -> Void,
        taskOutputSubscriber: @escaping TaskOutputSubscriber,
        taskInputHandler: @escaping TaskInputHandler,
        taskResizeHandler: @escaping TaskResizeHandler
    ) {
        self.bus = bus
        self.serverVersion = serverVersion
        self.snapshotProvider = snapshotProvider
        self.actionDispatcher = actionDispatcher
        self.taskOutputSubscriber = taskOutputSubscriber
        self.taskInputHandler = taskInputHandler
        self.taskResizeHandler = taskResizeHandler
    }

    func channelInactive(context: ChannelHandlerContext) {
        forwardingTask?.cancel()
        forwardingTask = nil
        stateLock.lock()
        let cancels = Array(taskOutputCancels.values)
        taskOutputCancels.removeAll()
        stateLock.unlock()
        for cancel in cancels { cancel() }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var payload = frame.unmaskedData
            let text = payload.readString(length: payload.readableBytes) ?? ""
            handleText(text, context: context)
        case .ping:
            var pong = frame
            pong.opcode = .pong
            context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            var closeFrame = frame
            closeFrame.fin = true
            closeFrame.opcode = .connectionClose
            context.writeAndFlush(self.wrapOutboundOut(closeFrame)).whenComplete { _ in
                context.close(promise: nil)
            }
        case .binary, .continuation, .pong:
            break
        default:
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("[ws] error: \(error)\n".utf8))
        context.close(promise: nil)
    }

    // Peek at `op`, dispatch to the matching handler. Unknown ops get
    // an ErrorEnvelope back; malformed frames close the connection.
    private func handleText(_ text: String, context: ChannelHandlerContext) {
        guard let data = text.data(using: .utf8) else {
            FileHandle.standardError.write(Data("[ws] non-UTF8 text frame; closing\n".utf8))
            context.close(promise: nil)
            return
        }
        struct OpPeek: Decodable { let op: String }
        let op: String
        do {
            op = try JSONDecoder().decode(OpPeek.self, from: data).op
        } catch {
            sendError(
                code: "malformed",
                message: "frame missing or invalid `op` field",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        switch op {
        case "hello":
            handleHello(context: context)
        case "dispatch":
            handleDispatch(payload: data, context: context)
        case "subscribeTaskOutput":
            handleSubscribeTaskOutput(payload: data, context: context)
        case "unsubscribeTaskOutput":
            handleUnsubscribeTaskOutput(payload: data, context: context)
        case "taskInput":
            handleTaskInput(payload: data, context: context)
        case "taskResize":
            handleTaskResize(payload: data, context: context)
        default:
            sendError(
                code: "unknownOp",
                message: "unknown op: \(op)",
                on: context.channel,
                eventLoop: context.eventLoop
            )
        }
    }

    // First `hello` triggers the handshake + event-forwarding loop.
    // Subsequent `hello` frames are no-ops (one greeting per session).
    private func handleHello(context: ChannelHandlerContext) {
        guard !greeted else { return }
        greeted = true
        let bus = self.bus
        let snapshotProvider = self.snapshotProvider
        let serverVersion = self.serverVersion
        let channel = context.channel
        let eventLoop = context.eventLoop

        forwardingTask = _Concurrency.Task { [weak self] in
            let snapshot = await snapshotProvider()
            let lastSeq = await bus.currentSeq
            let ack = HelloAck(
                sessionId: UUID().uuidString,
                serverVersion: serverVersion,
                protocolVersion: 1,
                snapshot: snapshot,
                lastEventSeq: lastSeq
            )
            self?.send(ack, on: channel, eventLoop: eventLoop)

            // Subscribe AFTER reading currentSeq so we don't miss events
            // (subscribe sees only future publishes; lastSeq covers the
            // back-end of the snapshot).
            let stream = await bus.subscribe()
            for await sequenced in stream {
                let env = EventEnvelope(seq: sequenced.seq, event: sequenced.event)
                self?.send(env, on: channel, eventLoop: eventLoop)
            }
        }
    }

    // {"op":"dispatch","action":{"kind":...,"payload":...}} — decode
    // the inner Action via ManiCore's wire Codable, hand it to the
    // dispatcher. The resulting Event flows back via the EventBus
    // subscription, so the client sees its own action reflected as an
    // event with a fresh seq — same path remote events take.
    private func handleDispatch(payload: Data, context: ChannelHandlerContext) {
        struct DispatchEnvelope: Decodable {
            let op: String
            let action: Action
        }
        let env: DispatchEnvelope
        do {
            env = try JSONDecoder().decode(DispatchEnvelope.self, from: payload)
        } catch {
            sendError(
                code: "malformedAction",
                message: "could not decode action: \(error)",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        let dispatcher = self.actionDispatcher
        _Concurrency.Task {
            await dispatcher(env.action)
        }
    }

    private func sendError(
        code: String,
        message: String,
        on channel: Channel,
        eventLoop: EventLoop
    ) {
        let env = ErrorEnvelope(code: code, message: message)
        send(env, on: channel, eventLoop: eventLoop)
    }

    // {"op":"subscribeTaskOutput","taskId":"..."} — install an output
    // handler on the given task's TaskIO. Bytes flow back as
    // {"op":"taskOutput",taskId,data:b64}. If the same task is already
    // subscribed on this connection, the previous handler is canceled
    // first (avoids duplicate streams to one client).
    private func handleSubscribeTaskOutput(payload: Data, context: ChannelHandlerContext) {
        struct Sub: Decodable { let op: String; let taskId: UUID }
        let sub: Sub
        do { sub = try JSONDecoder().decode(Sub.self, from: payload) }
        catch {
            sendError(
                code: "malformedSubscribe",
                message: "\(error)",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        let taskId = sub.taskId

        // Cancel any prior subscription for this task on this connection.
        stateLock.lock()
        let prior = taskOutputCancels.removeValue(forKey: taskId)
        stateLock.unlock()
        prior?()

        let subscriber = self.taskOutputSubscriber
        let channel = context.channel
        let eventLoop = context.eventLoop

        _Concurrency.Task { [weak self] in
            let cancel = await subscriber(taskId) { [weak self] bytes in
                guard let self else { return }
                let env = TaskOutputEnvelope(taskId: taskId, bytes: bytes)
                self.send(env, on: channel, eventLoop: eventLoop)
            }
            guard let self else {
                cancel?()
                return
            }
            if let cancel {
                self.stateLock.lock()
                self.taskOutputCancels[taskId] = cancel
                self.stateLock.unlock()
            } else {
                self.sendError(
                    code: "noSuchTask",
                    message: "no live pty for task \(taskId)",
                    on: channel,
                    eventLoop: eventLoop
                )
            }
        }
    }

    // {"op":"unsubscribeTaskOutput","taskId":"..."} — drop the handler
    // and stop forwarding bytes. No-op if not subscribed.
    private func handleUnsubscribeTaskOutput(payload: Data, context: ChannelHandlerContext) {
        struct Unsub: Decodable { let op: String; let taskId: UUID }
        let unsub: Unsub
        do { unsub = try JSONDecoder().decode(Unsub.self, from: payload) }
        catch {
            sendError(
                code: "malformedUnsubscribe",
                message: "\(error)",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        stateLock.lock()
        let cancel = taskOutputCancels.removeValue(forKey: unsub.taskId)
        stateLock.unlock()
        cancel?()
    }

    // {"op":"taskInput","taskId":"...","data":"<base64>"} — write
    // bytes to the task's PTY stdin. Used for keystrokes from a
    // remote terminal. Silently no-ops if the task isn't live (no
    // error frame for input — typing into a dead terminal is a
    // benign race during reconnect).
    private func handleTaskInput(payload: Data, context: ChannelHandlerContext) {
        struct Inp: Decodable { let op: String; let taskId: UUID; let data: String }
        let inp: Inp
        do { inp = try JSONDecoder().decode(Inp.self, from: payload) }
        catch {
            sendError(
                code: "malformedInput",
                message: "\(error)",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        guard let bytes = Data(base64Encoded: inp.data) else {
            sendError(
                code: "malformedInput",
                message: "data field is not valid base64",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        let handler = self.taskInputHandler
        let taskId = inp.taskId
        _Concurrency.Task {
            await handler(taskId, bytes)
        }
    }

    // {"op":"taskResize","taskId":"...","cols":<n>,"rows":<n>} —
    // forward a TIOCSWINSZ to the task's PTY. The conventional
    // "send resize on display" pattern means clients should re-emit
    // this whenever their view binds to the task (mirrors the
    // local UI's re-attach SIGWINCH fix in ContentView).
    private func handleTaskResize(payload: Data, context: ChannelHandlerContext) {
        struct Res: Decodable { let op: String; let taskId: UUID; let cols: UInt16; let rows: UInt16 }
        let res: Res
        do { res = try JSONDecoder().decode(Res.self, from: payload) }
        catch {
            sendError(
                code: "malformedResize",
                message: "\(error)",
                on: context.channel,
                eventLoop: context.eventLoop
            )
            return
        }
        let handler = self.taskResizeHandler
        let taskId = res.taskId
        let cols = res.cols
        let rows = res.rows
        _Concurrency.Task {
            await handler(taskId, cols, rows)
        }
    }

    // Encode + ship a text frame. We hop to the channel's event loop
    // because writes from a different executor (the _Concurrency.Task
    // above) need to be marshalled onto NIO's loop.
    private func send<T: Encodable>(_ value: T, on channel: Channel, eventLoop: EventLoop) {
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(value)
        } catch {
            FileHandle.standardError.write(Data("[ws] encode failed: \(error)\n".utf8))
            return
        }
        let buffer = channel.allocator.buffer(bytes: data)
        let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        eventLoop.execute {
            channel.writeAndFlush(frame, promise: nil)
        }
    }
}
