import Foundation
import CoreAudio
import AVFAudio

/// Captures audio NON-DESTRUCTIVELY using a macOS Core Audio process tap
/// (macOS 14.2+). The DJ's audio keeps playing to the speakers normally while we
/// receive a copy and push it into WebRTC via `NudiscoAudioDevice.deliver`.
///
/// Can tap the whole system OR a specific app (e.g. rekordbox / Serato only).
/// The first start triggers the system audio-capture permission prompt
/// (NSAudioCaptureUsageDescription).
///
/// References: Apple "Capturing system audio with Core Audio taps", and
/// github.com/insidegui/AudioCap. Some of these symbols are newer — verify names
/// against the macOS 14.2+ SDK if the build complains.
final class ProcessTapCapture {

    enum Source: Equatable {
        case systemWide
        case processes([AudioObjectID])
    }

    struct TapError: LocalizedError {
        let stage: String
        let status: OSStatus
        var errorDescription: String? { "audio capture failed (\(stage), status \(status))" }
    }

    /// RMS level, already mapped to 0...1 like the web meter, on the main queue.
    var levelHandler: ((Float) -> Void)?

    private let device: NudiscoAudioDevice
    private let ioQueue = DispatchQueue(label: "nudisco.tap.io", qos: .userInteractive)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var tapFormat: AVAudioFormat?
    private var levelDecimator = 0

    // The tap's native format is whatever the system output runs at (often 44.1 kHz,
    // e.g. Spotify). We normalize to a FIXED 48 kHz / 2ch float — the exact format
    // the WebRTC ADM is proven to accept (the test tone) — instead of relying on
    // libwebrtc to resample custom-ADM input on macOS (which doesn't work).
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: 48_000, channels: 2, interleaved: false)!
    private var rateConverter: AVAudioConverter?
    private var outBuffer: AVAudioPCMBuffer?

    init(device: NudiscoAudioDevice) { self.device = device }

    var isRunning: Bool { procID != nil }

    func start(source: Source) throws {
        stop()

        // 1) Describe the tap. Non-destructive: muteBehavior stays .unmuted so the
        //    speakers keep playing while we observe the audio.
        let desc: CATapDescription
        switch source {
        case .systemWide:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .processes(let ids):
            desc = CATapDescription(stereoMixdownOfProcesses: ids)
        }
        desc.name = "nudisco"
        desc.isPrivate = true
        desc.muteBehavior = .unmuted

        // 2) Create the tap.
        var newTap = AudioObjectID(kAudioObjectUnknown)
        var status = AudioHardwareCreateProcessTap(desc, &newTap)
        guard status == noErr else { throw TapError(stage: "create tap", status: status) }
        tapID = newTap

        // 3) Read the tap's UID + stream format.
        let tapUID = try readString(tapID, kAudioTapPropertyUID, stage: "tap uid")
        tapFormat = try readTapFormat(tapID)

        // Set up the tap-native -> 48 kHz/2ch converter (see outFormat).
        guard let tapFmt = tapFormat,
              let conv = AVAudioConverter(from: tapFmt, to: outFormat) else {
            cleanupTap()
            throw TapError(stage: "audio converter", status: -1)
        }
        rateConverter = conv
        outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 8192)

        // 4) Build a private aggregate device that contains the tap.
        let aggUID = UUID().uuidString
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "nudisco-capture",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: tapUID,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        var newAgg = AudioObjectID(kAudioObjectUnknown)
        status = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &newAgg)
        guard status == noErr else {
            cleanupTap()
            throw TapError(stage: "create aggregate", status: status)
        }
        aggregateID = newAgg

        // 5) Install the IOProc — the real-time callback. It converts the tap's
        //    native audio to 48 kHz/2ch and hands it to the WebRTC ADM.
        var newProc: AudioDeviceIOProcID?
        status = AudioDeviceCreateIOProcIDWithBlock(&newProc, aggregateID, ioQueue) {
            [weak self] _, inInputData, inInputTime, _, _ in
            guard let self = self,
                  let conv = self.rateConverter,
                  let outBuf = self.outBuffer,
                  let tapFmt = self.tapFormat,
                  let inBuf = AVAudioPCMBuffer(pcmFormat: tapFmt, bufferListNoCopy: inInputData, deallocator: nil)
            else { return }
            let inFrames = inBuf.frameLength
            guard inFrames > 0 else { return }

            outBuf.frameLength = 0
            var consumed = false
            let inputBlock: AVAudioConverterInputBlock = { _, statusPtr in
                if consumed { statusPtr.pointee = .noDataNow; return nil }
                consumed = true
                statusPtr.pointee = .haveData
                return inBuf
            }
            var convErr: NSError?
            _ = conv.convert(to: outBuf, error: &convErr, withInputFrom: inputBlock)
            if convErr == nil && outBuf.frameLength > 0 {
                self.device.deliver(outBuf.audioBufferList, format: self.outFormat,
                                    frames: outBuf.frameLength, timestamp: inInputTime)
            }
            self.emitLevel(from: inInputData, frames: inFrames)
        }
        guard status == noErr, let proc = newProc else {
            cleanup()
            throw TapError(stage: "create ioproc", status: status)
        }
        procID = proc

        status = AudioDeviceStart(aggregateID, proc)
        guard status == noErr else {
            cleanup()
            throw TapError(stage: "start device", status: status)
        }
    }

    func stop() {
        if let proc = procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        procID = nil
        cleanup()
    }

    // MARK: - level metering (RMS -> 0...1, matching the web meter mapping)
    private func emitLevel(from abl: UnsafePointer<AudioBufferList>, frames: AVAudioFrameCount) {
        levelDecimator += 1
        guard levelDecimator % 5 == 0 else { return }   // ~50ms cadence
        var sum: Double = 0
        var count = 0
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: abl))
        for buffer in buffers {
            guard let data = buffer.mData else { continue }
            let n = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            let samples = data.assumingMemoryBound(to: Float.self)
            for i in 0..<n { let v = Double(samples[i]); sum += v * v }
            count += n
        }
        guard count > 0 else { return }
        let rms = (sum / Double(count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let pct = Float(max(0, min(1, (db + 60) / 60)))
        DispatchQueue.main.async { self.levelHandler?(pct) }
    }

    // MARK: - teardown helpers
    private func cleanup() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        cleanupTap()
    }
    private func cleanupTap() {
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapFormat = nil
    }

    // MARK: - Core Audio property readers
    private func readString(_ obj: AudioObjectID, _ selector: AudioObjectPropertySelector, stage: String) throws -> String {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let str = value as String? else { throw TapError(stage: stage, status: status) }
        return str
    }

    private func readTapFormat(_ obj: AudioObjectID) throws -> AVAudioFormat {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let status = AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &asbd)
        guard status == noErr, let fmt = AVAudioFormat(streamDescription: &asbd) else {
            throw TapError(stage: "tap format", status: status)
        }
        return fmt
    }
}
