import Cocoa

/// Keeps Talys on one macOS Space, its "home".
///
/// Talys workspaces replace macOS Spaces: the Accessibility API only sees windows on the current Space, so on any
/// other one (including a native-fullscreen app's Space) Talys would mistake its windows for closed ones. It pauses
/// there instead and resumes on the way back. Space IDs come from SkyLight's private `CGS*` calls, looked up at
/// runtime so a future macOS without them just leaves Talys un-paused.
@MainActor
final class SpaceMonitor {
    static let shared = SpaceMonitor()

    private typealias ConnectionFn = @convention(c) () -> Int32
    private typealias ActiveSpaceFn = @convention(c) (Int32) -> UInt64
    private typealias CopySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?

    private struct SkyLight {
        let connection: Int32
        let activeSpace: ActiveSpaceFn
        let copySpaces: CopySpacesFn
    }

    /// One display's desktops; fullscreen-app Spaces are left out.
    private struct Display {
        let current: UInt64
        let desktops: [UInt64]

        var home: UInt64? { desktops.contains(current) ? current : desktops.first }
    }

    private static let noticeShownKey = "ExtraSpacesNoticeShown"
    private static let missionControlURL = URL(fileURLWithPath: "/System/Applications/Mission Control.app")

    private let skyLight: SkyLight? = {
        let handle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let connection = dlsym(handle, "CGSMainConnectionID"),
              let activeSpace = dlsym(handle, "CGSGetActiveSpace"),
              let copySpaces = dlsym(handle, "CGSCopyManagedDisplaySpaces") else { return nil }
        return SkyLight(
            connection: unsafeBitCast(connection, to: ConnectionFn.self)(),
            activeSpace: unsafeBitCast(activeSpace, to: ActiveSpaceFn.self),
            copySpaces: unsafeBitCast(copySpaces, to: CopySpacesFn.self)
        )
    }()

    /// The home desktop of each display, taken from where Talys launched.
    private var home: Set<UInt64> = []
    private var token: NSObjectProtocol?

    private(set) var isAway = false
    var onAwayChanged: ((Bool) -> Void)?

    func start() {
        guard skyLight != nil else {
            print("[Spaces] Space info unavailable on this macOS; Talys won't pause on other desktops.")
            return
        }
        home = Set(displays().compactMap(\.home))
        token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { SpaceMonitor.shared.update() }
        }
        update()
    }

    func stop() {
        if let token { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        token = nil
    }

    /// Asks once, ever, when there's more than one desktop, pointing at Mission Control to remove the extras.
    func noticeExtraSpacesIfNeeded() {
        let extra = displays().reduce(0) { $0 + max(0, $1.desktops.count - 1) }
        guard extra > 0, !UserDefaults.standard.bool(forKey: Self.noticeShownKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.noticeShownKey)

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Talys works best on a single desktop"
        alert.informativeText = "You have \(extra) extra macOS \(extra == 1 ? "desktop" : "desktops"). Talys workspaces replace them, and Talys pauses whenever you leave this desktop.\n\nTo remove the extras, open Mission Control, move the pointer to the desktop strip at the top, and click ✕ on each one. Their windows move to a remaining desktop."
        alert.addButton(withTitle: "Open Mission Control")
        alert.addButton(withTitle: "Keep Them")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Self.missionControlURL)
        }
    }

    // MARK: - Private

    private func update() {
        guard let skyLight else { return }
        let displays = displays()

        // A removed home desktop hands over to wherever that display is now.
        home.formIntersection(displays.flatMap(\.desktops))
        for display in displays where !display.desktops.contains(where: home.contains) {
            if let fallback = display.home { home.insert(fallback) }
        }

        let away = !home.contains(skyLight.activeSpace(skyLight.connection))
        guard away != isAway else { return }
        isAway = away
        print("[Spaces] \(away ? "Left" : "Back on") the home desktop.")
        onAwayChanged?(away)
    }

    private func displays() -> [Display] {
        guard let skyLight, let raw = skyLight.copySpaces(skyLight.connection)?.takeRetainedValue() as? [[String: Any]] else { return [] }
        return raw.compactMap { display in
            guard let current = (display["Current Space"] as? [String: Any]).flatMap(Self.spaceID),
                  let spaces = display["Spaces"] as? [[String: Any]] else { return nil }
            // type 0 is a regular desktop; 4 is a native-fullscreen app.
            let desktops = spaces.filter { ($0["type"] as? Int) == 0 }.compactMap(Self.spaceID)
            return Display(current: current, desktops: desktops)
        }
    }

    private static func spaceID(_ space: [String: Any]) -> UInt64? {
        ((space["id64"] ?? space["ManagedSpaceID"]) as? NSNumber)?.uint64Value
    }
}
