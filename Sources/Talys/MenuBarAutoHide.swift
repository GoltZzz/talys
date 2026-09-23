import Cocoa

/// Auto-hides the macOS menu bar while Talys runs, so the Talys bar owns the top of the screen.
///
/// This is the system-wide "Automatically hide and show the menu bar" setting (`_HIHideMenuBar` in the global
/// domain). Talys saves the user's own value before changing it and puts it back on quit.
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

    /// Brings the system setting in line with `hide_macos_menu_bar`, at launch and on config reload.
    func apply(enabled: Bool) {
        enabled ? take() : restore()
    }

    /// Puts the user's own setting back. Works from the saved original alone, so it also repairs a run
    /// that crashed while holding the menu bar hidden.
    func restore() {
        isActive = false
        guard let original = defaults.object(forKey: Self.originalKey) else { return }
        write((original as? Bool).map { $0 as CFBoolean as CFPropertyList })
        defaults.removeObject(forKey: Self.originalKey)
        print("[MenuBar] Restored the macOS menu bar setting.")
    }

    // MARK: - Private

    private func take() {
        guard !isActive else { return }
        // A leftover original means the last run didn't get to restore it (crash, force quit); keep that one.
        if defaults.object(forKey: Self.originalKey) == nil {
            let current = CFPreferencesCopyValue(Self.hideKey, kCFPreferencesAnyApplication,
                                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? Bool
            defaults.set(current.map { $0 as Any } ?? Self.absentMarker, forKey: Self.originalKey)
        }
        write(kCFBooleanTrue)
        isActive = true
        print("[MenuBar] Auto-hiding the macOS menu bar.")
    }

    /// Writes the setting (nil removes it) and tells the system to pick it up without a logout.
    private func write(_ value: CFPropertyList?) {
        CFPreferencesSetValue(Self.hideKey, value, kCFPreferencesAnyApplication,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        DistributedNotificationCenter.default().postNotificationName(
            Self.changedNotification, object: nil, userInfo: nil, deliverImmediately: true)
    }
}
