import Cocoa
import CoreAudio
import AudioToolbox

public enum AudioDirection: Sendable {
    case output, input

    var scope: AudioObjectPropertyScope {
        self == .output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
    }

    var defaultDeviceSelector: AudioObjectPropertySelector {
        self == .output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice
    }
}

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public enum Transport: Sendable { case builtIn, bluetooth, usb, display, airplay, virtual, other }

    public let id: AudioDeviceID
    public let name: String
    public let transport: Transport

    /// SF Symbol that best describes the device, e.g. AirPods, a webcam mic or a laptop speaker.
    public func symbol(for direction: AudioDirection) -> String {
        let n = name.lowercased()
        if n.contains("airpods max") { return "airpodsmax" }
        if n.contains("airpods pro") { return "airpodspro" }
        if n.contains("airpods") { return "airpods" }
        if n.contains("headphone") || n.contains("headset") || n.contains("buds") { return "headphones" }
        if direction == .input, n.contains("cam") || n.contains("4k") { return "web.camera" }
        switch transport {
        case .builtIn: return direction == .output ? "laptopcomputer" : "mic"
        case .display: return "display"
        case .airplay: return "airplayaudio"
        case .virtual: return "waveform"
        case .bluetooth: return direction == .output ? "hifispeaker" : "mic"
        case .usb, .other: return direction == .output ? "hifispeaker" : "mic"
        }
    }
}

/// Reads and drives the default output and input devices, pushing changes into TalysDesktopState as CoreAudio reports them.
@MainActor
public final class AudioController {
    public static let shared = AudioController()

    /// Per-direction device tracking: the current default device, its listeners and soft-mute memory.
    private final class Endpoint {
        let direction: AudioDirection
        var deviceID: AudioDeviceID = 0
        var listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
        /// Level to restore when unmuting a device that has no hardware mute.
        var softMuteRestore: Float?

        init(_ direction: AudioDirection) { self.direction = direction }
    }

    private let output = Endpoint(.output)
    private let input = Endpoint(.input)
    private var started = false

    private init() {}

    public func start() {
        guard !started else { return }
        started = true

        let system = AudioObjectID(kAudioObjectSystemObject)
        for endpoint in [output, input] {
            listen(on: system, selector: endpoint.direction.defaultDeviceSelector) { [weak self] in
                self?.attach(endpoint)
            }
        }
        listen(on: system, selector: kAudioHardwarePropertyDevices) { [weak self] in
            self?.refreshDevices()
        }
        attach(output)
        attach(input)
    }

    // MARK: - Output actions

    public func setVolume(_ value: Float) { setVolume(value, on: output) }
    public func adjustVolume(by delta: Float) { setVolume(readVolume(output) + delta, on: output) }
    public func toggleMute() { setMuted(!TalysDesktopState.shared.isMuted, on: output) }
    public func setMuted(_ muted: Bool) { setMuted(muted, on: output) }
    public func selectOutput(_ id: AudioDeviceID) { setDefault(id, for: .output) }

    // MARK: - Input actions

    public func setInputVolume(_ value: Float) { setVolume(value, on: input) }
    public func toggleInputMute() { setMuted(!TalysDesktopState.shared.isInputMuted, on: input) }
    public func selectInput(_ id: AudioDeviceID) { setDefault(id, for: .input) }

    // MARK: - Shared implementation

