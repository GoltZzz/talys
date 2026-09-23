import Cocoa

/// Reads and writes the system keyboard shortcuts in `com.apple.symbolichotkeys`.
///
/// macOS has no public API for these: each shortcut is an entry of `AppleSymbolicHotKeys` keyed by a numeric ID,
/// and `activateSettings -u` makes the system pick up an edit without a logout.
enum SymbolicHotKeys {
    private static var domain: CFString { "com.apple.symbolichotkeys" as CFString }
    private static var hotKeysKey: CFString { "AppleSymbolicHotKeys" as CFString }
    private static let activateSettings = "/System/Library/PrivateFrameworks/SystemAdministration.framework/Resources/activateSettings"

    static let shortcutsSettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")!

    /// Stored in place of an entry that macOS didn't have, so restoring removes it again.
    static let absentMarker = "absent"

    static func read() -> [String: Any] {
        CFPreferencesCopyValue(hotKeysKey, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String: Any] ?? [:]
    }

    /// Writes and reads back, so a silently rejected write counts as a failure.
    /// `checking`: the entries whose `enabled` flag must have stuck.
    static func write(_ hotKeys: [String: Any], checking ids: [String]) -> Bool {
        CFPreferencesSetValue(hotKeysKey, hotKeys as CFDictionary, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        guard CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return false }
        let written = read()
        return ids.allSatisfy { id in
            let got = written[id] as? [String: Any]
            let wanted = hotKeys[id] as? [String: Any]
            return (got?["enabled"] as? Bool) == (wanted?["enabled"] as? Bool)
        }
    }

    /// Tells the system to reload symbolic hotkeys without a logout.
    static func activate() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: activateSettings) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: activateSettings)
        process.arguments = ["-u"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// The key combination an entry triggers on, in Talys terms; nil for disabled or unparseable entries.
    /// `parameters` is `[character, keycode, modifier mask]`.
    static func binding(of entry: [String: Any]) -> KeyBinding? {
        guard entry["enabled"] as? Bool == true,
              let value = entry["value"] as? [String: Any],
              let params = value["parameters"] as? [Int], params.count == 3 else { return nil }
        let mask = CGEventFlags(rawValue: UInt64(params[2]))
        return KeyBinding(
            keyCode: UInt16(truncatingIfNeeded: params[1]),
            ctrl: mask.contains(.maskControl),
            shift: mask.contains(.maskShift),
            cmd: mask.contains(.maskCommand),
            alt: mask.contains(.maskAlternate)
        )
    }
}
