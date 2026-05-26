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
public final class Server: @unchecked Sendable {
    private let bus: EventBus
    private let snapshotProvider: @Sendable () async -> AppState
    private let serverVersion: String
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?

    public init(
        bus: EventBus,
        serverVersion: String,
        snapshotProvider: @escaping @Sendable () async -> AppState
    ) {
        self.bus = bus
        self.serverVersion = serverVersion
        self.snapshotProvider = snapshotProvider
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    public func start(host: String, port: Int) throws -> Channel {
        let bus = self.bus
        let snapshotProvider = self.snapshotProvider
        let serverVersion = self.serverVersion

        let upgrader = NIOWebSocketServerUpgrader(
            shouldUpgrade: { (channel, _) -> EventLoopFuture<HTTPHeaders?> in
                channel.eventLoop.makeSucceededFuture(HTTPHeaders())
            },
            upgradePipelineHandler: { (channel, _) -> EventLoopFuture<Void> in
                channel.pipeline.addHandler(WebSocketConnectionHandler(
                    bus: bus,
                    serverVersion: serverVersion,
                    snapshotProvider: snapshotProvider
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
    private var greeted = false
    private var forwardingTask: _Concurrency.Task<Void, Never>?

    init(
        bus: EventBus,
        serverVersion: String,
        snapshotProvider: @escaping @Sendable () async -> AppState
    ) {
        self.bus = bus
        self.serverVersion = serverVersion
        self.snapshotProvider = snapshotProvider
    }

    func channelInactive(context: ChannelHandlerContext) {
        forwardingTask?.cancel()
        forwardingTask = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            handleText(context: context)
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

    // First text frame triggers the handshake + event-forwarding loop.
    // Subsequent text frames are no-ops for now (action dispatch is S4).
    private func handleText(context: ChannelHandlerContext) {
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