    private func setVolume(_ value: Float, on endpoint: Endpoint) {
        let v = max(0, min(1, value))
        let id = endpoint.deviceID
        guard id != 0 else { return }
        var vol = Float32(v)
        let size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: endpoint.direction.scope)
        if AudioObjectSetPropertyData(id, &address, 0, nil, size, &vol) != noErr {
            // Devices without a virtual main volume: drive the main element or each channel directly.
            for element in volumeElements(endpoint) {
                var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: endpoint.direction.scope, element: element)
                AudioObjectSetPropertyData(id, &a, 0, nil, size, &vol)
            }
        }
        // Raising the volume unmutes, like the hardware keys do.
        if v > 0, readMute(endpoint) { setMuted(false, on: endpoint) }
        refreshLevels(endpoint)
    }

    private func setMuted(_ muted: Bool, on endpoint: Endpoint) {
        let id = endpoint.deviceID
        guard id != 0 else { return }
        var address = Self.address(kAudioDevicePropertyMute, scope: endpoint.direction.scope)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &address),
           AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue {
            var value: UInt32 = muted ? 1 : 0
            AudioObjectSetPropertyData(id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        } else if muted {
            endpoint.softMuteRestore = readVolume(endpoint)
            setVolume(0, on: endpoint)
        } else {
            let restore = endpoint.softMuteRestore ?? 0.5
            endpoint.softMuteRestore = nil
            setVolume(restore, on: endpoint)
        }
        refreshLevels(endpoint)
    }

    private func setDefault(_ id: AudioDeviceID, for direction: AudioDirection) {
        var newID = id
        var address = Self.address(direction.defaultDeviceSelector)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &newID)
    }

    // MARK: - State sync

    private func attach(_ endpoint: Endpoint) {
        for (addr, block) in endpoint.listeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(endpoint.deviceID, &a, DispatchQueue.main, block)
        }
        endpoint.listeners.removeAll()
        endpoint.softMuteRestore = nil

        endpoint.deviceID = Self.defaultDevice(endpoint.direction)
        if endpoint.deviceID != 0 {
            // Volume may be reported on the main element or per channel depending on the device.
            for element in [kAudioObjectPropertyElementMain, 1, 2] {
                listenOnDevice(endpoint, kAudioDevicePropertyVolumeScalar, element: element)
            }
            listenOnDevice(endpoint, kAudioDevicePropertyMute, element: kAudioObjectPropertyElementMain)
        }
        refreshDevices()
        refreshLevels(endpoint)
    }

    private func refreshLevels(_ endpoint: Endpoint) {
        let state = TalysDesktopState.shared
        let pct = Int((readVolume(endpoint) * 100).rounded())
        let muted = readMute(endpoint)
        let settable = isVolumeSettable(endpoint)
        switch endpoint.direction {
        case .output:
            if state.volumePercent != pct { state.volumePercent = pct }
            if state.isMuted != muted { state.isMuted = muted }
            if state.outputVolumeSettable != settable { state.outputVolumeSettable = settable }
        case .input:
            if state.inputVolumePercent != pct { state.inputVolumePercent = pct }
            if state.isInputMuted != muted { state.isInputMuted = muted }
            if state.inputVolumeSettable != settable { state.inputVolumeSettable = settable }
        }
    }

    private func refreshDevices() {
        let state = TalysDesktopState.shared
        let outputs = Self.devices(.output)
        let inputs = Self.devices(.input)
        if state.outputDevices != outputs { state.outputDevices = outputs }
        if state.inputDevices != inputs { state.inputDevices = inputs }
        if state.outputDeviceID != output.deviceID { state.outputDeviceID = output.deviceID }
        if state.inputDeviceID != input.deviceID { state.inputDeviceID = input.deviceID }
        let outName = outputs.first { $0.id == output.deviceID }?.name ?? ""
        let inName = inputs.first { $0.id == input.deviceID }?.name ?? ""
        if state.outputDeviceName != outName { state.outputDeviceName = outName }
        if state.inputDeviceName != inName { state.inputDeviceName = inName }
    }

    private func readVolume(_ endpoint: Endpoint) -> Float {
        let id = endpoint.deviceID
        guard id != 0 else { return 0 }
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: endpoint.direction.scope)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &vol) == noErr {
            return max(0, min(1, vol))
        }
        let levels = volumeElements(endpoint).compactMap { element -> Float32? in
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: endpoint.direction.scope, element: element)
            var v: Float32 = 0
            var s = UInt32(MemoryLayout<Float32>.size)
            return AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v) == noErr ? v : nil
        }
        // Fixed-volume devices (HDMI, some DACs and USB mics) expose no level at all.
        guard !levels.isEmpty else { return 1 }
        return max(0, min(1, levels.reduce(0, +) / Float(levels.count)))
    }

    private func readMute(_ endpoint: Endpoint) -> Bool {
        let id = endpoint.deviceID
        guard id != 0 else { return false }
        var address = Self.address(kAudioDevicePropertyMute, scope: endpoint.direction.scope)
        var mute: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &mute) == noErr {
            return mute == 1
        }
        return endpoint.softMuteRestore != nil
    }

    private func isVolumeSettable(_ endpoint: Endpoint) -> Bool {
        let id = endpoint.deviceID
        guard id != 0 else { return false }
        var address = Self.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, scope: endpoint.direction.scope)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(id, &address),
           AudioObjectIsPropertySettable(id, &address, &settable) == noErr, settable.boolValue {
            return true
        }
        return !volumeElements(endpoint).isEmpty
    }

    /// Elements that carry a settable volume scalar: the main element for mono/master control, else the stereo pair.
    private func volumeElements(_ endpoint: Endpoint) -> [AudioObjectPropertyElement] {
        let id = endpoint.deviceID
        let scope = endpoint.direction.scope
        var channels: [UInt32] = [1, 2]
        var address = Self.address(kAudioDevicePropertyPreferredChannelsForStereo, scope: scope)
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        _ = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &channels)

        let candidates = [kAudioObjectPropertyElementMain] + channels
        let settable = candidates.filter { element in
            var a = Self.address(kAudioDevicePropertyVolumeScalar, scope: scope, element: element)
            var ok: DarwinBoolean = false
            return AudioObjectHasProperty(id, &a) && AudioObjectIsPropertySettable(id, &a, &ok) == noErr && ok.boolValue
        }
        // Prefer the main element alone so we don't double-apply on devices that expose both.
        return settable.contains(kAudioObjectPropertyElementMain) ? [kAudioObjectPropertyElementMain] : settable
    }

    // MARK: - Listeners

    private func listen(on object: AudioObjectID, selector: AudioObjectPropertySelector, _ handler: @escaping @MainActor () -> Void) {
        var address = Self.address(selector)
        AudioObjectAddPropertyListenerBlock(object, &address, DispatchQueue.main) { _, _ in
            MainActor.assumeIsolated { handler() }
        }
    }

    private func listenOnDevice(_ endpoint: Endpoint, _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement) {
        var address = Self.address(selector, scope: endpoint.direction.scope, element: element)
        guard AudioObjectHasProperty(endpoint.deviceID, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self, weak endpoint] _, _ in
            MainActor.assumeIsolated {
                guard let self, let endpoint else { return }
                self.refreshLevels(endpoint)
            }
        }
        if AudioObjectAddPropertyListenerBlock(endpoint.deviceID, &address, DispatchQueue.main, block) == noErr {
            endpoint.listeners.append((address, block))
        }
    }

    // MARK: - CoreAudio helpers

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func defaultDevice(_ direction: AudioDirection) -> AudioDeviceID {
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = address(direction.defaultDeviceSelector)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return err == noErr ? id : 0
    }

    private static func devices(_ direction: AudioDirection) -> [AudioDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streams = Self.address(kAudioDevicePropertyStreams, scope: direction.scope)
            var streamSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamSize) == noErr, streamSize > 0 else { return nil }

            var nameAddress = Self.address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, &name) == noErr,
                  let cfName = name?.takeRetainedValue() else { return nil }
            return AudioDevice(id: id, name: cfName as String, transport: transport(of: id))
        }
    }

    private static func transport(of id: AudioDeviceID) -> AudioDevice.Transport {
        var address = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return .other }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return .display
        case kAudioDeviceTransportTypeAirPlay: return .airplay
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }
}
