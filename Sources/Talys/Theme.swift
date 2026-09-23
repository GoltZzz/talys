import Cocoa
import SwiftUI
import Observation
import TOMLDecoder

public struct RGB: Sendable, Equatable {
    public let r: Double
    public let g: Double
    public let b: Double

    public init(_ hex: UInt32) {
        self.r = Double((hex >> 16) & 0xFF) / 255
        self.g = Double((hex >> 8) & 0xFF) / 255
        self.b = Double(hex & 0xFF) / 255
    }

    public init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.hasPrefix("0x") { s.removeFirst(2) }
        guard s.count == 6, let value = UInt32(s, radix: 16) else { return nil }
        self.init(value)
    }

    public var color: Color { Color(red: r, green: g, blue: b) }
    public var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: 1) }
    public var cgColor: CGColor { nsColor.cgColor }
}

public struct Theme: Sendable, Equatable {
    public var name: String
    public var displayName: String

    public var base: RGB
    public var mantle: RGB
    public var crust: RGB
    public var surface0: RGB
    public var surface1: RGB
    public var overlay0: RGB
    public var text: RGB
    public var subtext0: RGB
    public var accent: RGB
    public var secondary: RGB
    public var green: RGB
    public var red: RGB
    public var yellow: RGB

    public var borderActive: RGB
    public var borderActive2: RGB
    public var borderInactive: RGB
}

extension Theme {
    public static let catppuccinMocha = Theme(
        name: "catppuccin_mocha", displayName: "Catppuccin Mocha",
        base: RGB(0x1E1E2E), mantle: RGB(0x181825), crust: RGB(0x11111B),
        surface0: RGB(0x313244), surface1: RGB(0x45475A), overlay0: RGB(0x6C7086),
        text: RGB(0xCDD6F4), subtext0: RGB(0xA6ADC8),
        accent: RGB(0xCBA6F7), secondary: RGB(0x74C7EC),
        green: RGB(0xA6E3A1), red: RGB(0xF38BA8), yellow: RGB(0xF9E2AF),
        borderActive: RGB(0xCBA6F7), borderActive2: RGB(0x74C7EC), borderInactive: RGB(0x45475A)
    )

    public static let tokyoNight = Theme(
        name: "tokyo_night", displayName: "Tokyo Night",
        base: RGB(0x1A1B26), mantle: RGB(0x16161E), crust: RGB(0x13131A),
        surface0: RGB(0x292E42), surface1: RGB(0x3B4261), overlay0: RGB(0x565F89),
        text: RGB(0xC0CAF5), subtext0: RGB(0xA9B1D6),
        accent: RGB(0x7AA2F7), secondary: RGB(0xBB9AF7),
        green: RGB(0x9ECE6A), red: RGB(0xF7768E), yellow: RGB(0xE0AF68),
        borderActive: RGB(0x7AA2F7), borderActive2: RGB(0xBB9AF7), borderInactive: RGB(0x3B4261)
    )

    public static let gruvbox = Theme(
        name: "gruvbox", displayName: "Gruvbox",
        base: RGB(0x282828), mantle: RGB(0x1D2021), crust: RGB(0x151718),
        surface0: RGB(0x3C3836), surface1: RGB(0x504945), overlay0: RGB(0x7C6F64),
        text: RGB(0xEBDBB2), subtext0: RGB(0xD5C4A1),
        accent: RGB(0xFE8019), secondary: RGB(0x83A598),
        green: RGB(0xB8BB26), red: RGB(0xFB4934), yellow: RGB(0xFABD2F),
        borderActive: RGB(0xFE8019), borderActive2: RGB(0xFABD2F), borderInactive: RGB(0x504945)
    )

    public static let rosePine = Theme(
        name: "rose_pine", displayName: "Rosé Pine",
        base: RGB(0x191724), mantle: RGB(0x1F1D2E), crust: RGB(0x12101A),
        surface0: RGB(0x26233A), surface1: RGB(0x403D52), overlay0: RGB(0x6E6A86),
        text: RGB(0xE0DEF4), subtext0: RGB(0x908CAA),
        accent: RGB(0xC4A7E7), secondary: RGB(0xEBBCBA),
        green: RGB(0x9CCFD8), red: RGB(0xEB6F92), yellow: RGB(0xF6C177),
        borderActive: RGB(0xC4A7E7), borderActive2: RGB(0xEBBCBA), borderInactive: RGB(0x403D52)
    )

