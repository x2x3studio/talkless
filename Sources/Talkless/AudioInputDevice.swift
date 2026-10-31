import CoreAudio
import Foundation

struct AudioInputDevice: Equatable, Identifiable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

/// Read-only Core Audio discovery. Device IDs are transient; only UIDs are persisted.
enum AudioInputDevices {
    static func available() throws -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else {
            throw TalklessError.message(L10n.tr("Cannot list microphones. Try reopening Settings."))
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard !ids.isEmpty else { return [] }
        let status = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else {
            throw TalklessError.message(L10n.tr("Cannot list microphones. Try reopening Settings."))
        }
        return ids.compactMap { id in
            guard hasInputChannels(id),
                  let uid = stringProperty(kAudioDevicePropertyDeviceUID, device: id), !uid.isEmpty else { return nil }
            let name = stringProperty(kAudioObjectPropertyName, device: id) ?? ""
            return AudioInputDevice(id: id, uid: uid, name: name.isEmpty ? L10n.format("Microphone (%@)", uid) : name)
        }.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.uid < $1.uid : order == .orderedAscending
        }
    }

    /// Resolve afresh at recording start. An explicit missing UID never uses the default.
    /// Injectable reads keep selection tests independent of the host's audio hardware.
    static func resolve(
        uid: String?,
        devices: () throws -> [AudioInputDevice] = available,
        defaultDevice: () throws -> AudioDeviceID = systemDefault
    ) throws -> AudioDeviceID {
        guard let uid else { return try defaultDevice() }
        guard let device = try devices().first(where: { $0.uid == uid }) else {
            throw TalklessError.message(L10n.tr("The selected microphone is unavailable. Reconnect it or choose another microphone in Settings › Dictation › Audio."))
        }
        return device.id
    }

    static func systemDefault() throws -> AudioDeviceID {
        let unavailable = TalklessError.message(L10n.tr("No available microphone found. Connect a microphone and select it in System Settings › Sound › Input."))
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                         0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown, hasInputChannels(device) else { throw unavailable }
        return device
    }

    /// Classification is diagnostic only. Private engine aggregates need not expose
    /// membership, and a class read must never authorize an explicit route mismatch.
    static func routeKind(actual: AudioDeviceID, requested: AudioDeviceID) -> String {
        guard actual != kAudioObjectUnknown else { return "unknown" }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyClass, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: AudioClassID = 0
        var size = UInt32(MemoryLayout<AudioClassID>.size)
        if AudioObjectGetPropertyData(actual, &address, 0, nil, &size, &value) == noErr,
           value == kAudioAggregateDeviceClassID { return "aggregate" }
        return actual == requested ? "direct" : "unknown"
    }

    private static func hasInputChannels(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, device: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        // Core Audio name/UID properties return a caller-owned CFString.
        return value?.takeRetainedValue() as String?
    }
}
