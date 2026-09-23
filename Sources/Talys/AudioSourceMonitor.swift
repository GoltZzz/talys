import Cocoa
import CoreAudio
import Observation

/// An app (or command-line process) that is currently sending audio to an output device.
struct AudioSource: Identifiable, Equatable {
    let id: pid_t
    let name: String
    let icon: NSImage?

    static func == (a: AudioSource, b: AudioSource) -> Bool { a.id == b.id && a.name == b.name }
}

/// Lists processes playing audio via CoreAudio's process objects (macOS 14.2+). Polls only while the panel is open.
@Observable
@MainActor
final class AudioSourceMonitor {
    static let shared = AudioSourceMonitor()

    private(set) var sources: [AudioSource] = []
    @ObservationIgnored private var timer: Timer?

    private init() {}

    func start() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in AudioSourceMonitor.shared.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let own = ProcessInfo.processInfo.processIdentifier
        let apps = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        var seen = Set<pid_t>()
        var result: [AudioSource] = []

        for process in Self.processObjects() {
            guard Self.isRunningOutput(process),
                  let pid = Self.pid(of: process), pid != own else { continue }
            let bundleID = Self.bundleID(of: process)

            if let app = Self.owningApp(pid: pid, bundleID: bundleID, among: apps) {
                guard seen.insert(app.processIdentifier).inserted else { continue }
                result.append(AudioSource(id: app.processIdentifier, name: app.localizedName ?? "App", icon: app.icon))
            } else {
                // Unbundled Apple helpers are system noise; command-line players (mpv, cliamp…) are not.
                if bundleID?.hasPrefix("com.apple.") == true { continue }
                guard seen.insert(pid).inserted, let name = Self.processName(pid) else { continue }
                result.append(AudioSource(id: pid, name: name, icon: nil))
            }
        }
        result.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if result != sources { sources = result }
    }

    /// Maps audio helper processes to the app the user recognizes (Chrome Helper → Chrome, WebKit → Safari).
    private static func owningApp(pid: pid_t, bundleID: String?, among apps: [NSRunningApplication]) -> NSRunningApplication? {
        if let app = apps.first(where: { $0.processIdentifier == pid }) { return app }
        guard let bundleID else { return nil }
        if bundleID.hasPrefix("com.apple.WebKit") {
            return apps.first { $0.bundleIdentifier == "com.apple.Safari" }
        }
        return apps
            .filter { app in app.bundleIdentifier.map { bundleID.hasPrefix($0 + ".") } ?? false }
            .max { ($0.bundleIdentifier?.count ?? 0) < ($1.bundleIdentifier?.count ?? 0) }
    }

    // MARK: - CoreAudio process objects

    private static func processObjects() -> [AudioObjectID] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioController.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func isRunningOutput(_ process: AudioObjectID) -> Bool {
        var address = AudioController.address(kAudioProcessPropertyIsRunningOutput)
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &running) == noErr && running != 0
    }

    private static func pid(of process: AudioObjectID) -> pid_t? {
        var address = AudioController.address(kAudioProcessPropertyPID)
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        return AudioObjectGetPropertyData(process, &address, 0, nil, &size, &pid) == noErr ? pid : nil
    }

    private static func bundleID(of process: AudioObjectID) -> String? {
        var address = AudioController.address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(process, &address, 0, nil, &size, &value) == noErr,
              let id = value?.takeRetainedValue() as String?, !id.isEmpty else { return nil }
        return id
    }

    private static func processName(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
