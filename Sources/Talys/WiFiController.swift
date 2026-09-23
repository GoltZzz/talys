import Cocoa
import CoreWLAN
import CoreLocation
import SystemConfiguration
import Observation

/// A network seen in the latest scan, collapsed to its strongest access point.
struct WiFiNetwork: Identifiable, Equatable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int
    let isSecure: Bool
    let isKnown: Bool
    let band: String?

    var bars: Int { Self.bars(forRSSI: rssi) }

    /// 0...3, roughly the buckets macOS uses for its menu bar icon.
    static func bars(forRSSI rssi: Int) -> Int {
        switch rssi {
        case (-55)...: 3
        case (-67)...: 2
        case (-78)...: 1
        default: 0
        }
    }
}

/// Live facts about the current connection.
struct WiFiDetails: Equatable {
    var ipAddress: String?
    var router: String?
    var rssi: Int
    var noise: Int
    var channel: String?
    var txRate: Double
    var security: String
    var standard: String?
}

/// CoreWLAN objects aren't Sendable; this carries scan results off the scanning thread untouched.
private final class ScanBox: @unchecked Sendable {
    let networks: Set<CWNetwork>
    let knownSSIDs: Set<String>
    init(networks: Set<CWNetwork>, knownSSIDs: Set<String>) {
        self.networks = networks
        self.knownSSIDs = knownSSIDs
    }
}

private final class NetworkBox: @unchecked Sendable {
    let network: CWNetwork
    init(_ network: CWNetwork) { self.network = network }
}

/// Drives the Wi-Fi panel: power, scanning, joining and connection details. Polls only while the panel is open.
@Observable
@MainActor
final class WiFiController {
    static let shared = WiFiController()

    private(set) var isPowered = false
    private(set) var currentSSID: String?
    private(set) var details: WiFiDetails?
    /// Saved networks in range, strongest first. Excludes the current one.
    private(set) var knownNetworks: [WiFiNetwork] = []
    /// Everything else in range, strongest first.
    private(set) var otherNetworks: [WiFiNetwork] = []
    private(set) var isScanning = false
    private(set) var hasScanned = false
    private(set) var joiningSSID: String?
    /// The network whose row is expanded to ask for a password.
    var passwordPromptSSID: String?
    private(set) var joinError: String?
    private(set) var locationDenied = false

    @ObservationIgnored private var scanned: [String: CWNetwork] = [:]
    @ObservationIgnored private var detailsTimer: Timer?
    @ObservationIgnored private var scanTimer: Timer?

    private init() {}

    private var interface: CWInterface? { CWWiFiClient.shared().interface() }

    // MARK: - Lifecycle

