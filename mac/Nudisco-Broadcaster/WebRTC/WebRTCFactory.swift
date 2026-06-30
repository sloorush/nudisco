import Foundation
import WebRTC

/// The single libwebrtc factory for the whole app, wired to our custom audio
/// device so that the audio we CAPTURE is what gets sent. Every peer connection
/// and the shared outgoing audio track are created here.
final class WebRTCFactory {
    static let shared = WebRTCFactory()

    /// The ADM the capture layer pushes PCM into (see `NudiscoAudioDevice.deliver`).
    let audioDevice = NudiscoAudioDevice()
    let factory: RTCPeerConnectionFactory

    /// One shared outgoing track fed by the captured audio. The same track is
    /// added to every listener's peer connection (a one-to-many mesh) — encoding
    /// still happens per-connection, exactly like the web broadcaster.
    private(set) lazy var sharedAudioTrack: RTCAudioTrack = makeAudioTrack()

    private init() {
        RTCInitializeSSL()
        // ⚠️ Spike 0: this initializer (the `audioDevice:` variant) must exist in
        // the resolved WebRTC package. If the build can't find it, the prebuilt
        // binary doesn't expose custom-audio — switch project.yml's WebRTC url to
        // https://github.com/webrtc-sdk/webrtc (Fallback A) and rebuild.
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory(),
            audioDevice: audioDevice)
    }

    private func makeAudioTrack() -> RTCAudioTrack {
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let source = factory.audioSource(with: c)
        return factory.audioTrack(with: source, trackId: "nudisco-audio")
    }

    func newPeerConnection(delegate: RTCPeerConnectionDelegate) -> RTCPeerConnection? {
        let cfg = RTCConfiguration()
        cfg.iceServers = []                  // LAN-only: host candidates, no STUN/TURN
        cfg.sdpSemantics = .unifiedPlan
        cfg.bundlePolicy = .maxBundle
        cfg.rtcpMuxPolicy = .require
        let c = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        return factory.peerConnection(with: cfg, constraints: c, delegate: delegate)
    }
}
