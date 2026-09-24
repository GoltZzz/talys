import Cocoa

/// Swaps the macOS menu bar for the Talys bar while Talys runs.
///
/// This is the system-wide "Automatically hide and show the menu bar" setting (`_HIHideMenuBar` in the global
/// domain); the Talys bar then sits above the menu bar so its hover reveal stays covered. Chosen by `bar.menu_bar`;
/// Talys saves the user's own value before changing it and puts it back on quit.
@MainActor
final class MenuBarAutoHide {
    static let shared = MenuBarAutoHide()

    private static let hideKey = "_HIHideMenuBar" as CFString
    /// Posted by System Settings when the setting changes; running apps and the menu bar re-read it.
    private static let changedNotification = Notification.Name("AppleInterfaceMenuBarHidingChangedNotification")

    /// The user's value before Talys touched it; `absentMarker` when macOS had none (stock default).
    private static let originalKey = "MenuBarAutoHideOriginal"
    private static let absentMarker = "absent"

    private let defaults = UserDefaults.standard

    /// True while Talys is holding the menu bar hidden.
    private(set) var isActive = false

    /// `bar.menu_bar` values.
    enum Mode: String {
        case ask, talys, macos
    }

    /// The prompt's answer when it couldn't be written to config, so it's asked at most once per run.
    private var sessionAnswer: Mode?

    /// Resolves `bar.menu_bar` to `.talys` or `.macos`, asking the user (once) when it's `"ask"` or unrecognised.
    /// The answer is written back to the config so it's remembered.
    func resolve(_ setting: String) -> Mode {
        if let mode = Mode(rawValue: setting.lowercased()), mode != .ask { return mode }
        if Mode(rawValue: setting.lowercased()) == nil {
            print("[MenuBar] Unknown menu_bar value \"\(setting)\"; expected \"ask\", \"talys\" or \"macos\".")
        }
        if let answer = sessionAnswer { return answer }
        let answer: Mode = askUser() ? .talys : .macos
        sessionAnswer = answer
        ConfigManager.persistMenuBar(answer.rawValue)
        return answer
    }

    /// Brings the system setting in line with whether the Talys bar is showing, at launch and on config reload.
    func apply(enabled: Bool) {
        enabled ? take() : restore()
    }

    /// Puts the user's own setting back. Works from the saved original alone, so it also repairs a run
    /// that crashed while holding the menu bar hidden. A setting changed in System Settings while Talys ran
    /// is the user's newer choice, so it's kept instead.
    func restore() {
        isActive = false
        guard let original = defaults.object(forKey: Self.originalKey) else { return }
        if readCurrent() == true {
            write((original as? Bool).map { $0 as CFBoolean as CFPropertyList })
            print("[MenuBar] Restored the macOS menu bar setting.")
        } else {
            print("[MenuBar] The menu bar setting was changed outside Talys; leaving it as is.")
        }
        defaults.removeObject(forKey: Self.originalKey)
    }

    // MARK: - Private

    private func take() {
        guard !isActive else { return }
        // A leftover original means the last run didn't get to restore it (crash, force quit); keep that one.
        if defaults.object(forKey: Self.originalKey) == nil {
            defaults.set(readCurrent().map { $0 as Any } ?? Self.absentMarker, forKey: Self.originalKey)
        }
        write(kCFBooleanTrue)
        isActive = true
        print("[MenuBar] Auto-hiding the macOS menu bar.")
    }

    private func readCurrent() -> Bool? {
        CFPreferencesCopyValue(Self.hideKey, kCFPreferencesAnyApplication,
                               kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
    }

    /// Writes the setting (nil removes it) and tells the system to pick it up without a logout.
    private func write(_ value: CFPropertyList?) {
        CFPreferencesSetValue(Self.hideKey, value, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            Self.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }

    private func askUser() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Use the Talys bar instead of the macOS menu bar?"
        alert.informativeText = """
            While Talys runs, it sets the macOS menu bar to hide automatically and covers it with the Talys bar. \
            App menus (File, Edit, Help…) are then only reachable by their keyboard shortcuts.

            Your menu bar setting goes back to how it was when you quit Talys. You can change this later from the launcher or with menu_bar in the config.
            """
        alert.addButton(withTitle: "Use Talys Bar")
        alert.addButton(withTitle: "Keep macOS Menu Bar")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
