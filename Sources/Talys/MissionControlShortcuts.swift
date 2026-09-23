import Cocoa

/// Turns off the Mission Control shortcuts that use the same keys as a Talys binding, while Talys runs.
///
/// Only clashing shortcuts are touched, and only after the user agrees once. Each one's original entry is saved
/// before it's disabled and written back on quit; a leftover saved entry (crash, force quit) is kept and restored
/// on the next sync instead of being overwritten.
@MainActor
final class MissionControlShortcuts {
    static let shared = MissionControlShortcuts()

    private enum Choice: String {
        case accepted, declined
    }

    /// Symbolic hotkey IDs and their names in System Settings → Keyboard Shortcuts → Mission Control.
    private static let shortcuts: [(id: String, name: String)] = [
        ("32", "Mission Control"),
        ("33", "Application windows"),
        ("79", "Move left a space"),
        ("80", "Move left a space"),
        ("81", "Move right a space"),
        ("82", "Move right a space"),
    ] + (1...9).map { (String(117 + $0), "Switch to Desktop \($0)") }

    /// What macOS uses when it has no entry: Ctrl+arrows (fn is part of the arrow-key mask) are on by default,
    /// "Switch to Desktop N" is off, so it has no stock entry here.
    private static let stockEntries: [String: [String: Any]] = [
        "32": stock(keyCode: 126, mask: 8_650_752),
        "33": stock(keyCode: 125, mask: 8_650_752),
        "79": stock(keyCode: 123, mask: 8_650_752),
        "80": stock(keyCode: 123, mask: 8_781_824),
        "81": stock(keyCode: 124, mask: 8_650_752),
        "82": stock(keyCode: 124, mask: 8_781_824),
    ]

    private static func stock(keyCode: Int, mask: Int) -> [String: Any] {
        ["enabled": true, "value": ["parameters": [65535, keyCode, mask], "type": "standard"] as [String: Any]]
    }

    private static let choiceKey = "MissionControlShortcutsChoice"
    /// Original entries of the shortcuts Talys has disabled, keyed by ID; `absentMarker` when macOS had none.
    private static let originalsKey = "MissionControlShortcutsOriginals"

    private let defaults = UserDefaults.standard
    private var bindings: [KeyBinding: KeyAction] = [:]

    private var choice: Choice? {
        get { defaults.string(forKey: Self.choiceKey).flatMap(Choice.init) }
        set { defaults.set(newValue?.rawValue, forKey: Self.choiceKey) }
    }

    private var originals: [String: Any] {
        get { defaults.dictionary(forKey: Self.originalsKey) ?? [:] }
        set { defaults.set(newValue.isEmpty ? nil : newValue, forKey: Self.originalsKey) }
    }

    var isAccepted: Bool { choice == .accepted }

    /// True when some Mission Control shortcut shares keys with the current Talys bindings.
    var hasClashes: Bool { !clashes().isEmpty }

    /// Called whenever the Talys bindings change: asks once when something clashes, then disables exactly
    /// the clashing shortcuts (if accepted) and gives back any that no longer clash.
    func sync(with bindings: [KeyBinding: KeyAction]) {
        self.bindings = bindings
        let clashing = clashes()
        if choice == nil, !clashing.isEmpty {
            choice = askUser(names: clashing.map(\.name)) ? .accepted : .declined
        }
        if choice == .accepted {
            apply(disabling: Set(clashing.map(\.id)))
        } else {
            apply(disabling: [])
            if !clashing.isEmpty {
                print("[MissionControl] These macOS shortcuts share keys with Talys and may win: \(Self.describe(clashing)).")
            }
        }
    }

    /// Gives every shortcut back without changing the saved choice, so the next launch takes them again.
    func restore() {
        apply(disabling: [])
    }

    /// Launcher command: stop managing the shortcuts, now and on future launches.
    func release() {
        choice = .declined
        restore()
    }

    /// Launcher command: disable clashing shortcuts, now and on future launches.
    func enable() {
        choice = .accepted
        sync(with: bindings)
    }

    // MARK: - Private

    /// Shortcuts whose keys (as they were before Talys touched them) match a Talys binding.
    private func clashes() -> [(id: String, name: String)] {
        let current = SymbolicHotKeys.read()
        let saved = originals
        return Self.shortcuts.filter { shortcut in
            let entry: [String: Any]?
            if let original = saved[shortcut.id] {
                entry = original as? [String: Any] ?? Self.stockEntries[shortcut.id]
            } else {
                entry = current[shortcut.id] as? [String: Any] ?? Self.stockEntries[shortcut.id]
            }
            guard let entry, let binding = SymbolicHotKeys.binding(of: entry) else { return false }
            return bindings[binding] != nil
        }
    }

    /// Makes `wanted` the exact set of shortcuts Talys holds disabled, restoring the rest from their saved originals.
    private func apply(disabling wanted: Set<String>) {
        var hotKeys = SymbolicHotKeys.read()
        var saved = originals
        var touched: [String] = []

        let released = saved.keys.filter { !wanted.contains($0) }
        for id in released {
            // Absent originals go back as the explicit stock entry where there is one; removing the key alone
            // doesn't make the hotkey server re-enable a shortcut it last saw disabled.
            if let entry = saved[id] as? [String: Any] ?? Self.stockEntries[id] {
                hotKeys[id] = entry
            } else {
                hotKeys.removeValue(forKey: id)
            }
            touched.append(id)
        }

        for id in wanted {
            let current = hotKeys[id] as? [String: Any]
            if saved[id] == nil {
                saved[id] = current ?? SymbolicHotKeys.absentMarker
            }
            guard current?["enabled"] as? Bool != false else { continue }
            var entry = current ?? Self.stockEntries[id] ?? [:]
            entry["enabled"] = false
            hotKeys[id] = entry
            touched.append(id)
        }

        guard !touched.isEmpty else { return }
        // Save originals before writing, so a crash mid-way still knows what to put back.
        originals = saved

        if SymbolicHotKeys.write(hotKeys, checking: touched) && SymbolicHotKeys.activate() {
            for id in released { saved.removeValue(forKey: id) }
            originals = saved
            let names = Self.shortcuts.filter { touched.contains($0.id) }
            print("[MissionControl] \(wanted.isEmpty ? "Restored" : "Updated") shortcuts: \(Self.describe(names)).")
        } else {
            print("[MissionControl] Could not update Mission Control shortcuts; change them in System Settings → Keyboard → Keyboard Shortcuts → Mission Control.")
        }
    }

    private static func describe(_ shortcuts: [(id: String, name: String)]) -> String {
        var seen = Set<String>()
        return shortcuts.map(\.name).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    private func askUser(names: [String]) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        var seen = Set<String>()
        let list = names.filter { seen.insert($0).inserted }.map { "• \($0)" }.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Turn off Mission Control shortcuts that clash with Talys?"
        alert.informativeText = "These macOS shortcuts use the same keys as your Talys bindings:\n\n\(list)\n\nTalys will turn them off while it runs and give them back when Talys quits. You can change this later from the launcher."
        alert.addButton(withTitle: "Turn Off While Running")
        alert.addButton(withTitle: "Leave Them")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
