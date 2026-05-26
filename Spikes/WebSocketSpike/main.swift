import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket
import ManiCore

// S2 spike — embedded WS server that answers a `hello` frame with a
// `helloAck` carrying an AppState snapshot. Establishes the swift-nio
// stack + the protocol envelope shape against a non-Swift consumer
// (Python websockets client) before lifting any of it into the mac
// app. No real state — just AppState.empty.
//
// Run:    swift run WebSocketSpike
// Test from another shell:
//
//   python3 - <<'PY'
//   import asyncio, json, websockets
//   async def go():
//       async with websockets.connect("ws://127.0.0.1:8765") as ws:
//           await ws.send(json.dumps({"op":"hello","clientId":"py","protocolVersion":1}))
//           print(json.dumps(json.loads(await ws.recv()), indent=2))
//   asyncio.run(go())
//   PY
//
// If the websockets package isn't installed:
//   python3 -m pip install --user websockets

private let host = "127.0.0.1"
private let port = 8765

// MARK: - HTTP fallback handler
// For requests that don't upgrade to WebSocket, return 426 and close.
// Real production server would serve a redirect-to-docs page or similar.
private final class HTTPFallbackHandler: ChannelInboundHandler, RemovableChannelHandler {
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
// One per connection. On any client text frame, emit a helloAck.
// Spike-only: ignores the client's payload, always replies the same.
private final class WebSocketHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    func channelActive(context: ChannelHandlerContext) {
        FileHandle.standardError.write(Data("[ws] client connected: \(context.remoteAddress?.description ?? "?")\n".utf8))
    }

    func channelInactive(context: ChannelHandlerContext) {
        FileHandle.standardError.write(Data("[ws] client disconnected\n".utf8))
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = self.unwrapInboundIn(data)
        switch frame.opcode {
        case .text:
            var payload = frame.unmaskedData
            let text = payload.readString(length: payload.readableBytes) ?? ""
            FileHandle.standardError.write(Data("[ws] recv: \(text)\n".utf8))
            sendHelloAck(context: context)
        case .ping:
            var pong = frame
            pong.opcode = .pong
            context.writeAndFlush(self.wrapOutboundOut(pong), promise: nil)
        case .connectionClose:
            // Echo the close frame and shut down.
            var closeFrame = frame
            closeFrame.fin = true
            closeFrame.opcode = .connectionClose
            context.writeAndFlush(self.wrapOutboundOut(closeFrame)).whenComplete { _ in
                context.close(promise: nil)
            }
        case .binary, .continuation, .pong:
            break
        default:
            // Unknown opcode — close per RFC 6455 §5.5.
            context.close(promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        FileHandle.standardError.write(Data("[ws] error: \(error)\n".utf8))
        context.close(promise: nil)
    }

    private func sendHelloAck(context: ChannelHandlerContext) {
        struct HelloAck: Encodable {
            let op: String
            let sessionId: String
            let serverVersion: String
            let protocolVersion: Int
            let snapshot: AppState
            let lastEventSeq: Int
        }
        let ack = HelloAck(
            op: "helloAck",
            sessionId: UUID().uuidString,
            serverVersion: "0.2.0-spike",
            protocolVersion: 1,
            snapshot: .empty,
            lastEventSeq: 0
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(ack)
        } catch {
            FileHandle.standardError.write(Data("[ws] encode failed: \(error)\n".utf8))
            context.close(promise: nil)
            return
        }
        let buffer = context.channel.allocator.buffer(bytes: data)
        let respFrame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
        context.writeAndFlush(self.wrapOutboundOut(respFrame), promise: nil)
    }
}

// MARK: - Bootstrap

let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
defer { try? group.syncShutdownGracefully() }

let upgrader = NIOWebSocketServerUpgrader(
    shouldUpgrade: { (channel, _) -> EventLoopFuture<HTTPHeaders?> in
        channel.eventLoop.makeSucceededFuture(HTTPHeaders())
    },
    upgradePipelineHandler: { (channel, _) -> EventLoopFuture<Void> in
        channel.pipeline.addHandler(WebSocketHandler())
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

let channel: Channel
do {
    channel = try bootstrap.bind(host: host, port: port).wait()
} catch {
    FileHandle.standardError.write(Data("[ws] bind failed at \(host):\(port): \(error)\n".utf8))
    exit(1)
}

FileHandle.standardError.write(Data("[ws] listening on ws://\(host):\(port)\n".utf8))
try channel.closeFuture.wait()
