import Foundation

/// Relays WebRTC offer/answer/ICE between ONE broadcaster and MANY listeners — a
/// faithful Swift port of `src/signaling.js`. It is transport-agnostic: each peer
/// is just an id + a `send` closure, so the SAME hub serves the in-process native
/// broadcaster (its closure routes into `BroadcastEngine`) and WebSocket listeners
/// (web + iOS, whose closure writes a WS text frame). The wire protocol — message
/// `type`s and JSON shapes, and the `L1, L2, …` listener ids — is preserved
/// exactly so the unchanged web/iOS listeners interoperate.
///
/// All state is mutated on a single serial queue; `send` closures must be
/// thread-safe and must not re-enter the hub synchronously (NIO channel writes and
/// the in-process closure both hop threads, so they're fine).
final class SignalingHub {
    struct Peer {
        let id: String
        let house: Bool
        let send: ([String: Any]) -> Void
    }

    private let q = DispatchQueue(label: "nudisco.signaling")
    private var broadcaster: Peer?
    private var listeners: [String: Peer] = [:]
    private var counter = 0

    /// Register a peer (the in-process broadcaster, a WS broadcaster fallback, or a
    /// WS listener). Returns the assigned id used for subsequent `message`/`disconnect`.
    @discardableResult
    func connect(role: String, house: Bool, send: @escaping ([String: Any]) -> Void) -> String {
        q.sync {
            if role == "broadcaster" {
                // Only one broadcaster at a time; a new one replaces the old.
                if let old = broadcaster {
                    old.send(["type": "replaced"])
                }
                let peer = Peer(id: "broadcaster", house: false, send: send)
                broadcaster = peer
                send(["type": "welcome", "id": "broadcaster", "role": "broadcaster"])
                // Re-announce every existing listener so the broadcaster offers to all.
                for (id, l) in listeners {
                    send(["type": "listener-joined", "id": id, "house": l.house])
                    l.send(["type": "broadcaster-available"])
                }
                sendCountLocked()
                return "broadcaster"
            } else {
                counter += 1
                let id = "L\(counter)"
                let peer = Peer(id: id, house: house, send: send)
                listeners[id] = peer
                send(["type": "welcome", "id": id, "role": "listener"])
                if let b = broadcaster {
                    send(["type": "broadcaster-available"])
                    b.send(["type": "listener-joined", "id": id, "house": house])
                } else {
                    send(["type": "no-broadcaster"])
                }
                sendCountLocked()
                return id
            }
        }
    }

    /// Handle a `signal` or `stats` message from a connected peer.
    func message(from id: String, _ msg: [String: Any]) {
        q.sync {
            guard let type = msg["type"] as? String else { return }
            switch type {
            case "signal":
                // Route an opaque SDP/ICE payload to the addressed peer.
                let to = msg["to"] as? String
                let target: Peer? = (to == "broadcaster") ? broadcaster : (to.flatMap { listeners[$0] })
                target?.send(["type": "signal", "from": id, "data": msg["data"] ?? [:]])
            case "stats":
                // Listener -> broadcaster latency/quality telemetry.
                if let l = listeners[id], let b = broadcaster {
                    b.send([
                        "type": "listener-stats",
                        "id": l.id,
                        "house": l.house,
                        "stats": msg["stats"] ?? [:],
                    ])
                }
            default:
                break
            }
        }
    }

    /// A peer's transport closed.
    func disconnect(id: String) {
        q.sync {
            if id == "broadcaster" {
                guard broadcaster != nil else { return }
                broadcaster = nil
                for l in listeners.values { l.send(["type": "broadcaster-gone"]) }
            } else if listeners.removeValue(forKey: id) != nil {
                broadcaster?.send(["type": "listener-left", "id": id])
                sendCountLocked()
            }
        }
    }

    var listenerCount: Int { q.sync { listeners.count } }

    // Caller already holds `q`.
    private func sendCountLocked() {
        broadcaster?.send(["type": "listener-count", "count": listeners.count])
    }
}
