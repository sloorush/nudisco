import Foundation
import CoreAudio
import AppKit

/// One audio-producing process the DJ can choose to capture (instead of the whole
/// system). Backed by Core Audio's process object list (macOS 14.2+).
struct AudioProcess: Identifiable, Hashable {
    let id: AudioObjectID        // the Core Audio process object id (passed to CATapDescription)
    let pid: pid_t
    let name: String
    let bundleID: String?
}

enum AudioProcessList {

    /// Processes currently playing audio, resolved to friendly app names and
    /// sorted. Falls back to the bundle id when no app name is available.
    static func current() -> [AudioProcess] {
        let objects = processObjectIDs()
        var seen = Set<pid_t>()
        var out: [AudioProcess] = []
        for obj in objects {
            guard let pid = pid(of: obj), !seen.contains(pid) else { continue }
            // Only list processes actually producing output audio.
            guard isRunningOutput(obj) else { continue }
            seen.insert(pid)
            let bundleID = string(of: obj, kAudioProcessPropertyBundleID)
            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName
                ?? bundleID
                ?? "pid \(pid)"
            out.append(AudioProcess(id: obj, pid: pid, name: name, bundleID: bundleID))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Core Audio plumbing
    private static func processObjectIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let sys = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, $0.baseAddress!)
        }
        return status == noErr ? ids : []
    }

    private static func pid(of obj: AudioObjectID) -> pid_t? {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var pid: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &pid) == noErr, pid > 0 else { return nil }
        return pid
    }

    private static func isRunningOutput(_ obj: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningOutput,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    private static func string(of obj: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == noErr else { return nil }
        return value as String?
    }
}
