import Cocoa
import IOBluetooth
import Observation
import Darwin

// MARK: - Device model

struct BluetoothDevice: Identifiable, Equatable, Sendable {
    let id: String
    var name: String
    var address: String
    var minorType: String
    var isConnected: Bool
    var battery: Int?
    var batteryLeft: Int?
    var batteryRight: Int?
    var batteryCase: Int?
    var isAudio: Bool
    var symbol: String
    var category: String

    var batteryHelp: String? {
        var parts: [String] = []
        if let batteryLeft { parts.append("L \(batteryLeft)%") }
        if let batteryRight { parts.append("R \(batteryRight)%") }
        if let batteryCase { parts.append("Case \(batteryCase)%") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

// MARK: - Controller

@Observable
@MainActor
final class BluetoothController {
    static let shared = BluetoothController()

    private(set) var isPowered = false
    private(set) var isBusy = false
    private(set) var activity: String?
    private(set) var errorMessage: String?
    private(set) var devices: [BluetoothDevice] = []

    private var timer: Timer?
    private var started = false
    private var panelOpen = false
    private var fullRefreshInFlight = false
    private var refreshGeneration = 0
    private var lastFullRefresh = Date.distantPast
    private var lastConnectedKey = ""

    private init() {}

    // MARK: Derived state

    var connectedDevices: [BluetoothDevice] {
        devices.filter(\.isConnected)
    }

    /// Audio first, as chosen in the design. Among several audio devices, prefer one that reports
    /// charge, then fall back to name so the label does not jump around between refreshes.
    var primaryDevice: BluetoothDevice? {
        let connected = connectedDevices
        return connected.sorted { lhs, rhs in
            if lhs.isAudio != rhs.isAudio { return lhs.isAudio }
            if (lhs.battery != nil) != (rhs.battery != nil) { return lhs.battery != nil }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.first
    }

    var pairedDevices: [BluetoothDevice] {
        devices.filter { !$0.isConnected }
    }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        refreshGeneration += 1
        isPowered = Self.readPower()
        refreshNow()

        let timer = Timer(timeInterval: 2.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        started = false
        panelOpen = false
        fullRefreshInFlight = false
        refreshGeneration += 1
    }

    /// Called when the Bluetooth popover opens or closes. While it is open, the paired list and
    /// battery levels are refreshed more often so newly connected devices appear promptly.
    func setPanelOpen(_ open: Bool) {
        panelOpen = open
        if open { refreshNow() }
    }

    func refreshNow() {
        refresh(full: true)
        refreshConnectionStates()
    }

    // MARK: Polling

    private func tick() {
        guard started else { return }

        let powered = Self.readPower()
        if powered != isPowered {
            isPowered = powered
            if powered {
                refresh(full: true)
            } else {
                devices = []
                lastConnectedKey = ""
            }
            return
        }

        guard powered else { return }

        refreshConnectionStates()

        let interval: TimeInterval = panelOpen ? 3 : 30
        if Date().timeIntervalSince(lastFullRefresh) > interval {
            refresh(full: true)
        }
    }

    /// Cheap refresh through IOBluetooth: adapter state and baseband connection flags. The
    /// system profiler snapshot supplies BLE-only devices and battery levels less often.
    private func refreshConnectionStates() {
        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }

        var byID: [String: IOBluetoothDevice] = [:]
        for device in paired {
            if let address = device.addressString {
                byID[Self.normalize(address)] = device
            }
        }

        for index in devices.indices {
            guard let live = byID[devices[index].id] else { continue }
            let connected = live.isConnected()
            if devices[index].isConnected != connected {
                devices[index].isConnected = connected
            }
        }

        let known = Set(devices.map(\.id))
        for (id, live) in byID where !known.contains(id) {
            if let device = Self.device(from: live) {
                devices.append(device)
            }
        }

        sortDevices()

        let key = connectedDevices.map(\.id).sorted().joined(separator: "|")
        if key != lastConnectedKey {
            lastConnectedKey = key
            // A connection just changed — fetch the system snapshot for its battery.
            if Date().timeIntervalSince(lastFullRefresh) > 1 {
                refresh(full: true)
            }
        }
    }

    // MARK: System profiler snapshot

    private func refresh(full: Bool) {
        guard full else {
            refreshConnectionStates()
            return
        }
        guard !fullRefreshInFlight else { return }
        fullRefreshInFlight = true

        let powered = Self.readPower()
        isPowered = powered
        guard powered else {
            devices = []
            lastConnectedKey = ""
            lastFullRefresh = Date()
            fullRefreshInFlight = false
            return
        }

        let expected = refreshGeneration
        Task {
            let snapshot = await Self.loadSnapshot()
            guard self.started, self.refreshGeneration == expected else { return }
            if let snapshot {
                self.apply(snapshot)
            }
            self.lastFullRefresh = Date()
            self.fullRefreshInFlight = false
        }
    }

    private func apply(_ snapshot: [BluetoothDevice]) {
        var old: [String: BluetoothDevice] = [:]
        for device in devices { old[device.id] = device }

        var merged = snapshot
        for index in merged.indices {
            guard let previous = old[merged[index].id] else { continue }
            // The profiler occasionally drops battery keys while a device is waking up; keep
            // the last known percentages instead of making the ring disappear.
            if merged[index].battery == nil { merged[index].battery = previous.battery }
            if merged[index].batteryLeft == nil { merged[index].batteryLeft = previous.batteryLeft }
            if merged[index].batteryRight == nil { merged[index].batteryRight = previous.batteryRight }
            if merged[index].batteryCase == nil { merged[index].batteryCase = previous.batteryCase }
        }

        // Some BLE peripherals are paired in IOBluetooth but omitted from system_profiler.
        // Keep them so a 30-second snapshot doesn't make them flicker out of the panel.
        let snapshotIDs = Set(merged.map(\.id))
        let live = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        let pairedIDs = Set(live.compactMap { $0.addressString.map(Self.normalize) })
        for device in devices where !snapshotIDs.contains(device.id) && pairedIDs.contains(device.id) {
            merged.append(device)
        }

        devices = merged
        sortDevices()
        lastConnectedKey = connectedDevices.map(\.id).sorted().joined(separator: "|")
    }

    private func sortDevices() {
        devices.sort { lhs, rhs in
            if lhs.isConnected != rhs.isConnected { return lhs.isConnected }
            if lhs.isAudio != rhs.isAudio { return lhs.isAudio }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    // MARK: Actions

    func setPowered(_ on: Bool) {
        guard on != isPowered, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        activity = on ? "Turning Bluetooth on…" : "Turning Bluetooth off…"

        guard let setPower = Self.setPowerFunction else {
            isBusy = false
            activity = nil
            fail("Change Bluetooth power in Bluetooth Settings.")
            openSettings()
            return
        }
        setPower(on ? 1 : 0)

        Task {
            // The controller takes a moment to settle; poll briefly instead of assuming.
            for _ in 0..<8 {
                try? await Task.sleep(for: .milliseconds(250))
                if Self.readPower() == on { break }
            }
            isBusy = false
            activity = nil
            isPowered = Self.readPower()
            if isPowered != on {
                fail(on ? "Couldn’t turn Bluetooth on." : "Couldn’t turn Bluetooth off.")
            }
            refresh(full: true)
        }
    }

    func toggleConnection(_ device: BluetoothDevice) {
        guard !isBusy else { return }
        guard !device.address.isEmpty else {
            fail("\(device.name) can’t be controlled from Talys. Use Bluetooth Settings.")
            return
        }

        let connecting = !device.isConnected
        isBusy = true
        errorMessage = nil
        activity = connecting ? "Connecting \(device.name)…" : "Disconnecting \(device.name)…"

        let address = device.address
        Task {
            let status: Int32 = await Task.detached(priority: .userInitiated) {
                guard let live = IOBluetoothDevice(addressString: address) else {
                    return Int32(kIOReturnError)
                }
                return connecting ? live.openConnection() : live.closeConnection()
            }.value

            try? await Task.sleep(for: .milliseconds(700))
            isBusy = false
            activity = nil
            if status != kIOReturnSuccess {
                fail(connecting
                     ? "Couldn’t connect to \(device.name)."
                     : "Couldn’t disconnect \(device.name).")
            }
            refresh(full: true)
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings") {
            NSWorkspace.shared.open(url)
        }
    }

    private func fail(_ message: String) {
        errorMessage = message
        Task {
            try? await Task.sleep(for: .seconds(5))
            if errorMessage == message { errorMessage = nil }
        }
    }

    // MARK: Helpers

    nonisolated private static func normalize(_ address: String) -> String {
        address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .lowercased()
    }

    nonisolated private static func displayAddress(_ address: String) -> String {
        address
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: ":")
            .uppercased()
    }

    private static func readPower() -> Bool {
        (IOBluetoothHostController.default()?.powerState.rawValue ?? 0) == 1
    }

    /// `IOBluetoothPreferenceSetControllerPowerState` has been present in IOBluetooth for years
    /// (blueutil uses the same entry point) but is not in the public headers. Resolve it lazily
    /// so Talys still builds and shows status if the symbol ever goes away.
    private static let setPowerFunction: (@convention(c) (Int32) -> Void)? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOBluetooth.framework/IOBluetooth", RTLD_NOW),
              let symbol = dlsym(handle, "IOBluetoothPreferenceSetControllerPowerState") else {
            return nil
        }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32) -> Void).self)
    }()

