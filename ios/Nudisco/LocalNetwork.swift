import Foundation
import Network

/// iOS requires explicit "Local Network" permission for an app to talk to LAN
/// devices (Safari is exempt — that's why the web listener worked but the app
/// didn't). A plain URLSessionWebSocketTask to a raw LAN IP often fails with
/// -1009 without ever showing the prompt; a Network-framework connection
/// reliably triggers it. So we poke host:port with a short TCP connection first,
/// which surfaces the permission dialog and confirms reachability, then connect
/// the WebSocket regardless of the result.
enum LocalNetwork {
    static func prime(host: String, port: UInt16, timeout: TimeInterval = 3,
                      completion: @escaping (Bool) -> Void) {
        let conn = NWConnection(host: NWEndpoint.Host(host),
                                port: NWEndpoint.Port(rawValue: port) ?? 80,
                                using: .tcp)
        var finished = false
        let finish: (Bool) -> Void = { ok in
            guard !finished else { return }
            finished = true
            conn.cancel()
            DispatchQueue.main.async { completion(ok) }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:                 finish(true)
            case .failed, .cancelled:    finish(false)
            default:                     break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { finish(false) }
    }
}
