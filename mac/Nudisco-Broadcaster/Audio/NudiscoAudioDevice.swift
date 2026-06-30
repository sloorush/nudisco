import Foundation
import AVFAudio
import CoreAudio
import WebRTC

/// Custom WebRTC audio device (ADM). Instead of libwebrtc opening the microphone,
/// WE feed it the audio we capture (the DJ's system/app audio) by calling
/// `deliver(...)` from our capture callback. This is the macOS analogue of the
/// iOS-only "inject custom audio" feature; the protocol shape and the
/// deliverRecordedData / renderBlock mechanics mirror the canonical example at
/// github.com/mstyura/RTCAudioDevice.
///
/// ⚠️ Spike 0 (see mac/README.md): this whole approach depends on the resolved
/// WebRTC package exposing the `RTCAudioDevice` protocol AND
/// `RTCPeerConnectionFactory(encoderFactory:decoderFactory:audioDevice:)`. Prove
/// that first with the built-in Test Tone source before trusting the real tap.
final class NudiscoAudioDevice: NSObject {
    // Held strong, matching the reference implementation. The app creates exactly
    // one factory for its lifetime, so there's no meaningful retain-cycle concern.
    private var delegate: RTCAudioDeviceDelegate?

    // Captured ONCE when recording starts so the real-time `deliver()` path never
    // touches the delegate (and never locks) per audio buffer.
    private var deliverBlock: RTCAudioDeviceDeliverRecordedDataBlock?
    private var recording = false

    // Advertised input format. Kept equal to the producer's sample rate/channels;
    // libwebrtc resamples this to 48 kHz for Opus. Default to 48k stereo.
    private var inSampleRate: Double = 48_000
    private var inChannels: Int = 2
    private var rtcInputFormat: AVAudioFormat?
    private var converter: PCMConverter?

    /// Push captured audio into WebRTC. Called from the capture thread — the
    /// process-tap IOProc in production, or the sine generator during Spike 0.
    /// `src` holds `frames` of audio described by `format`. No-op until libwebrtc
    /// has started recording (i.e. there's at least one listener pulling audio).
    func deliver(_ src: UnsafePointer<AudioBufferList>,
                 format: AVAudioFormat,
                 frames: AVAudioFrameCount,
                 timestamp: UnsafePointer<AudioTimeStamp>) {
        guard let deliver = deliverBlock else { return }
        ensureFormat(format)
        guard let converter = converter else { return }

        var flags = AudioUnitRenderActionFlags()
        // Mirror the reference: pass inputData = nil + a renderContext + a
        // renderBlock that converts our captured buffer into the int16 buffer
        // libwebrtc hands us. The call is synchronous, so the on-stack context
        // pointer stays valid for the duration of the renderBlock.
        var ctx = (Unmanaged.passUnretained(converter), src)
        let renderBlock: RTCAudioDeviceRenderRecordedDataBlock = { _, _, _, frameCount, outABL, rawCtx in
            let (conv, input) = rawCtx!
                .assumingMemoryBound(to: (Unmanaged<PCMConverter>, UnsafePointer<AudioBufferList>).self)
                .pointee
            return conv.takeUnretainedValue().convert(frames: frameCount, from: input, to: outABL)
        }
        _ = withUnsafeMutablePointer(to: &ctx) { ctxPtr in
            deliver(&flags, timestamp, 1, frames, nil, ctxPtr, renderBlock)
        }
    }

    /// Rebuild the converter when the producer's format changes (e.g. the DJ
    /// switches output device / sample rate) and tell libwebrtc to reconfigure.
    private func ensureFormat(_ format: AVAudioFormat) {
        let sr = format.sampleRate
        let ch = min(2, Int(format.channelCount))
        if converter != nil && sr == inSampleRate && ch == inChannels { return }
        inSampleRate = sr
        inChannels = ch
        let rtc = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                sampleRate: sr,
                                channels: AVAudioChannelCount(ch),
                                interleaved: true)
        rtcInputFormat = rtc
        converter = rtc.flatMap { PCMConverter(from: format, to: $0) }
        // Must notify so webrtc::AudioDeviceBuffer matches our advertised params.
        delegate?.notifyAudioInputParametersChange()
    }
}

// MARK: - RTCAudioDevice
// Property/method names match the WebRTC ObjC SDK (verify against the resolved
// package's RTCAudioDevice.h if a method ever fails to override).
extension NudiscoAudioDevice: RTCAudioDevice {
    var deviceInputSampleRate: Double { inSampleRate }
    var deviceOutputSampleRate: Double { 48_000 }            // unused (send-only)
    var inputIOBufferDuration: TimeInterval { 0.01 }
    var outputIOBufferDuration: TimeInterval { 0.01 }
    var inputNumberOfChannels: Int { inChannels }
    var outputNumberOfChannels: Int { 2 }                    // unused (send-only)
    var inputLatency: TimeInterval { 0 }
    var outputLatency: TimeInterval { 0 }

    var isInitialized: Bool { delegate != nil }

    func initialize(with delegate: RTCAudioDeviceDelegate) -> Bool {
        guard self.delegate == nil else { return false }
        self.delegate = delegate
        return true
    }

    func terminateDevice() -> Bool {
        recording = false
        deliverBlock = nil
        delegate = nil
        return true
    }

    // Playout is unused — the broadcaster only sends. Implement harmlessly so the
    // ADM initializes both directions without doing anything on output.
    var isPlayoutInitialized: Bool { isInitialized }
    func initializePlayout() -> Bool { isInitialized }
    var isPlaying: Bool { false }
    func startPlayout() -> Bool { true }
    func stopPlayout() -> Bool { true }

    var isRecordingInitialized: Bool { isInitialized }
    func initializeRecording() -> Bool { isInitialized }
    var isRecording: Bool { recording }

    func startRecording() -> Bool {
        deliverBlock = delegate?.deliverRecordedData
        recording = true
        return true
    }

    func stopRecording() -> Bool {
        recording = false
        deliverBlock = nil
        return true
    }
}