    public static let nord = Theme(
        name: "nord", displayName: "Nord",
        base: RGB(0x2E3440), mantle: RGB(0x2B303B), crust: RGB(0x242933),
        surface0: RGB(0x3B4252), surface1: RGB(0x434C5E), overlay0: RGB(0x4C566A),
        text: RGB(0xECEFF4), subtext0: RGB(0xD8DEE9),
        accent: RGB(0x88C0D0), secondary: RGB(0x81A1C1),
        green: RGB(0xA3BE8C), red: RGB(0xBF616A), yellow: RGB(0xEBCB8B),
        borderActive: RGB(0x88C0D0), borderActive2: RGB(0x81A1C1), borderInactive: RGB(0x434C5E)
    )

    public static let builtIn: [Theme] = [catppuccinMocha, tokyoNight, gruvbox, rosePine, nord]

    /// Overlays hex color overrides (e.g. `accent = "#ff0000"`) from a user theme file.
    func applying(overrides: [String: String]) -> Theme {
        var t = self
        func set(_ key: String, _ path: WritableKeyPath<Theme, RGB>) {
            if let hex = overrides[key], let rgb = RGB(hexString: hex) { t[keyPath: path] = rgb }
        }
        set("base", \.base); set("mantle", \.mantle); set("crust", \.crust)
        set("surface0", \.surface0); set("surface1", \.surface1); set("overlay0", \.overlay0)
        set("text", \.text); set("subtext0", \.subtext0)
        set("accent", \.accent); set("secondary", \.secondary)
        set("green", \.green); set("red", \.red); set("yellow", \.yellow)
        t.borderActive = t.accent
        t.borderActive2 = t.secondary
        t.borderInactive = t.surface1
        set("border_active", \.borderActive); set("border_active_2", \.borderActive2); set("border_inactive", \.borderInactive)
        if let display = overrides["display_name"] { t.displayName = display }
        return t
    }
}

@Observable
@MainActor
public final class ThemeManager {
    public static let shared = ThemeManager()

    public private(set) var current: Theme = .catppuccinMocha

    @ObservationIgnored
    public var onThemeChanged: ((Theme) -> Void)?

    private init() {}

    /// `~/.config/talys/themes/<name>.toml` — flat hex keys, unspecified keys inherit from `extends` (default catppuccin_mocha).
    public static var themesDirectory: URL {
        ConfigManager.configURL.deletingLastPathComponent().appendingPathComponent("themes")
    }

    public func availableThemes() -> [Theme] {
        var themes = Theme.builtIn
        let dir = Self.themesDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.pathExtension == "toml" {
            let name = file.deletingPathExtension().lastPathComponent
            if let theme = loadUserTheme(named: name) {
                themes.removeAll { $0.name == name }
                themes.append(theme)
            }
        }
        return themes
    }

    public func theme(named name: String) -> Theme? {
        let key = Self.normalize(name)
        if let user = loadUserTheme(named: key) { return user }
        return Theme.builtIn.first { $0.name == key }
    }

    @discardableResult
    public func apply(named name: String) -> Bool {
        guard let theme = theme(named: name) else {
            print("[Theme] Unknown theme \"\(name)\"; keeping \(current.name).")
            return false
        }
        guard theme != current else { return true }
        current = theme
        print("[Theme] Applied \(theme.displayName)")
        onThemeChanged?(theme)
        return true
    }

    public func cycle() {
        let themes = availableThemes()
        guard !themes.isEmpty else { return }
        let idx = themes.firstIndex { $0.name == current.name } ?? -1
        let next = themes[(idx + 1) % themes.count]
        if apply(named: next.name) {
            ConfigManager.persistTheme(next.name)
        }
    }

    private func loadUserTheme(named name: String) -> Theme? {
        let url = Self.themesDirectory.appendingPathComponent("\(name).toml")
        guard let data = try? Data(contentsOf: url) else { return nil }
        do {
            let overrides = try TOMLDecoder().decode([String: String].self, from: data)
            let baseName = Self.normalize(overrides["extends"] ?? Theme.catppuccinMocha.name)
            let base = Theme.builtIn.first { $0.name == baseName } ?? .catppuccinMocha
            var theme = base.applying(overrides: overrides)
            theme.name = name
            if overrides["display_name"] == nil { theme.displayName = name }
            return theme
        } catch {
            print("[Theme] Could not parse \(url.path): \(error)")
            return nil
        }
    }

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "é", with: "e")
    }
}
