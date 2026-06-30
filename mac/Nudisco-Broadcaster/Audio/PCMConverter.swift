import Foundation
import CoreAudio
import AVFAudio

/// Thin wrapper over Core Audio's AudioConverter for SAME-sample-rate format
/// changes — e.g. float32 (de)interleaved -> int16 interleaved, which is what
/// libwebrtc's audio buffer wants. Sample-RATE conversion is intentionally left
/// to WebRTC: we advertise the capture device's native rate as the ADM input
/// rate and libwebrtc resamples to 48 kHz internally. That keeps this converter
/// trivial and robust, so it requires `from.sampleRate == to.sampleRate`.
final class PCMConverter {
    let from: AVAudioFormat
    let to: AVAudioFormat
    private var converter: AudioConverterRef?

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard from.sampleRate == to.sampleRate else {
            print("PCMConverter: refusing sample-rate change \(from.sampleRate) -> \(to.sampleRate)")
            return nil
        }
        var c: AudioConverterRef?
        guard AudioConverterNew(from.streamDescription, to.streamDescription, &c) == noErr,
              let c = c else { return nil }
        self.converter = c
        self.from = from
        self.to = to
    }

    deinit {
        if let converter = converter { AudioConverterDispose(converter) }
    }

    /// Convert `frames` of audio from `src` into `dst`. `dst` is pre-allocated by
    /// the caller (libwebrtc) for `frames` at the `to` format.
    func convert(frames: AVAudioFrameCount,
                 from src: UnsafePointer<AudioBufferList>,
                 to dst: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard let converter = converter else { return kAudioConverterErr_UnspecifiedError }
        return AudioConverterConvertComplexBuffer(converter, frames, src, dst)
    }
}
