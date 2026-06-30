import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOWebSocket

/// The in-app HTTP + WebSocket server that REPLACES the Node `src/server.js`.
/// HTTP and WebSocket share ONE port (the unchanged web listener computes its
/// socket as `ws://<same host:port>/ws`): non-`/ws` requests fall through to
/// `HTTPHandler`; `/ws` upgrades to a `WebSocketSignalingHandler`.
final class EmbeddedServer {
    let port: Int
    private let hub: SignalingHub
    private let publicDir: URL
    private var group: MultiThreadedEventLoopGroup?
    private var channel: Channel?

    init(port: Int = 3000, hub: SignalingHub, publicDir: URL) {
        self.port = port
        self.hub = hub
        self.publicDir = publicDir
    }

    /// Binds and starts serving. Throws if the port is taken.
    func start() throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        self.group = group
        let hub = self.hub
        let publicDir = self.publicDir
        let port = self.port

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // One handler instance we can remove on upgrade (see below).
                let httpHandler = HTTPHandler(publicDir: publicDir, port: port)
                let upgrader = NIOWebSocketServerUpgrader(
                    maxFrameSize: 1 << 20,
                    shouldUpgrade: { channel, head in
                        // Only /ws upgrades; everything else stays HTTP.
                        if head.uri == "/ws" {
                            return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                        }
                        return channel.eventLoop.makeSucceededFuture(nil)
                    },
                    upgradePipelineHandler: { channel, _ in
                        channel.pipeline.addHandler(WebSocketSignalingHandler(hub: hub))
                    })
                let config: NIOHTTPServerUpgradeConfiguration = (
                    upgraders: [upgrader],
                    completionHandler: { _ in
                        // On a successful WebSocket upgrade, drop the HTTP handler —
                        // otherwise WS frames hit it (it expects parsed HTTP) and the
                        // pipeline crashes ("found IOData ... expected HTTPPart").
                        channel.pipeline.removeHandler(httpHandler, promise: nil)
                    })
                return channel.pipeline
                    .configureHTTPServerPipeline(withServerUpgrade: config)
                    .flatMap {
                        channel.pipeline.addHandler(httpHandler)
                    }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        channel = try bootstrap.bind(host: "0.0.0.0", port: port).wait()
    }

    func stop() {
        try? channel?.close().wait()
        try? group?.syncShutdownGracefully()
        channel = nil
        group = nil
    }

    /// Where the bundled, UNCHANGED web listener lives (copied in as a folder ref).
    static var bundledPublicDir: URL {
        Bundle.main.resourceURL?.appendingPathComponent("public")
            ?? URL(fileURLWithPath: "public")
    }
}
