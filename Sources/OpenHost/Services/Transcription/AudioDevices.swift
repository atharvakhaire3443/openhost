import Foundation
import CoreAudio

struct AudioOutputDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let audioID: AudioDeviceID
}

enum AudioDevices {
    static func listInputs() -> [AudioInputDevice] {
        enumerate(scope: kAudioDevicePropertyScopeInput).map {
            AudioInputDevice(id: $0.uid, name: $0.name)
        }
    }

    static func listOutputs() -> [AudioOutputDevice] {
        enumerate(scope: kAudioDevicePropertyScopeOutput).map {
            AudioOutputDevice(id: $0.uid, name: $0.name, audioID: $0.id)
        }
    }

    private struct DeviceEntry {
        let id: AudioDeviceID
        let uid: String
        let name: String
    }

    private static func enumerate(scope: AudioObjectPropertyScope) -> [DeviceEntry] {
        var propSize: UInt32 = 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)

        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &propSize) == noErr else { return [] }
        let count = Int(propSize) / MemoryLayout<AudioDeviceID>.size
        if count == 0 { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &propSize, &ids) == noErr else { return [] }

        var out: [DeviceEntry] = []
        for id in ids {
            if hasStreams(deviceID: id, scope: scope), let entry = describe(deviceID: id) {
                out.append(entry)
            }
        }
        return out
    }

    private static func hasStreams(deviceID: AudioDeviceID, scope: AudioObjectPropertyScope) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func describe(deviceID: AudioDeviceID) -> DeviceEntry? {
        var nameAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var nameCF: Unmanaged<CFString>?
        var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameCF) == noErr,
              let name = nameCF?.takeRetainedValue() as String?
        else { return nil }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &uidAddr, 0, nil, &uidSize, &uidCF) == noErr,
              let uid = uidCF?.takeRetainedValue() as String?
        else { return nil }

        return DeviceEntry(id: deviceID, uid: uid, name: name)
    }

    static func find(byUID uid: String) -> AudioDeviceID? {
        listOutputs().first(where: { $0.id == uid })?.audioID
    }
}
