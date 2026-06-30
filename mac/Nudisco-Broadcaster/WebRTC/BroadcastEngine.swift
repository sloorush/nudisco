import Foundation
import WebRTC

/// The broadcaster half of the mesh — a port of the `MeshBroadcaster` class in
/// public/js/mesh-broadcaster.js. Registers itself with the `SignalingHub` as the
/// in-process broadcaster, opens one `BroadcastPeer` per listener, and routes
/// SDP/ICE. All state is touched on the main queue.
final class BroadcastEngine {
    private let hub: SignalingHub
    private var peers: [String: BroadcastPeer] = [:]
    private var attached = false

    // Set by the view model; all invoked on the main queue.
    var onListenerCount: ((Int) -> Void)?
    var onListenerStats: ((_ id: String, _ house: Bool, _ stats: [String: Any]) -> Void)?
    var onListenerLeft: ((String) -> Void)?
    var onPeersChanged: (() -> Void)?
    var onReplaced: (() -> Void)?

    init(hub: SignalingHub) { self.hub = hub }

    /// Go on air: become the hub's broadcaster. (Audio starts flowing once a
    /// listener connects and libwebrtc begins pulling from the ADM.)
    func start() {
        guard !attached else { return }
        attached = true
        hub.connect(role: "broadcaster", house: false) { [weak self] msg in
            DispatchQueue.main.async { self?.handle(msg) }
        }
    }

    func stop() {
        guard attached else { return }
        attached = false
        hub.disconnect(id: "broadcaster")
        peers.values.forEach { $0.close() }
        peers.removeAll()
        onPeersChanged?()
    }

    var count: Int { peers.count }

    private func handle(_ msg: [String: Any]) {
        guard let type = msg["type"] as? String else { return }
        switch type {
        case "listener-joined":
            if let id = msg["id"] as? String { addListener(id, house: (msg["house"] as? Bool) ?? false) }
        case "listener-left":
            if let id = msg["id"] as? String { removeListener(id); onListenerLeft?(id) }
        case "listener-count":
            onListenerCount?((msg["count"] as? Int) ?? 0)
        case "listener-stats":
            if let id = msg["id"] as? String {
                onListenerStats?(id, (msg["house"] as? Bool) ?? false, (msg["stats"] as? [String: Any]) ?? [:])
            }
        case "signal":
            if let from = msg["from"] as? String, let data = msg["data"] as? [String: Any] {
                routeSignal(from: from, data: data)
            }
        case "replaced":
            stop()
            onReplaced?()
        default:
            break
        }
    }

    private func addListener(_ id: String, house: Bool) {
        guard peers[id] == nil else { return }
        let peer = BroadcastPeer(
            id: id, house: house,
            onSignal: { [weak self] m in self?.hub.message(from: "broadcaster", m) },
            onClosed: { [weak self] in DispatchQueue.main.async { self?.removeListener(id) } })
        peers[id] = peer
        peer.start()
        onPeersChanged?()
    }

    private func removeListener(_ id: String) {
        guard let peer = peers.removeValue(forKey: id) else { return }
        peer.close()
        onPeersChanged?()
    }

    private func routeSignal(from: String, data: [String: Any]) {
        guard let peer = peers[from] else { return }
        if let sdp = data["sdp"] as? [String: Any], let s = sdp["sdp"] as? String {
            peer.handleAnswer(s)                          // the listener's answer
        } else if let cand = data["candidate"] as? [String: Any] {
            peer.addRemoteCandidate(cand)
        }
    }

    // MARK: - listener table snapshot (broadcaster-side RTT per peer)
    struct PeerStat { let id: String; let house: Bool; let state: String; let rttMs: Double? }

    func peerStats(_ completion: @escaping ([PeerStat]) -> Void) {
        let all = Array(peers.values)
        guard !all.isEmpty else { completion([]); return }
        var out: [PeerStat] = []
        let lock = NSLock()
        let group = DispatchGroup()
        for p in all {
            group.enter()
            p.rtt { rtt, state in
                lock.lock()
                out.append(PeerStat(id: p.id, house: p.house,
                                    state: Self.stateString(state),
                                    rttMs: rtt.map { $0.rounded() }))
                lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(out.sorted { $0.id < $1.id }) }
    }

    private static func stateString(_ s: RTCPeerConnectionState) -> String {
        switch s {
        case .new: return "new"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnected: return "disconnected"
        case .failed: return "failed"
        case .closed: return "closed"
        @unknown default: return "—"
        }
    }
}
