import Foundation
import CTalysEngine

/// What a window wants from the Smart layout. Well-known apps come with built-in preferences; matching
/// `[[window_rules]]` override them field by field, the first rule to set a field winning.
struct WindowPrefs: Equatable {
    /// Preferred width ÷ height; 0 = none.
    var aspect: Double = 0
    /// Width past which the window just wastes space; 0 = none.
    var maxWidth: Double = 0
    /// Share of the screen relative to other windows.
    var weight: Double = 1

    static let terminal = WindowPrefs(aspect: 0.7)
    static let browser = WindowPrefs(maxWidth: 1600, weight: 1.3)
    static let editor = WindowPrefs(weight: 1.5)
    static let chat = WindowPrefs(maxWidth: 1100, weight: 0.6)
    static let background = WindowPrefs(weight: 0.6)

    /// Bundle ID (or prefix ending in ".") → built-in preferences.
    private static let presets: [(String, WindowPrefs)] = [
        ("com.mitchellh.ghostty", .terminal),
        ("com.googlecode.iterm2", .terminal),
        ("com.apple.Terminal", .terminal),
        ("net.kovidgoyal.kitty", .terminal),
        ("org.alacritty", .terminal),
        ("com.github.wez.wezterm", .terminal),
        ("dev.warp.", .terminal),
        ("com.google.Chrome", .browser),
        ("com.apple.Safari", .browser),
        ("org.mozilla.firefox", .browser),
        ("company.thebrowser.", .browser),
        ("com.brave.Browser", .browser),
        ("com.microsoft.edgemac", .browser),
        ("app.zen-browser.", .browser),
        ("com.microsoft.VSCode", .editor),
        ("com.todesktop.230313mzl4w4u92", .editor), // Cursor
        ("dev.zed.Zed", .editor),
        ("com.jetbrains.", .editor),
        ("com.apple.dt.Xcode", .editor),
        ("com.sublimetext.", .editor),
        ("com.tinyspeck.slackmacgap", .chat),
        ("com.hnc.Discord", .chat),
        ("ru.keepcoder.Telegram", .chat),
        ("net.whatsapp.WhatsApp", .chat),
        ("com.apple.MobileSMS", .chat),
        ("com.microsoft.teams2", .chat),
        ("com.spotify.client", .background),
        ("com.apple.Music", .background),
    ]

    static func preset(bundleId: String?) -> WindowPrefs {
        guard let bundleId else { return WindowPrefs() }
        for (key, prefs) in presets {
            if key.hasSuffix(".") ? bundleId.hasPrefix(key) : bundleId == key { return prefs }
        }
        return WindowPrefs()
    }

    static func resolve(bundleId: String?, rules: [WindowRule]) -> WindowPrefs {
        var prefs = preset(bundleId: bundleId)
        if let text = rules.lazy.compactMap(\.aspect).first {
            if let aspect = parseAspect(text) {
                prefs.aspect = aspect
            } else {
                print("[Config] Unknown aspect \"\(text)\" in window rule — ignored.")
            }
        }
        if let maxWidth = rules.lazy.compactMap(\.max_width).first { prefs.maxWidth = max(0, maxWidth) }
        if let weight = rules.lazy.compactMap(\.weight).first, weight > 0 { prefs.weight = weight }
        return prefs
    }

    /// "tall", "wide", "square", "16:9" or a plain width ÷ height number.
    static func parseAspect(_ text: String) -> Double? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch t {
        case "tall": return 0.7
        case "wide": return 1.8
        case "square": return 1.0
        case "none", "": return 0
        default: break
        }
        let parts = t.split(separator: ":")
        if parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 { return w / h }
        if parts.count == 1, let value = Double(t), value > 0 { return value }
        return nil
    }

    func send(for wid: TalysWindowId) {
        talys_engine_set_window_prefs(wid, aspect, maxWidth, weight)
    }
}
