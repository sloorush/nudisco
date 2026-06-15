import Foundation
import WebRTC

protocol WebRTCClientDelegate: AnyObject {
    func webRTC(_ c: WebRTCClient, didGenerateCandidate dict: [String: Any])
    func webRTC(_ c: WebRTCClient, didChangeConnection state: RTCPeerConnectionState)
    func webRTCDidReceiveAudio(_ c: WebRTCClient)
}

/// One receive-only WebRTC peer to the broadcaster. The broadcaster is always
/// the OFFERER, so we just apply its offer, answer, and exchange ICE. We add NO
/// local track (receive only) — combined with the .playback audio session this
/// means the app never touches the microphone. RED + audio NACK offered by the
/// broadcaster are decoded/honored by libwebrtc automatically.
final class WebRTCClient: NSObject {
    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    weak var delegate: WebRTCClientDelegate?
    private(set) var remoteAudioTrack: RTCAudioTrack?
    private var pc: RTCPeerConnection?
    private var pendingCandidates: [[String: Any]] = []
    private var hasRemoteDesc = false
    private let preset: BufferPreset

    init(preset: BufferPreset) { self.preset = preset; super.init() }

    func start() {
        let cfg = RTCConfiguration()
        cfg.iceServers = []                       // LAN-only: host candidates, no STUN/TURN
        cfg.sdpSemantics = .unifiedPlan
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        cfg.audioJitterBufferMaxPackets = preset.jitterMaxPackets
        cfg.audioJitterBufferFastAccelerate = preset.fastAccelerate
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc = WebRTCClient.factory.peerConnection(with: cfg, constraints: c, delegate: self)
    }

    func close() {
        pc?.close(); pc = nil
        remoteAudioTrack = nil; pendingCandidates = []; hasRemoteDesc = false
    }

    /// Apply the broadcaster's offer, create + set our answer, return answer SDP.
    func handleOffer(_ sdp: String, completion: @escaping (String?) -> Void) {
        guard let pc = pc else { completion(nil); return }
        pc.setRemoteDescription(RTCSessionDescription(type: .offer, sdp: sdp)) { [weak self] err in
            guard let self = self else { return }
            if let err = err { print("setRemoteDescription:", err); completion(nil); return }
            self.hasRemoteDesc = true
            let mc = RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"],
                                         optionalConstraints: nil)
            pc.answer(for: mc) { answer, err in
                guard let answer = answer else { print("createAnswer:", err as Any); completion(nil); return }
                pc.setLocalDescription(answer) { _ in
                    self.flushCandidates()
                    completion(answer.sdp)
                }
            }
        }
    }

    func addRemoteCandidate(_ dict: [String: Any]) {
        hasRemoteDesc ? apply(dict) : pendingCandidates.append(dict)
    }

    func setMuted(_ muted: Bool) { remoteAudioTrack?.isEnabled = !muted }

    /// Returns (estMs, rttMs, jbMs, jitterMs) for the latency readout + reporting.
    func stats(_ completion: @escaping (Double?, Double?, Double?, Double?) -> Void) {
        guard let pc = pc else { completion(nil, nil, nil, nil); return }
        pc.statistics { report in
            var jbDelay: Double?, jbCount: Double?, jitter: Double?, rtt: Double?
            for (_, s) in report.statistics {
                if s.type == "inbound-rtp", (s.values["kind"] as? String) == "audio" {
                    jbDelay = (s.values["jitterBufferDelay"] as? NSNumber)?.doubleValue
                    jbCount = (s.values["jitterBufferEmittedCount"] as? NSNumber)?.doubleValue
                    jitter  = (s.values["jitter"] as? NSNumber)?.doubleValue
                } else if s.type == "candidate-pair", (s.values["state"] as? String) == "succeeded" {
                    if let r = (s.values["currentRoundTripTime"] as? NSNumber)?.doubleValue { rtt = r }
                }
            }
            let rttMs = rtt.map { $0 * 1000 }
            var jbMs: Double?
            if let d = jbDelay, let c = jbCount, c > 0 { jbMs = d / c * 1000 }
            var est: Double?
            // Native output buffer is small, so a ~30ms pipeline constant (vs 48 on web).
            if let jb = jbMs { est = (rttMs.map { $0 / 2 } ?? 0) + jb + 30 }
            completion(est, rttMs, jbMs, jitter.map { $0 * 1000 })
        }
    }

    // MARK: helpers
    private func flushCandidates() { pendingCandidates.forEach(apply); pendingCandidates = [] }
    private func apply(_ dict: [String: Any]) {
        guard let pc = pc, let cand = dict["candidate"] as? String else { return }
        let idx = (dict["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        let candidate = RTCIceCandidate(sdp: cand, sdpMLineIndex: idx, sdpMid: dict["sdpMid"] as? String)
        pc.add(candidate) { error in
            if let error = error { print("addIceCandidate:", error) }
        }
    }
}

extension WebRTCClient: RTCPeerConnectionDelegate {
    func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        var d: [String: Any] = ["candidate": candidate.sdp, "sdpMLineIndex": candidate.sdpMLineIndex]
        if let mid = candidate.sdpMid { d["sdpMid"] = mid }
        delegate?.webRTC(self, didGenerateCandidate: d)
    }
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        delegate?.webRTC(self, didChangeConnection: newState)
    }
    func peerConnection(_ pc: RTCPeerConnection, didAdd receiver: RTCRtpReceiver, streams: [RTCMediaStream]) {
        if let track = receiver.track as? RTCAudioTrack {
            track.isEnabled = true
            remoteAudioTrack = track
            DispatchQueue.main.async { self.delegate?.webRTCDidReceiveAudio(self) }
        }
    }
    // Required delegate stubs (unused).
    func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {}
    func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
