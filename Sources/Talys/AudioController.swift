import Cocoa
import CoreAudio
import AudioToolbox

public struct AudioOutputDevice: Identifiable, Equatable {
    public let id: AudioDeviceID
    public let name: String
}

/// Reads and drives the default output device, pushing changes into TalysDesktopState as CoreAudio reports them.
@MainActor
public final class AudioController {
    public static let shared = AudioController()

    private var deviceID: AudioDeviceID = 0
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var started = false
    /// Level to restore when unmuting a device that has no hardware mute.
    private var softMuteRestore: Float?

    private init() {}

    public func start() {
        guard !started else { return }
        started = true

        listen(on: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice) { [weak self] in
            self?.attachToDefaultDevice()
        }
        listen(on: AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices) { [weak self] in
            self?.refreshDevices()
        }
        attachToDefaultDevice()
    }

    // MARK: - Actions

    public func setVolume(_ value: Float) {
        let v = max(0, min(1, value))
        guard deviceID != 0 else { return }
        var vol = Float32(v)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        let err = AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        if err != noErr {
            // Devices without a virtual main volume: drive each stereo channel directly.
            for channel in stereoChannels() {
                var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: channel)
                AudioObjectSetPropertyData(deviceID, &a, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            }
        }
        // Raising the volume unmutes, like the hardware keys do.
        if v > 0, readMute() { setMuted(false) }
        refreshLevels()
    }

    public func adjustVolume(by delta: Float) {
        setVolume(readVolume() + delta)
    }

    public func toggleMute() {
        setMuted(!TalysDesktopState.shared.isMuted)
    }

    public func setMuted(_ muted: Bool) {
        guard deviceID != 0 else { return }
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectIsPropertySettable(deviceID, &address, &settable) == noErr, settable.boolValue {
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else if muted {
            softMuteRestore = readVolume()
            setVolume(0)
        } else {
            setVolume(softMuteRestore ?? 0.5)
            softMuteRestore = nil
        }
        refreshLevels()
    }

    public func selectOutput(_ id: AudioDeviceID) {
        var newID = id
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &newID)
    }

    // MARK: - State sync

    private func attachToDefaultDevice() {
        for (addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(deviceID, &a, DispatchQueue.main, block)
        }
        deviceListeners.removeAll()
        softMuteRestore = nil

        deviceID = Self.defaultOutputDevice()
        if deviceID != 0 {
            // Volume may be reported on the main element or per channel depending on the device.
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                listenOnDevice(kAudioDevicePropertyVolumeScalar, element: element)
            }
            listenOnDevice(kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        }
        refreshDevices()
        refreshLevels()
    }

    private func refreshLevels() {
        let state = TalysDesktopState.shared
        let pct = Int((readVolume() * 100).rounded())
        let muted = readMute()
        if state.volumePercent != pct { state.volumePercent = pct }
        if state.isMuted != muted { state.isMuted = muted }
    }

    private func refreshDevices() {
        let state = TalysDesktopState.shared
        let devices = Self.outputDevices()
        if state.outputDevices != devices { state.outputDevices = devices }
        let name = devices.first { $0.id == deviceID }?.name ?? ""
        if state.outputDeviceName != name { state.outputDeviceName = name }
    }

    private func readVolume() -> Float {
        guard deviceID != 0 else { return 0 }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: kAudioDevicePropertyScopeOutput)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &vol) == noErr {
            return max(0, min(1, vol))
        }
        let levels = stereoChannels().compactMap { channel -> Float32? in
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: kAudioDevicePropertyScopeOutput, element: channel)
            var v: Float32 = 0
            var s = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(deviceID, &a, 0, nil, &s, &v) == noErr ? v : nil
        }
        // Fixed-volume outputs (HDMI, some DACs) expose no level at all.
        guard !levels.isEmpty else { return 1 }
        return max(0, min(1, levels.reduce(0, +) / Float(levels.count)))
    }

    private func readMute() -> Bool {
        guard deviceID != 0 else { return false }
        var address = Self.address(kAudioDevicePropertyMute, scope: kAudioDevicePropertyScopeOutput)
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &mute) == noErr {
            return mute == 1
        }
        return softMuteRestore != nil
    }

    private func stereoChannels() -> [UInt32] {
        var address = Self.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: kAudioDevicePropertyScopeOutput)
        var channels: [UInt32] = [1, 2]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &channels)
        return channels
    }

    // MARK: - Listeners

    private func listen(on object: AudioObjectID, selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor () -> Void) {
        var address = Self.address(selector)
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func listenOnDevice(_ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) {
        var address = Self.address(selector, scope: kAudioDevicePropertyScopeOutput, element: element)
        guard AudioObjectHasProperty(deviceID, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { AudioController.shared.refreshLevels() }
        }
        if AudioObjectAddPropertyListenerBlock(deviceID, &address, DispatchQueue.main, block) == noErr {
            deviceListeners.append((address, block))
        }
    }

    // MARK: - CoreAudio helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultOutputDevice() -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return err == noErr ? id : 0
    }

    private static func outputDevices() -> [AudioOutputDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }

            var nameAddress = Self.address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let cfName = name?.takeRetainedValue() else { return nil }
            return AudioOutputDevice(id: id, name: cfName as String)
        }
    }
}
