import Cocoa
import IOKit.ps
import CoreWLAN
import AudioToolbox

@MainActor
public final class SystemMetricsService {
    public static let shared = SystemMetricsService()

    private var timer: Timer?
    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()
    private let altTimeFormatter = DateFormatter()

    public init() {
        timeFormatter.dateFormat = "HH:mm"
        dateFormatter.dateFormat = "EEE MMM d"
        altTimeFormatter.dateFormat = "HH:mm:ss"
    }

    public func start() {
        refreshAll()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshAll()
            }
        }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    public func refreshAll() {
        let now = Date()
        let state = TalysDesktopState.shared

        // Clock & Date
        if state.showAltClock {
            state.timeString = altTimeFormatter.string(from: now)
        } else {
            state.timeString = timeFormatter.string(from: now)
        }
        state.dateString = dateFormatter.string(from: now)

        // Battery
        let (pct, charging) = getBatteryInfo()
        state.batteryPercent = pct
        state.isCharging = charging

        // Wi-Fi
        let (connected, ssid) = getWiFiInfo()
        state.wifiConnected = connected
        state.wifiSSID = ssid

        // Audio
        let (vol, muted) = getAudioVolume()
        state.volumePercent = Int(vol * 100.0)
        state.isMuted = muted
    }

    private func getBatteryInfo() -> (Int, Bool) {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return (100, false)
        }

        for source in sources {
            guard let info = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any],
                  let current = info[kIOPSCurrentCapacityKey as String] as? Int,
                  let max = info[kIOPSMaxCapacityKey as String] as? Int,
                  max > 0 else { continue }

            let isCharging = (info[kIOPSIsChargingKey as String] as? Bool) ?? false
            let pct = Int((Double(current) / Double(max)) * 100.0)
            return (pct, isCharging)
        }
        return (100, false)
    }

    private func getWiFiInfo() -> (Bool, String) {
        guard let interface = CWWiFiClient.shared().interface(),
              interface.powerOn() else {
            return (false, "Off")
        }

        let ssid = interface.ssid() ?? "Wi-Fi"
        let rssi = interface.rssiValue()
        return (rssi != 0, ssid)
    }

    private func getAudioVolume() -> (Float, Bool) {
        var defaultDeviceID = AudioDeviceID(0)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &defaultDeviceID
        ) == noErr else {
            return (0.5, false)
        }

        var vol: Float32 = 0.5
        address.mSelector = kAudioDevicePropertyVolumeScalar
        address.mScope = kAudioDevicePropertyScopeOutput
        address.mElement = kAudioObjectPropertyElementMain
        var volSize = UInt32(MemoryLayout<Float32>.size)
        
        let err = AudioObjectGetPropertyData(defaultDeviceID, &address, 0, nil, &volSize, &vol)
        if err != noErr {
            // Some devices use element 1 for channel 1
            address.mElement = 1
            _ = AudioObjectGetPropertyData(defaultDeviceID, &address, 0, nil, &volSize, &vol)
        }

        var mute: UInt32 = 0
        address.mSelector = kAudioDevicePropertyMute
        var muteSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(defaultDeviceID, &address, 0, nil, &muteSize, &mute)

        return (max(0.0, min(1.0, vol)), mute == 1)
    }
}
