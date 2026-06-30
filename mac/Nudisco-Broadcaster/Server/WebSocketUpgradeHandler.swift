import Foundation
import NIOCore
import NIOWebSocket

/// One WebSocket connection (a web or iOS listener). Bridges the socket to the
/// transport-agnostic `SignalingHub`: the first message is `hello` (which
/// registers the peer and captures a `send` closure that writes text frames back
/// to this socket); subsequent `signal`/`stats` messages are forwarded to the hub.
/// Mirrors the per-socket handling in src/signaling.js.
final class WebSocketSignalingHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let hub: SignalingHub
    private var peerID: String?
    private var awaitingClose = false

    init(hub: SignalingHub) { self.hub = hub }

    func handlerRemoved(context: ChannelHandlerContext) {
        if let id = peerID { hub.disconnect(id: id) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        if let id = peerID { hub.disconnect(id: id); peerID = nil }
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.opcode {
        case .text, .binary:
            var payload = frame.unmaskedData
            guard let text = payload.readString(length: payload.readableBytes),
                  let bytes = text.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any],
                  let type = msg["type"] as? String else { return }
            handle(type: type, msg: msg, channel: context.channel)

        case .ping:
            let pong = WebSocketFrame(fin: true, opcode: .pong, data: frame.unmaskedData)
            context.writeAndFlush(wrapOutboundOut(pong), promise: nil)

        case .connectionClose:
            receivedClose(context: context, frame: frame)

        default:
            break
        }
    }

    private func handle(type: String, msg: [String: Any], channel: Channel) {
        if type == "hello" {
            guard peerID == nil else { return }
            let role = (msg["role"] as? String) ?? "listener"
            let house = (msg["house"] as? Bool) ?? false
            // Capture the channel so the hub can push frames back from any thread
            // (Channel.writeAndFlush is thread-safe — it hops to the event loop).
            peerID = hub.connect(role: role, house: house) { [weak channel] json in
                guard let channel = channel,
                      let data = try? JSONSerialization.data(withJSONObject: json),
                      let str = String(data: data, encoding: .utf8) else { return }
                var buffer = channel.allocator.buffer(capacity: str.utf8.count)
                buffer.writeString(str)
                let frame = WebSocketFrame(fin: true, opcode: .text, data: buffer)
                channel.writeAndFlush(frame, promise: nil)
            }
        } else if let id = peerID {
            hub.message(from: id, msg)
        }
    }

    private func receivedClose(context: ChannelHandlerContext, frame: WebSocketFrame) {
        if awaitingClose {
            context.close(promise: nil)
        } else {
            var data = frame.unmaskedData
            let closeCode = data.readWebSocketErrorCode() ?? .normalClosure
            var buffer = context.channel.allocator.buffer(capacity: 2)
            buffer.write(webSocketErrorCode: closeCode)
            let close = WebSocketFrame(fin: true, opcode: .connectionClose, data: buffer)
            context.writeAndFlush(wrapOutboundOut(close)).whenComplete { _ in
                context.close(promise: nil)
            }
        }
    }
}
