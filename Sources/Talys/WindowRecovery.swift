import Cocoa
@preconcurrency import ApplicationServices

/// Written before hiding a window. PID + launch time prevents matching a reused PID;
/// WindowServer ID distinguishes windows even when titles change or are duplicated.
struct RecoveryEntry: Codable, Equatable {
    let pid: Int32
    let launched: Date
    let windowID: UInt32
    let frame: CGRect
    // Absent in older journals, which always used NSRunningApplication.launchDate.
    var usesProcessStartTime: Bool? = nil

    func matchesProcess(pid: Int32, launched: Date) -> Bool {
        self.pid == pid && self.launched == launched
    }

    func timestamp(launchDate: Date?, processStartTime: @autoclosure () -> Date?) -> Date? {
        usesProcessStartTime == true ? processStartTime() : launchDate
    }
}

enum RecoveryProcessIdentity {
    /// Helper/unbundled processes may have no AppKit launchDate. The kernel still
    /// supplies their start time, preserving protection against PID reuse.
    static func startTime(pid: pid_t) -> Date? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_start_tvsec > 0 else { return nil }
        return Date(timeIntervalSince1970: Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000)
    }

    static func resolve(launchDate: Date?, processStartTime: @autoclosure () -> Date?) -> (date: Date, usesProcessStartTime: Bool)? {
        if let launchDate { return (launchDate, false) }
        return processStartTime().map { ($0, true) }
    }
}

enum RecoveryOutcome { case recovered, gone, pending }

struct RecoveryJournal {
    let url: URL
    private(set) var entries: [RecoveryEntry]

    init(url: URL) throws {
        self.url = url
        entries = FileManager.default.fileExists(atPath: url.path)
            ? try JSONDecoder().decode([RecoveryEntry].self, from: Data(contentsOf: url)) : []
    }

    mutating func replace(_ entries: [RecoveryEntry]) throws {
        let data = try JSONEncoder().encode(entries)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        self.entries = entries
    }

    /// Commit only confirmed recovery/death. A write failure preserves the old journal.
    mutating func recover(using restore: (RecoveryEntry) -> RecoveryOutcome) throws -> Int {
        var remaining: [RecoveryEntry] = []
        var recovered = 0
        for entry in entries {
            switch restore(entry) {
            case .recovered: recovered += 1
            case .gone: break
            case .pending: remaining.append(entry)
            }
        }
        if remaining != entries { try replace(remaining) }
        return recovered
    }

    static func fitted(_ frame: CGRect, in bounds: CGRect) -> CGRect {
        let width = min(max(1, frame.width), bounds.width)
        let height = min(max(1, frame.height), bounds.height)
        return CGRect(x: min(max(frame.minX, bounds.minX), bounds.maxX - width),
                      y: min(max(frame.minY, bounds.minY), bounds.maxY - height), width: width, height: height)
    }

    /// An app may reject shrinking below its minimum. Keep its title bar reachable even then.
    static func reachable(_ frame: CGRect, in bounds: CGRect) -> Bool {
        frame.width > 0 && frame.height > 0 && frame.minY >= bounds.minY - 2
            && frame.minY + min(22, frame.height) <= bounds.maxY + 2
            && frame.minX >= bounds.minX - 2
            && frame.minX + min(100, frame.width) <= bounds.maxX + 2
    }
}

@MainActor
final class WindowRecovery {
    static let shared = WindowRecovery()
    static let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/talys")
    private var journal: RecoveryJournal?
    private var lockFD: Int32 = -1
    private(set) var loadFailed = false
    var hasPending: Bool { loadFailed || !(journal?.entries.isEmpty ?? true) }
    var pendingCount: Int { journal?.entries.count ?? 0 }

    private init() {}

    private func loadJournal() {
        do { journal = try RecoveryJournal(url: Self.directory.appendingPathComponent("window-recovery.json")) }
        catch {
            loadFailed = true
            print("[Recovery] Cannot read recovery journal: \(error). Tiling stays disabled; journal preserved.")
        }
    }

    /// The app and rescue command must never manipulate the desktop/journal concurrently.
    func acquireLock() -> Bool {
        do { try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true) }
        catch { print("[Recovery] Cannot create recovery directory: \(error)"); return false }
        lockFD = open(Self.directory.appendingPathComponent("window-recovery.lock").path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard lockFD >= 0, flock(lockFD, LOCK_EX | LOCK_NB) == 0 else {
            if lockFD >= 0 { close(lockFD); lockFD = -1 }
            print("[Recovery] Another Talys instance is running. Quit it before running recovery.")
            return false
        }
        // Read only after acquiring ownership; another instance may have just exited.
        loadJournal()
        return true
    }

    private typealias WindowIDFunction = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError
    private static let windowIDFunction: WindowIDFunction? = {
        guard let handle = dlopen(nil, RTLD_LAZY), let symbol = dlsym(handle, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: WindowIDFunction.self)
    }()

    static var supportsWindowIdentity: Bool { windowIDFunction != nil }

