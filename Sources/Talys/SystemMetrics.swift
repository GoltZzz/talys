import Cocoa
import IOKit.ps
import CoreWLAN
import CoreLocation

@MainActor
public final class SystemMetricsService {
    public static let shared = SystemMetricsService()

    private var timer: Timer?
    private let timeFormatter = DateFormatter()
    private let dateFormatter = DateFormatter()
    private let altTimeFormatter = DateFormatter()
    /// macOS 14+ hides the Wi-Fi SSID from apps without Location access.
    private let locationManager = CLLocationManager()

    public init() {
        dateFormatter.dateFormat = "EEE MMM d"
        setClock12Hour(true)
    }

    public func setClock12Hour(_ twelveHour: Bool) {
        timeFormatter.dateFormat = twelveHour ? "h:mm a" : "HH:mm"
        altTimeFormatter.dateFormat = twelveHour ? "h:mm:ss a" : "HH:mm:ss"
        refreshAll()
    }

    public func start() {
        if locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
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

        // ssid() is nil without Location access; fall back to the generic label.
        let ssid = interface.ssid() ?? "Wi-Fi"
        return (interface.rssiValue() != 0, ssid)
    }
}