    func start() {
        passwordPromptSSID = nil
        joinError = nil
        refreshDetails()
        scan()
        detailsTimer?.invalidate()
        detailsTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in WiFiController.shared.refreshDetails() }
        }
        scanTimer?.invalidate()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: true) { _ in
            Task { @MainActor in WiFiController.shared.scan() }
        }
    }

    func stop() {
        detailsTimer?.invalidate()
        scanTimer?.invalidate()
        detailsTimer = nil
        scanTimer = nil
    }

    // MARK: - Actions

    func setPower(_ on: Bool) {
        guard let interface else { return }
        do {
            try interface.setPower(on)
        } catch {
            print("[WiFi] setPower(\(on)) failed: \(error.localizedDescription)")
        }
        refreshDetails()
        SystemMetricsService.shared.refreshAll()
        if on {
            // The radio needs a moment before it can scan.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                MainActor.assumeIsolated { WiFiController.shared.scan() }
            }
        } else {
            knownNetworks = []
            otherNetworks = []
            scanned = [:]
        }
    }

    /// Joins `network`. Secure networks we don't have a password for expand into a password prompt first.
    func select(_ network: WiFiNetwork) {
        guard joiningSSID == nil, network.ssid != currentSSID else { return }
        joinError = nil
        if network.isSecure && !network.isKnown {
            passwordPromptSSID = passwordPromptSSID == network.ssid ? nil : network.ssid
            return
        }
        passwordPromptSSID = nil
        join(network, password: nil)
    }

    func join(_ network: WiFiNetwork, password: String?) {
        guard let cw = scanned[network.ssid] else { return }
        joiningSSID = network.ssid
        joinError = nil
        let box = NetworkBox(cw)
        let password = password?.isEmpty == true ? nil : password

        Task {
            let failure: String? = await Task.detached {
                guard let interface = CWWiFiClient.shared().interface() else { return "Wi-Fi is unavailable" }
                do {
                    try interface.associate(to: box.network, password: password)
                    return nil
                } catch {
                    return error.localizedDescription
                }
            }.value
            finishJoin(network, failure: failure, usedPassword: password != nil)
        }
    }

    func disconnect() {
        interface?.disassociate()
        refreshDetails()
        SystemMetricsService.shared.refreshAll()
        scan()
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLocationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
    }

    private func finishJoin(_ network: WiFiNetwork, failure: String?, usedPassword: Bool) {
        joiningSSID = nil
        if let failure {
            print("[WiFi] join \(network.ssid) failed: \(failure)")
            if network.isSecure {
                // A saved network whose password isn't available to us, or a wrong password: ask (again).
                passwordPromptSSID = network.ssid
                joinError = usedPassword ? "Couldn't join. Check the password." : "Enter the password to join."
            } else {
                joinError = "Couldn't join \(network.ssid)."
            }
        } else {
            passwordPromptSSID = nil
        }
        refreshDetails()
        SystemMetricsService.shared.refreshAll()
        scan()
    }

    // MARK: - Polling

    func refreshDetails() {
        locationDenied = [.denied, .restricted].contains(CLLocationManager().authorizationStatus)

        guard let interface, interface.powerOn() else {
            isPowered = false
            currentSSID = nil
            details = nil
            return
        }
        isPowered = true

        guard interface.rssiValue() != 0 else {
            currentSSID = nil
            details = nil
            return
        }
        currentSSID = interface.ssid()

        let name = interface.interfaceName
        details = WiFiDetails(
            ipAddress: name.flatMap(Self.ipv4Address(of:)),
            router: name.flatMap(Self.router(for:)),
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            channel: interface.wlanChannel().map(Self.describe(channel:)),
            txRate: interface.transmitRate(),
            security: Self.describe(security: interface.security()),
            standard: Self.describe(phyMode: interface.activePHYMode())
        )
    }

    func scan() {
        guard !isScanning, joiningSSID == nil, interface?.powerOn() == true else { return }
        isScanning = true

        Task {
            let box: ScanBox? = await Task.detached {
                guard let interface = CWWiFiClient.shared().interface() else { return nil }
                // Blocks for 1–3 s while the radio sweeps channels.
                guard let networks = try? interface.scanForNetworks(withSSID: nil) else { return nil }
                let profiles = interface.configuration()?.networkProfiles.array as? [CWNetworkProfile] ?? []
                return ScanBox(networks: networks, knownSSIDs: Set(profiles.compactMap(\.ssid)))
            }.value
            isScanning = false
            hasScanned = true
            if let box { apply(box) }
        }
    }

    private func apply(_ box: ScanBox) {
        // Several access points can share an SSID; keep the strongest.
        var strongest: [String: CWNetwork] = [:]
        for network in box.networks {
            guard let ssid = network.ssid, !ssid.isEmpty else { continue }
            if let existing = strongest[ssid], existing.rssiValue >= network.rssiValue { continue }
            strongest[ssid] = network
        }
        scanned = strongest

        let networks = strongest.values
            .map { cw in
                WiFiNetwork(
                    ssid: cw.ssid ?? "",
                    rssi: cw.rssiValue,
                    isSecure: !cw.supportsSecurity(.none),
                    isKnown: box.knownSSIDs.contains(cw.ssid ?? ""),
                    band: cw.wlanChannel.map { Self.describe(band: $0.channelBand) } ?? nil
                )
            }
            .filter { $0.ssid != currentSSID }
            .sorted { $0.rssi > $1.rssi }

        knownNetworks = networks.filter(\.isKnown)
        otherNetworks = networks.filter { !$0.isKnown }
    }

    // MARK: - Lookups

    private static func ipv4Address(of interfaceName: String) -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = ptr.pointee
            guard String(cString: entry.ifa_name) == interfaceName,
                  let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: host)
            }
        }
        return nil
    }

    /// The default gateway, when Wi-Fi is the primary interface.
    private static func router(for interfaceName: String) -> String? {
        guard let store = SCDynamicStoreCreate(nil, "Talys" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              global["PrimaryInterface"] as? String == interfaceName else { return nil }
        return global["Router"] as? String
    }

    private static func describe(channel: CWChannel) -> String {
        let band = describe(band: channel.channelBand).map { " · \($0)" } ?? ""
        return "\(channel.channelNumber)\(band)"
    }

    private static func describe(band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    private static func describe(security: CWSecurity) -> String {
        switch security {
        case .none: "Open"
        case .WEP, .dynamicWEP: "WEP"
        case .wpaPersonal, .wpaPersonalMixed: "WPA"
        case .wpa2Personal: "WPA2"
        case .personal: "WPA2/WPA3"
        case .wpa3Personal: "WPA3"
        case .wpa3Transition: "WPA2/WPA3"
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise: "Enterprise"
        case .OWE, .oweTransition: "Enhanced Open"
        default: "Secured"
        }
    }

    private static func describe(phyMode: CWPHYMode) -> String? {
        switch phyMode {
        case .mode11ax: "Wi-Fi 6"
        case .mode11ac: "Wi-Fi 5"
        case .mode11n: "Wi-Fi 4"
        case .mode11a, .mode11b, .mode11g: "802.11"
        default: nil
        }
    }
}