    private func currentTimestamp(for entry: RecoveryEntry) -> Date? {
        entry.timestamp(launchDate: NSRunningApplication(processIdentifier: entry.pid)?.launchDate,
                        processStartTime: RecoveryProcessIdentity.startTime(pid: entry.pid))
    }

    private func isSameWindow(_ saved: RecoveryEntry, _ current: RecoveryEntry) -> Bool {
        saved.pid == current.pid && saved.windowID == current.windowID
            && currentTimestamp(for: saved) == saved.launched
    }

    private func identity(_ element: AXUIElement, pid: pid_t, frame: CGRect, diagnose: Bool = false) -> RecoveryEntry? {
        func failed(_ reason: String) -> RecoveryEntry? {
            if diagnose {
                let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "Unknown app"
                print("[Recovery] Cannot identify \(name) (PID \(pid)): \(reason); leaving it visible.")
            }
            return nil
        }
        guard let process = RecoveryProcessIdentity.resolve(
            launchDate: NSRunningApplication(processIdentifier: pid)?.launchDate,
            processStartTime: RecoveryProcessIdentity.startTime(pid: pid)) else {
            return failed("both app launch date and kernel process start time are unavailable")
        }
        guard let function = Self.windowIDFunction else { return failed("window identity API is unavailable") }
        var id: CGWindowID = 0
        let error = function(element, &id)
        guard error == .success, id != 0 else { return failed("window ID lookup failed (AX error \(error.rawValue), ID \(id))") }
        return RecoveryEntry(pid: pid, launched: process.date, windowID: id, frame: frame,
                             usesProcessStartTime: process.usesProcessStartTime)
    }

    /// Fail closed: without a durable recovery record, leave the window visible.
    func prepare(_ element: AXUIElement, pid: pid_t, frame: CGRect) -> Bool {
        guard var journal else {
            print("[Recovery] Recovery journal unavailable (PID \(pid)); leaving it visible.")
            return false
        }
        guard frame.width > 0, frame.height > 0,
              [frame.minX, frame.minY, frame.width, frame.height].allSatisfy({ $0.isFinite }) else {
            print("[Recovery] Invalid recovery frame (PID \(pid)); leaving it visible.")
            return false
        }
        guard let entry = identity(element, pid: pid, frame: frame, diagnose: true) else { return false }
        if journal.entries.contains(where: { isSameWindow($0, entry) }) { return true }
        do {
            try journal.replace(journal.entries + [entry])
            self.journal = journal
            return true
        } catch { print("[Recovery] Cannot save recovery record: \(error)"); return false }
    }

    func acknowledgeVisible(_ element: AXUIElement, pid: pid_t, bounds: CGRect) {
        guard let frame = AccessibilityHelper.getFrame(for: element), RecoveryJournal.reachable(frame, in: bounds),
              let entry = identity(element, pid: pid, frame: frame), var journal else { return }
        let remaining = journal.entries.filter { !isSameWindow($0, entry) }
        guard remaining.count != journal.entries.count else { return }
        do { try journal.replace(remaining); self.journal = journal }
        catch { print("[Recovery] Cannot clear recovered record: \(error)") }
    }

    /// Enumerates AX windows directly, including minimized windows. Missing windows of live
    /// processes remain pending: they may belong to an unavailable macOS Space.
    @discardableResult
    func recover(bounds: CGRect) -> Int {
        guard var journal else { return 0 }
        var recovered = 0
        do {
            recovered = try journal.recover { entry in
                guard let app = NSRunningApplication(processIdentifier: entry.pid), !app.isTerminated else { return .gone }
                guard let launched = currentTimestamp(for: entry) else { return .pending }
                guard entry.matchesProcess(pid: app.processIdentifier, launched: launched) else { return .gone }
                let application = AXUIElementCreateApplication(entry.pid)
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(application, kAXWindowsAttribute as CFString, &value) == .success,
                      let windows = value as? [AXUIElement],
                      let element = windows.first(where: { identity($0, pid: entry.pid, frame: entry.frame)?.windowID == entry.windowID }) else { return .pending }
                let target = RecoveryJournal.fitted(entry.frame, in: bounds)
                AccessibilityHelper.setFrame(for: element, frame: target)
                if let actual = AccessibilityHelper.getFrame(for: element) {
                    AccessibilityHelper.setPosition(for: element, to: RecoveryJournal.fitted(CGRect(origin: target.origin, size: actual.size), in: bounds).origin)
                }
                guard let actual = AccessibilityHelper.getFrame(for: element), RecoveryJournal.reachable(actual, in: bounds) else { return .pending }
                let expected = RecoveryJournal.fitted(CGRect(origin: target.origin, size: actual.size), in: bounds)
                guard abs(actual.minX - expected.minX) <= 2, abs(actual.minY - expected.minY) <= 2 else { return .pending }
                return .recovered
            }
            self.journal = journal
        } catch { print("[Recovery] Cannot save recovery results: \(error)") }
        if pendingCount > 0 { print("[Recovery] \(pendingCount) window(s) still pending. Return to their macOS desktop and retry Reveal All Windows or --recover-windows.") }
        return recovered
    }
}
