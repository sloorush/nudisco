import Foundation
import WebRTC

/// One outgoing peer connection to a single listener — the broadcaster side of
/// the mesh, ported from `addListener()` in public/js/mesh-broadcaster.js (and
/// mirroring the config in ios/Nudisco/WebRTCClient.swift, but inverted: we are
/// the OFFERER and we SEND audio). Each listener gets its own BroadcastPeer.
final class BroadcastPeer: NSObject {
    let id: String
    let house: Bool

    private var pc: RTCPeerConnection?
    private let onSignal: ([String: Any]) -> Void   // emits {type:signal, to:id, data:…}
    private let onClosed: () -> Void
    private var pendingCandidates: [RTCIceCandidate] = []
    private var hasRemote = false

    init(id: String, house: Bool,
         onSignal: @escaping ([String: Any]) -> Void,
         onClosed: @escaping () -> Void) {
        self.id = id
        self.house = house
        self.onSignal = onSignal
        self.onClosed = onClosed
        super.init()
    }

    /// Create the peer, attach the shared captured-audio track, prefer RED, then
    /// offer (with the Opus SDP munge + bitrate), exactly like the web broadcaster.
    func start() {
        guard let pc = WebRTCFactory.shared.newPeerConnection(delegate: self) else { onClosed(); return }
        self.pc = pc

        pc.add(WebRTCFactory.shared.sharedAudioTrack, streamIds: ["nudisco"])
        // RED is preferred via SDP in SdpMunge.configureOpus (this libwebrtc build
        // doesn't expose setCodecPreferences), applied to the offer below.

        let mc = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: mc) { [weak self] sdp, err in
            guard let self = self, let sdp = sdp else { self?.onClosed(); return }
            let munged = SdpMunge.configureOpus(sdp.sdp)
            let offer = RTCSessionDescription(type: .offer, sdp: munged)
            pc.setLocalDescription(offer) { [weak self] _ in
                guard let self = self else { return }
                self.setBitrate(160_000)
                self.onSignal([
                    "type": "signal", "to": self.id,
                    "data": ["sdp": ["type": "offer", "sdp": munged]],
                ])
            }
        }
    }

    /// Apply the listener's answer, then flush any ICE that raced ahead of it.
    func handleAnswer(_ sdp: String) {
        guard let pc = pc else { return }
        pc.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] _ in
            guard let self = self else { return }
            self.hasRemote = true
            self.pendingCandidates.forEach { c in pc.add(c) { _ in } }
            self.pendingCandidates = []
        }
    }

    func addRemoteCandidate(_ dict: [String: Any]) {
        guard let cand = dict["candidate"] as? String else { return }
        let idx = (dict["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        let candidate = RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: dict["sdpMid"] as? String)
        if hasRemote, let pc = pc { pc.add(candidate) { _ in } } else { pendingCandidates.append(candidate) }
    }

    /// Broadcaster-side transport RTT (ms) for the listener table.
    func rtt(_ completion: @escaping (Double?, RTCPeerConnectionState) -> Void) {
        guard let pc = pc else { completion(nil, .closed); return }
        let state = pc.connectionState
        pc.statistics { report in
            var rtt: Double?
            for (_, s) in report.statistics where s.type == "candidate-pair" {
                if (s.values["state"] as? String) == "succeeded",
                   let r = (s.values["currentRoundTripTime"] as? NSNumber)?.doubleValue {
                    rtt = r * 1000
                }
            }
            completion(rtt, state)
        }
    }

    func close() {
        pc?.close()
        pc = nil
    }

    // MARK: helpers
    private func setBitrate(_ bps: Int) {
        guard let sender = pc?.senders.first(where: { $0.track?.kind == "audio" }) else { return }
        let params = sender.parameters
        for enc in params.encodings {
            enc.maxBitrateBps = NSNumber(value: bps)
            enc.networkPriority = .high          // prioritize getting packets out fast
        }
        sender.parameters = params
    }
}

// MARK: - RTCPeerConnectionDelegate
extension BroadcastPeer: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        var c: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex]
        if let mid = candidate.sdpMid { c["sdpMid"] = mid }
        onSignal(["type": "signal", "to": id, "data": ["candidate": c]])
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        if newState == .failed || newState == .closed { onClosed() }
    }
    // Unused delegate stubs.
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {}
}
