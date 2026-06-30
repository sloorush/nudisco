import Foundation
import NIOCore
import NIOHTTP1

/// Serves the bundled `public/` web listener plus `/api/info` and `/qr.svg` —
/// a port of the static + small-API half of src/server.js. Same routes, same
/// MIME map, same path-traversal guard. (`/ws` never reaches here: it is taken by
/// the WebSocket upgrader earlier in the pipeline.)
final class HTTPHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let publicDir: URL
    private let port: Int
    private var head: HTTPRequestHead?

    init(publicDir: URL, port: Int) {
        self.publicDir = publicDir
        self.port = port
    }

    private static let mime: [String: String] = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "svg": "image/svg+xml",
        "png": "image/png",
        "ico": "image/x-icon",
        "json": "application/json; charset=utf-8",
        "map": "application/json; charset=utf-8",
        "woff2": "font/woff2",
        "woff": "font/woff",
        "ttf": "font/ttf",
    ]

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let h):
            head = h
        case .body:
            break                          // GET only — ignore any body
        case .end:
            if let h = head { route(context: context, head: h) }
            head = nil
        }
    }

    private func route(context: ChannelHandlerContext, head: HTTPRequestHead) {
        let comps = URLComponents(string: head.uri)
        var path = comps?.percentEncodedPath.removingPercentEncoding ?? head.uri

        // /api/info — canonical listener URL (always the LAN IP, never localhost).
        if path == "/api/info" {
            let ip = LanIP.current()
            let info: [String: Any] = [
                "lanIp": ip, "port": port, "scheme": "http", "secure": false,
                "listenerUrl": "http://\(ip):\(port)/",
            ]
            let body = (try? JSONSerialization.data(withJSONObject: info)) ?? Data()
            return send(context, head, status: .ok, body: body,
                        contentType: Self.mime["json"]!, noStore: true)
        }

        // /qr.svg?text= — QR for the join URL.
        if path == "/qr.svg" {
            let text = comps?.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            if let svg = QRSvg.svg(for: text), let body = svg.data(using: .utf8) {
                return send(context, head, status: .ok, body: body,
                            contentType: Self.mime["svg"]!, noStore: true)
            }
            return send(context, head, status: .badRequest, body: Data("bad qr request".utf8),
                        contentType: "text/plain")
        }

        // Page routes.
        if path == "/" { path = "/index.html" }
        else if path == "/broadcast" || path == "/broadcast/" { path = "/broadcast.html" }

        // Static file — path-traversal safe (resolve and confirm it stays inside public/).
        let base = publicDir.standardizedFileURL
        let target = base.appendingPathComponent(path).standardizedFileURL
        guard target.path == base.path || target.path.hasPrefix(base.path + "/") else {
            return send(context, head, status: .forbidden, body: Data("forbidden".utf8),
                        contentType: "text/plain")
        }
        guard let data = try? Data(contentsOf: target) else {
            return send(context, head, status: .notFound, body: Data("not found".utf8),
                        contentType: "text/plain")
        }
        let ext = target.pathExtension.lowercased()
        send(context, head, status: .ok, body: data,
             contentType: Self.mime[ext] ?? "application/octet-stream")
    }

    private func send(_ context: ChannelHandlerContext, _ reqHead: HTTPRequestHead,
                      status: HTTPResponseStatus, body: Data,
                      contentType: String, noStore: Bool = false) {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: String(body.count))
        if noStore { headers.add(name: "Cache-Control", value: "no-store") }
        let keepAlive = reqHead.isKeepAlive
        headers.add(name: "Connection", value: keepAlive ? "keep-alive" : "close")

        let respHead = HTTPResponseHead(version: reqHead.version, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(respHead)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: body.count)
        buffer.writeBytes(body)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            if !keepAlive { context.close(promise: nil) }
        }
    }
}
