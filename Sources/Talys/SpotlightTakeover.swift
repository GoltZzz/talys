import Cocoa

/// Hands Cmd+Space from Spotlight to the Talys launcher.
///
/// Spotlight's shortcut is entry 64 of the system's symbolic hotkeys (see `SymbolicHotKeys`).
/// The user is asked once; after accepting, Talys disables the shortcut on every launch and restores it on quit.
@MainActor
final class SpotlightTakeover {
    static let shared = SpotlightTakeover()

    private enum Choice: String {
        case accepted, declined
    }

    private static let spotlightID = "64"

    private static let choiceKey = "SpotlightTakeoverChoice"
    /// Spotlight's entry as it was before Talys touched it; `absentMarker` when macOS had no entry (stock default).
    private static let originalKey = "SpotlightTakeoverOriginal"

    /// Cmd+Space is Spotlight's stock binding (keycode 49, command mask 1 << 20).
    private static let stockEntry: [String: Any] = [
        "enabled": true,
        "value": ["parameters": [32, 49, 1_048_576], "type": "standard"] as [String: Any],
    ]

    private let defaults = UserDefaults.standard

    /// True while Talys holds Cmd+Space, so the launcher should be bound to it.
    private(set) var isActive = false

    private var choice: Choice? {
        get { defaults.string(forKey: Self.choiceKey).flatMap(Choice.init) }
        set { defaults.set(newValue?.rawValue, forKey: Self.choiceKey) }
    }

    var isAccepted: Bool { choice == .accepted }

    /// Called at launch: asks once, then takes the shortcut over if the user has accepted.
    func prepareOnLaunch() {
        if choice == nil {
            choice = askUser() ? .accepted : .declined
        }
        if choice == .accepted {
            take()
        }
    }

    /// Launcher command: stop taking Cmd+Space over, now and on future launches.
    func release() {
        choice = .declined
        restore()
    }

    /// Launcher command: start taking Cmd+Space over, now and on future launches.
    func enable() {
        choice = .accepted
        take()
    }

    /// Gives Spotlight its shortcut back without changing the saved choice, so the next launch takes it again.
    /// Works from the saved original alone, so it also repairs a run that crashed while holding the shortcut.
    func restore() {
        isActive = false
        guard let original = defaults.object(forKey: Self.originalKey) else { return }

        // An absent original is written back as the explicit stock entry: just removing the key leaves the
        // hotkey server with the disabled state it last saw, so Cmd+Space stays dead until a logout.
        var hotKeys = SymbolicHotKeys.read()
        hotKeys[Self.spotlightID] = original as? [String: Any] ?? Self.stockEntry
        if SymbolicHotKeys.write(hotKeys, checking: [Self.spotlightID]) && SymbolicHotKeys.activate() {
            defaults.removeObject(forKey: Self.originalKey)
            print("[Spotlight] Restored Spotlight's Cmd+Space shortcut.")
        } else {
            print("[Spotlight] Could not restore Spotlight's shortcut; re-enable it in System Settings → Keyboard → Keyboard Shortcuts → Spotlight.")
        }
    }

    /// Rebinds the launcher from its default key to Cmd+Space while the takeover is active.
    /// A `launcher` key set explicitly in the user's config is left alone.
    func adjustBindings(_ bindings: inout [KeyBinding: KeyAction], config: TalysConfig) {
        guard isActive, config.keybindings["launcher"] == nil else { return }
        for (binding, action) in bindings {
            if case .toggleLauncher = action { bindings.removeValue(forKey: binding) }
        }
        let cmdSpace = KeyBinding(keyCode: 49, cmd: true)
        if let previous = bindings[cmdSpace] {
            print("[Spotlight] Cmd+Space was bound to \(previous); using it for the launcher.")
        }
        bindings[cmdSpace] = .toggleLauncher
    }

    // MARK: - Private

    private func take() {
        guard !isActive else { return }
        var hotKeys = SymbolicHotKeys.read()
        let current = hotKeys[Self.spotlightID] as? [String: Any]

        // A leftover original means the last run didn't get to restore it (crash, force quit); keep that one.
        if defaults.object(forKey: Self.originalKey) == nil {
            defaults.set(current ?? SymbolicHotKeys.absentMarker, forKey: Self.originalKey)
        }

        var entry = current ?? Self.stockEntry
        entry["enabled"] = false
        hotKeys[Self.spotlightID] = entry

        if SymbolicHotKeys.write(hotKeys, checking: [Self.spotlightID]) && SymbolicHotKeys.activate() {
            isActive = true
            print("[Spotlight] Disabled Spotlight's Cmd+Space; the launcher now owns it.")
        } else {
            print("[Spotlight] Could not disable Spotlight's shortcut automatically.")
            showManualFallback()
        }
    }

    private func askUser() -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Use Cmd+Space for the Talys launcher?"
        alert.informativeText = "Talys will turn off Spotlight's Cmd+Space shortcut while it runs and give it back when Talys quits. You can change this later from the launcher."
        alert.addButton(withTitle: "Use Cmd+Space")
        alert.addButton(withTitle: "Keep Spotlight")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showManualFallback() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Turn off Spotlight's shortcut"
        alert.informativeText = "Talys couldn't change it automatically. In Keyboard Shortcuts → Spotlight, uncheck \"Show Spotlight search\". The launcher stays on its usual key until then."
        alert.addButton(withTitle: "Open Keyboard Shortcuts")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(SymbolicHotKeys.shortcutsSettingsURL)
        }
    }
}