    // MARK: System profiler

    private static func loadSnapshot() async -> [BluetoothDevice]? {
        await Task.detached(priority: .utility) {
            guard let data = runSystemProfiler() else { return nil }
            return parseSnapshot(data)
        }.value
    }

    nonisolated private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return data.isEmpty ? nil : data
        } catch {
            return nil
        }
    }

    nonisolated private static func parseSnapshot(_ data: Data) -> [BluetoothDevice]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = object["SPBluetoothDataType"] as? [[String: Any]],
              let section = sections.first else {
            return nil
        }

        var found: [String: BluetoothDevice] = [:]

        for (key, connected) in [("device_connected", true), ("device_not_connected", false)] {
            guard let list = section[key] as? [[String: Any]] else { continue }
            for entry in list {
                for (rawName, rawValue) in entry {
                    guard let info = rawValue as? [String: Any] else { continue }

                    let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { continue }
                    let rawAddress = (info["device_address"] as? String) ?? ""
                    let address = displayAddress(rawAddress)
                    let id = rawAddress.isEmpty ? "name:\(name.lowercased())" : normalize(rawAddress)
                    let minorType = (info["device_minorType"] as? String) ?? ""

                    let left = percentage(info["device_batteryLevelLeft"])
                    let right = percentage(info["device_batteryLevelRight"])
                    let caseLevel = percentage(info["device_batteryLevelCase"])
                    let main = percentage(info["device_batteryLevel"])
                        ?? percentage(info["device_batteryLevelMain"])
                        ?? percentage(info["device_batteryLevelSingle"])
                        ?? [left, right].compactMap { $0 }.max()

                    let classification = classify(name: name, minorType: minorType)

                    var device = BluetoothDevice(
                        id: id,
                        name: name,
                        address: address,
                        minorType: minorType,
                        isConnected: connected,
                        battery: main,
                        batteryLeft: left,
                        batteryRight: right,
                        batteryCase: caseLevel,
                        isAudio: classification.isAudio,
                        symbol: classification.symbol,
                        category: classification.category
                    )

                    if let existing = found[id] {
                        // A device can appear in both lists; connected wins, and merge battery keys.
                        device.isConnected = device.isConnected || existing.isConnected
                        device.battery = device.battery ?? existing.battery
                        device.batteryLeft = device.batteryLeft ?? existing.batteryLeft
                        device.batteryRight = device.batteryRight ?? existing.batteryRight
                        device.batteryCase = device.batteryCase ?? existing.batteryCase
                    }
                    found[id] = device
                }
            }
        }

        return found.values.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            if $0.isAudio != $1.isAudio { return $0.isAudio }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    nonisolated private static func percentage(_ value: Any?) -> Int? {
        let raw: Int?
        switch value {
        case let number as Int:
            raw = number
        case let number as Double:
            raw = Int(number)
        case let string as String:
            let cleaned = string
                .replacingOccurrences(of: "%", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            raw = Int(cleaned)
        default:
            raw = nil
        }
        guard let raw else { return nil }
        return min(100, max(0, raw))
    }

    // MARK: IOBluetooth fallback

    nonisolated private static func device(from live: IOBluetoothDevice) -> BluetoothDevice? {
        guard let rawAddress = live.addressString else { return nil }
        let address = displayAddress(rawAddress)
        let name = (live.name ?? "Bluetooth device").trimmingCharacters(in: .whitespacesAndNewlines)
        let major = live.deviceClassMajor
        let minor = live.deviceClassMinor

        let typeHint: String
        if major == 4 {
            switch minor {
            case 5: typeHint = "Speaker"
            case 6: typeHint = "Headphones"
            case 1, 2: typeHint = "Headset"
            default: typeHint = "Audio"
            }
        } else if major == 5 {
            switch minor {
            case 16: typeHint = "Keyboard"
            case 32, 48: typeHint = "Mouse"
            default: typeHint = "Peripheral"
            }
        } else {
            typeHint = "Device"
        }

        let classification = classify(name: name, minorType: typeHint)
        return BluetoothDevice(
            id: normalize(rawAddress),
            name: name,
            address: address,
            minorType: typeHint,
            isConnected: live.isConnected(),
            battery: nil,
            batteryLeft: nil,
            batteryRight: nil,
            batteryCase: nil,
            isAudio: major == 4 || classification.isAudio,
            symbol: classification.symbol,
            category: classification.category
        )
    }

    nonisolated private static func classify(name: String, minorType: String)
        -> (symbol: String, category: String, isAudio: Bool) {
        let n = name.lowercased()
        let m = minorType.lowercased()

        if n.contains("airpods") {
            let symbol = n.contains("max") ? "airpodsmax" : (n.contains("pro") ? "airpodspro" : "airpods")
            return (symbol, "Audio", true)
        }
        if m.contains("hearing") || n.contains("hearing aid") {
            return ("ear", "Hearing aid", true)
        }
        if m.contains("headphone") || m.contains("headset") || m.contains("audio")
            || n.contains("headphone") || n.contains("headset") || n.contains("buds") {
            return ("headphones", "Audio", true)
        }
        if m.contains("speaker") || n.contains("speaker") {
            return ("hifispeaker.fill", "Speaker", true)
        }
        if m.contains("keyboard") || n.contains("keyboard")
            || n.contains("keychron") || n.contains("rk61") {
            return ("keyboard.fill", "Keyboard", false)
        }
        if m.contains("mouse") || n.contains("mouse") || n.contains("mx master") {
            return ("computermouse.fill", "Mouse", false)
        }
        if m.contains("trackpad") {
            return ("computermouse.fill", "Trackpad", false)
        }
        if m.contains("game") {
            return ("gamecontroller.fill", "Controller", false)
        }
        return ("dot.radiowaves.left.and.right", "Device", false)
    }
}
