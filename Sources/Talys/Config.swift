import Foundation
import TOMLDecoder
import CTalysEngine

// Every config section decodes with `decodeIfPresent` so a config file written by an older
// Talys version (missing newer keys or whole sections) still loads instead of falling back to defaults.

public struct GapsConfig: Codable, Sendable {
    public var inner: Double = 8.0
    public var outer: Double = 10.0

    public init(inner: Double = 8.0, outer: Double = 10.0) {
        self.inner = inner
        self.outer = outer
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GapsConfig()
        inner = try c.decodeIfPresent(Double.self, forKey: .inner) ?? d.inner
        outer = try c.decodeIfPresent(Double.self, forKey: .outer) ?? d.outer
    }
}

public struct GeneralConfig: Codable, Sendable {
    public var layout: String = "smart"
    /// Modifier(s) substituted for `mod` in keybindings, e.g. "alt", "cmd", "hyper", "ctrl+alt".
    public var mod: String = "alt"
    /// Theme name; falls back to `[bar] theme` when unset.
    public var theme: String?
    /// What happens to a window that can't shrink enough to fit its workspace: "workspace" moves it to the
    /// next workspace with room, "float" floats it on top.
    public var overflow: String = "workspace"
    /// Switch to the workspace a newly opened window overflowed to.
    public var overflow_follow: Bool = true

    public init(layout: String = "smart", mod: String = "alt", theme: String? = nil,
                overflow: String = "workspace", overflow_follow: Bool = true) {
        self.layout = layout
        self.mod = mod
        self.theme = theme
        self.overflow = overflow
        self.overflow_follow = overflow_follow
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GeneralConfig()
        layout = try c.decodeIfPresent(String.self, forKey: .layout) ?? d.layout
        mod = try c.decodeIfPresent(String.self, forKey: .mod) ?? d.mod
        theme = try c.decodeIfPresent(String.self, forKey: .theme)
        overflow = try c.decodeIfPresent(String.self, forKey: .overflow) ?? d.overflow
        overflow_follow = try c.decodeIfPresent(Bool.self, forKey: .overflow_follow) ?? d.overflow_follow
    }
}

public struct WindowRule: Codable, Sendable {
    public var app: String?
    public var title: String?
    public var floating: Bool?
    public var workspace: UInt8?
    /// Smart layout: preferred shape — "tall", "wide", "square", "16:9" or a width ÷ height number.
    public var aspect: String?
    /// Smart layout: width past which the window just wastes space.
    public var max_width: Double?
    /// Smart layout: share of the screen relative to other windows (1 = normal).
    public var weight: Double?

    public init(app: String? = nil, title: String? = nil, floating: Bool? = nil, workspace: UInt8? = nil,
                aspect: String? = nil, max_width: Double? = nil, weight: Double? = nil) {
        self.app = app
        self.title = title
        self.floating = floating
        self.workspace = workspace
        self.aspect = aspect
        self.max_width = max_width
        self.weight = weight
    }
}

/// `[[bind]]` entry that runs a shell command, e.g. `keys = "mod+return"`, `exec = "open -na Ghostty"`.
public struct ExecBind: Codable, Sendable {
    public var keys: String
    public var exec: String
}

public struct AnimationsConfig: Codable, Sendable {
    public var enabled: Bool = true
    public var duration_ms: Double = 120.0

    public init(enabled: Bool = true, duration_ms: Double = 120.0) {
        self.enabled = enabled
        self.duration_ms = duration_ms
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AnimationsConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        duration_ms = try c.decodeIfPresent(Double.self, forKey: .duration_ms) ?? d.duration_ms
    }
}

public struct BordersConfig: Codable, Sendable {
    public var enabled: Bool = true
    public var width: Double = 2.0
    public var radius: Double = 12.0
    /// Draw the active border as an accent → secondary gradient (Hyprland style).
    public var gradient: Bool = true

    public init(enabled: Bool = true, width: Double = 2.0, radius: Double = 12.0, gradient: Bool = true) {
        self.enabled = enabled
        self.width = width
        self.radius = radius
        self.gradient = gradient
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BordersConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        width = try c.decodeIfPresent(Double.self, forKey: .width) ?? d.width
        radius = try c.decodeIfPresent(Double.self, forKey: .radius) ?? d.radius
        gradient = try c.decodeIfPresent(Bool.self, forKey: .gradient) ?? d.gradient
    }
}

public struct BarConfig: Codable, Sendable {
    public var enabled: Bool = true
    public var height: Double = 34.0
    public var margin_top: Double = 6.0
    public var margin_horizontal: Double = 14.0
    public var gap: Double = 8.0
    public var theme: String = "catppuccin_mocha"
    /// 12-hour clock ("9:43 PM") instead of 24-hour ("21:43").
    public var clock_12h: Bool = true
    /// "talys" swaps the macOS menu bar for the Talys bar, "macos" keeps the menu bar and shows no Talys bar,
    /// "ask" asks on launch and writes the answer back here.
    public var menu_bar: String = "ask"

    public init(
        enabled: Bool = true,
        height: Double = 34.0,
        margin_top: Double = 6.0,
        margin_horizontal: Double = 14.0,
        gap: Double = 8.0,
        theme: String = "catppuccin_mocha",
        clock_12h: Bool = true,
        menu_bar: String = "ask"
    ) {
        self.enabled = enabled
        self.height = height
        self.margin_top = margin_top
        self.margin_horizontal = margin_horizontal
        self.gap = gap
        self.theme = theme
        self.clock_12h = clock_12h
        self.menu_bar = menu_bar
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = BarConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        height = try c.decodeIfPresent(Double.self, forKey: .height) ?? d.height
        margin_top = try c.decodeIfPresent(Double.self, forKey: .margin_top) ?? d.margin_top
        margin_horizontal = try c.decodeIfPresent(Double.self, forKey: .margin_horizontal) ?? d.margin_horizontal
        gap = try c.decodeIfPresent(Double.self, forKey: .gap) ?? d.gap
        theme = try c.decodeIfPresent(String.self, forKey: .theme) ?? d.theme
        clock_12h = try c.decodeIfPresent(Bool.self, forKey: .clock_12h) ?? d.clock_12h
        menu_bar = try c.decodeIfPresent(String.self, forKey: .menu_bar) ?? d.menu_bar
    }
}

public struct TalysConfig: Codable, Sendable {
    public var gaps: GapsConfig = GapsConfig()
    public var general: GeneralConfig = GeneralConfig()
    public var keybindings: [String: String] = [:]
    public var bind: [ExecBind] = []
    public var window_rules: [WindowRule] = []
    public var animations: AnimationsConfig = AnimationsConfig()
    public var borders: BordersConfig = BordersConfig()
    public var bar: BarConfig = BarConfig()

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        gaps = try c.decodeIfPresent(GapsConfig.self, forKey: .gaps) ?? GapsConfig()
        general = try c.decodeIfPresent(GeneralConfig.self, forKey: .general) ?? GeneralConfig()
        keybindings = try c.decodeIfPresent([String: String].self, forKey: .keybindings) ?? [:]
        bind = try c.decodeIfPresent([ExecBind].self, forKey: .bind) ?? []
        window_rules = try c.decodeIfPresent([WindowRule].self, forKey: .window_rules) ?? []
        animations = try c.decodeIfPresent(AnimationsConfig.self, forKey: .animations) ?? AnimationsConfig()
        borders = try c.decodeIfPresent(BordersConfig.self, forKey: .borders) ?? BordersConfig()
        bar = try c.decodeIfPresent(BarConfig.self, forKey: .bar) ?? BarConfig()
    }

    public var themeName: String { general.theme ?? bar.theme }
}

public enum ConfigManager {
    public static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/talys/config.toml")
    }

    /// Action name → default key string. User `[keybindings]` entries override these by name.
    public static let defaultKeybindings: [String: String] = {
        var map: [String: String] = [
            "focus_left": "mod+h",
            "focus_down": "mod+j",
            "focus_up": "mod+k",
            "focus_right": "mod+l",
            "swap_left": "mod+shift+h",
            "swap_down": "mod+shift+j",
            "swap_up": "mod+shift+k",
            "swap_right": "mod+shift+l",
            "toggle_float": "mod+v",
            "close_window": "mod+q",
            "retile": "mod+r",
            "resize_shrink": "mod+[",
            "resize_grow": "mod+]",
            "toggle_fullscreen": "mod+f",
            "cycle_layout": "mod+tab",
            "launcher": "mod+space",
            "toggle_scratchpad": "mod+s",
            "move_to_scratchpad": "mod+shift+s",
            "cycle_theme": "mod+shift+t",
            "toggle_animations": "mod+shift+a",
            "cycle_column_width": "mod+w",
            "stack_left": "mod+comma",
            "stack_right": "mod+period",
            "open_settings": "mod+shift+comma",
        ]
        for ws in 1...9 {
            map["switch_workspace_\(ws)"] = "mod+\(ws)"
            map["move_to_workspace_\(ws)"] = "mod+shift+\(ws)"
        }
        return map
    }()

    public static let actionMap: [String: KeyAction] = {
        var map: [String: KeyAction] = [
            "focus_left": .focusDirection(0),
            "focus_down": .focusDirection(1),
            "focus_up": .focusDirection(2),
            "focus_right": .focusDirection(3),
            "swap_left": .swapDirection(0),
            "swap_down": .swapDirection(1),
            "swap_up": .swapDirection(2),
            "swap_right": .swapDirection(3),
            "toggle_float": .toggleFloat,
            "close_window": .closeWindow,
            "retile": .retile,
            "resize_shrink": .resize(-0.05),
            "resize_grow": .resize(0.05),
            "toggle_fullscreen": .toggleFullscreen,
            "cycle_layout": .cycleLayout,
            "launcher": .toggleLauncher,
            "toggle_scratchpad": .toggleScratchpad,
            "move_to_scratchpad": .moveToScratchpad,
            "cycle_theme": .cycleTheme,
            "toggle_animations": .toggleAnimations,
            "cycle_column_width": .cycleColumnWidth,
            "stack_left": .consumeOrExpel(0),
            "stack_right": .consumeOrExpel(3),
            "open_settings": .openSettings,
        ]
        for ws in 1...9 {
            map["switch_workspace_\(ws)"] = .switchWorkspace(UInt8(ws))
            map["move_to_workspace_\(ws)"] = .moveToWorkspace(UInt8(ws))
        }
        return map
    }()

    private static let defaultTomlContent = """
# Talys Configuration (~/.config/talys/config.toml)

[general]
layout = "smart"            # "smart", "dwindle", "master_stack", "scrolling", "monocle"
mod = "alt"                 # Modifier used by "mod+..." binds: "alt", "cmd", "ctrl", "hyper", or combos like "ctrl+alt"
theme = "catppuccin_mocha"  # catppuccin_mocha, tokyo_night, gruvbox, rose_pine, nord, or ~/.config/talys/themes/<name>.toml
overflow = "workspace"      # Window too big to fit its workspace: "workspace" (next one with room) or "float"
overflow_follow = true      # Switch to the workspace a newly opened window overflowed to

[bar]
enabled = true
height = 34.0
margin_top = 6.0
margin_horizontal = 14.0
gap = 8.0
clock_12h = true            # 12-hour clock (9:43 PM); false for 24-hour (21:43)
menu_bar = "ask"            # "talys": Talys bar replaces the macOS menu bar (restored on quit); "macos": keep it, no Talys bar; "ask": ask on launch

[gaps]
inner = 8.0
outer = 10.0

[borders]
enabled = true
width = 2.0
radius = 12.0
gradient = true

[animations]
enabled = true              # Toggle at runtime with toggle_animations (mod+shift+a)
duration_ms = 120.0

# Any action left out here keeps its default bind; set one to "" to unbind it.
[keybindings]
focus_left = "mod+h"
focus_down = "mod+j"
focus_up = "mod+k"
focus_right = "mod+l"

swap_left = "mod+shift+h"
swap_down = "mod+shift+j"
swap_up = "mod+shift+k"
swap_right = "mod+shift+l"

launcher = "mod+space"
toggle_float = "mod+v"
close_window = "mod+q"
retile = "mod+r"

resize_shrink = "mod+["
resize_grow = "mod+]"

toggle_fullscreen = "mod+f"
cycle_layout = "mod+tab"

toggle_scratchpad = "mod+s"
move_to_scratchpad = "mod+shift+s"
cycle_theme = "mod+shift+t"
toggle_animations = "mod+shift+a"
open_settings = "mod+shift+comma"

# Scrolling layout: columns scroll sideways instead of shrinking; focus_*/swap_* move between columns.
cycle_column_width = "mod+w"   # 1/3 → 1/2 → 2/3 of the screen
stack_left = "mod+comma"       # Stack into the left column, or pull out of a shared one
stack_right = "mod+period"

switch_workspace_1 = "mod+1"
switch_workspace_2 = "mod+2"
switch_workspace_3 = "mod+3"
switch_workspace_4 = "mod+4"
switch_workspace_5 = "mod+5"
switch_workspace_6 = "mod+6"
switch_workspace_7 = "mod+7"
switch_workspace_8 = "mod+8"
switch_workspace_9 = "mod+9"

move_to_workspace_1 = "mod+shift+1"
move_to_workspace_2 = "mod+shift+2"
move_to_workspace_3 = "mod+shift+3"
move_to_workspace_4 = "mod+shift+4"
move_to_workspace_5 = "mod+shift+5"
move_to_workspace_6 = "mod+shift+6"
move_to_workspace_7 = "mod+shift+7"
move_to_workspace_8 = "mod+shift+8"
move_to_workspace_9 = "mod+shift+9"

# Shell command binds (run with /bin/sh; Homebrew paths are on PATH).
[[bind]]
keys = "mod+return"
exec = "osascript -e 'tell application \\"Terminal\\" to do script \\"\\"' -e 'tell application \\"Terminal\\" to activate'"

# [[bind]]
# keys = "mod+return"
# exec = "open -na Ghostty"
#
# [[bind]]
# keys = "mod+b"
# exec = "open -a Safari"

# Example Window Rules:
# [[window_rules]]
# app = "Finder"
# floating = true
#
# [[window_rules]]
# app = "Spotify"
# workspace = 3
#
# Smart layout preferences (common terminals, browsers, editors and chat apps have built-in ones):
# [[window_rules]]
# app = "Ghostty"
# aspect = "tall"           # "tall", "wide", "square", "16:9", or a width ÷ height number
# weight = 1.5              # share of the screen relative to other windows (1 = normal)
# max_width = 1400.0        # wider than this just wastes space
"""

    public static func loadConfig(from url: URL = configURL) -> TalysConfig {
        let fileManager = FileManager.default

        if url == configURL && !fileManager.fileExists(atPath: url.path) {
            do {
                let dir = url.deletingLastPathComponent()
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try defaultTomlContent.write(to: url, atomically: true, encoding: .utf8)
                print("[Config] Created default config at \(url.path)")
            } catch {
                print("[Config] Could not create default config: \(error)")
            }
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            print("[Config] Using default configuration.")
            return TalysConfig()
        }

        do {
            let config = try decodeConfig(at: url)
            print("[Config] Successfully loaded configuration from \(url.path)")
            return config
        } catch {
            print("[Config] Error parsing config.toml: \(error). Using defaults.")
            return TalysConfig()
        }
    }

    /// Like `loadConfig`, but surfaces read and parse errors instead of falling back to defaults.
    public static func decodeConfig(at url: URL = configURL) throws -> TalysConfig {
        let data = try Data(contentsOf: url)
        return try TOMLDecoder().decode(TalysConfig.self, from: data)
    }

    @MainActor
    public static func applyConfig(_ config: TalysConfig, to controller: TilingController, keyboard: KeyboardManager) {
        controller.setGaps(inner: config.gaps.inner, outer: config.gaps.outer)

        let layout: Int32 = switch config.general.layout.lowercased() {
        case "dwindle": TALYS_LAYOUT_DWINDLE
        case "master_stack", "master-stack": TALYS_LAYOUT_MASTER_STACK
        case "monocle": TALYS_LAYOUT_MONOCLE
        case "scrolling", "scroll": TALYS_LAYOUT_SCROLLING
        default: TALYS_LAYOUT_SMART
        }
        talys_engine_set_default_layout_mode(UInt8(layout))
        TalysDesktopState.shared.updateLayoutModeFromEngine()

        controller.setWindowRules(config.window_rules)
        controller.setOverflow(toWorkspace: config.general.overflow.lowercased() != "float",
                               follow: config.general.overflow_follow)
        controller.setAnimations(enabled: config.animations.enabled, durationMs: config.animations.duration_ms)
        controller.setBarConfig(config.bar)

        ThemeManager.shared.apply(named: config.themeName)
        BorderController.shared.updateConfig(config.borders)

        keyboard.bindings = buildBindings(for: config)
        print("[Config] Applied \(keyboard.bindings.count) keybindings (mod = \(config.general.mod)).")

        controller.applyLayout()
    }

    /// Defaults, then `[keybindings]` overrides by action name, then `[[bind]]` exec entries.
    /// Later entries win when two binds claim the same key combo.
    public static func buildBindings(for config: TalysConfig) -> [KeyBinding: KeyAction] {
        var byName = defaultKeybindings
        for (name, keyStr) in config.keybindings {
            if actionMap[name] == nil {
                print("[Config] Unknown keybinding action \"\(name)\" — ignored.")
                continue
            }
            byName[name] = keyStr
        }

        let mod = config.general.mod
        var bindings: [KeyBinding: KeyAction] = [:]
        var owners: [KeyBinding: String] = [:]

        func insert(_ binding: KeyBinding, _ action: KeyAction, owner: String, keyStr: String) {
            if let previous = owners[binding] {
                print("[Config] \"\(keyStr)\" is bound to both \(previous) and \(owner); using \(owner).")
            }
            bindings[binding] = action
            owners[binding] = owner
        }

        // Defaults the user didn't touch go in first so explicit user binds win collisions.
        let userNames = Set(config.keybindings.keys)
        let ordered = byName.sorted { a, b in
            let aUser = userNames.contains(a.key), bUser = userNames.contains(b.key)
            return aUser == bUser ? a.key < b.key : !aUser
        }

        for (name, keyStr) in ordered {
            guard let action = actionMap[name], !keyStr.isEmpty else { continue }
            guard let binding = parseKeyBinding(keyStr, mod: mod) else {
                print("[Config] Could not parse key \"\(keyStr)\" for \(name).")
                continue
            }
            insert(binding, action, owner: name, keyStr: keyStr)
        }

        for entry in config.bind where !entry.keys.isEmpty {
            guard let binding = parseKeyBinding(entry.keys, mod: mod) else {
                print("[Config] Could not parse key \"\(entry.keys)\" for exec bind.")
                continue
            }
            insert(binding, .exec(entry.exec), owner: "exec(\(entry.exec))", keyStr: entry.keys)
        }

        return bindings
    }

    /// `talys --check-config [path]`: parse a config and print the resolved keybindings without starting the WM.
    public static func checkConfig(path: String?) {
        let url = path.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) } ?? configURL
        let config = loadConfig(from: url)
        print("mod = \(config.general.mod), theme = \(config.themeName), layout = \(config.general.layout)")
        print("borders: enabled=\(config.borders.enabled) width=\(config.borders.width) radius=\(config.borders.radius)")
        let bindings = buildBindings(for: config)
        let lines = bindings.map { binding, action -> String in
            let mods = [binding.ctrl ? "ctrl" : nil, binding.alt ? "alt" : nil, binding.shift ? "shift" : nil, binding.cmd ? "cmd" : nil]
                .compactMap { $0 }.joined(separator: "+")
            return "  \(mods)+key\(binding.keyCode) -> \(action)"
        }
        print("\(bindings.count) bindings:")
        lines.sorted().forEach { print($0) }
    }

    /// Writes `menu_bar` under [bar], replacing the retired `hide_macos_menu_bar` line or adding the line
    /// (or the section) if missing.
    @discardableResult
    public static func persistMenuBar(_ mode: String) -> Bool {
        let url = configURL
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: "\n")
        let newLine = "menu_bar = \"\(mode)\""

        var section = ""
        var barHeader: Int?
        var existing: Int?
        var legacy: Int?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line
                if line == "[bar]" { barHeader = i }
                continue
            }
            guard section == "[bar]" else { continue }
            if line.hasPrefix("menu_bar") { existing = i }
            if line.hasPrefix("hide_macos_menu_bar") { legacy = i }
        }

        if let i = existing ?? legacy {
            lines[i] = newLine
        } else if let i = barHeader {
            lines.insert(newLine, at: i + 1)
        } else {
            lines += ["", "[bar]", newLine]
        }

        text = lines.joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            print("[Config] Could not persist menu_bar: \(error)")
            return false
        }
    }

    /// Rewrites the `theme = "..."` line in config.toml so a theme picked at runtime survives restarts.
    public static func persistTheme(_ name: String) {
        let url = configURL
        guard var text = try? String(contentsOf: url, encoding: .utf8) else { return }
        var lines = text.components(separatedBy: "\n")
        let newLine = "theme = \"\(name)\""

        var section = ""
        var generalHeader: Int?
        var generalTheme: Int?
        var barTheme: Int?
        for (i, raw) in lines.enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                section = line
                if line == "[general]" { generalHeader = i }
                continue
            }
            let isThemeLine = line.hasPrefix("theme") && line.dropFirst(5).trimmingCharacters(in: .whitespaces).hasPrefix("=")
            if isThemeLine {
                if section == "[general]" { generalTheme = i }
                if section == "[bar]" { barTheme = i }
            }
        }

        if let i = generalTheme {
            lines[i] = newLine
        } else if let i = barTheme {
            lines[i] = newLine
        } else if let i = generalHeader {
            lines.insert(newLine, at: i + 1)
        } else {
            lines.insert(contentsOf: ["[general]", newLine, ""], at: 0)
        }

        text = lines.joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            print("[Config] Could not persist theme: \(error)")
        }
    }

    public static func parseModifiers(_ str: String) -> (ctrl: Bool, shift: Bool, cmd: Bool, alt: Bool) {
        var ctrl = false, shift = false, cmd = false, alt = false
        for part in str.lowercased().split(separator: "+").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            switch part {
            case "ctrl", "control": ctrl = true
            case "shift": shift = true
            case "cmd", "command", "super": cmd = true
            case "alt", "opt", "option": alt = true
            case "hyper": ctrl = true; shift = true; cmd = true; alt = true
            case "meh": ctrl = true; shift = true; alt = true
            default: break
            }
        }
        return (ctrl, shift, cmd, alt)
    }

    public static func parseKeyBinding(_ str: String, mod: String = "alt") -> KeyBinding? {
        let parts = str.lowercased().split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var ctrl = false
        var shift = false
        var cmd = false
        var alt = false
        var keyStr = ""

        for (i, part) in parts.enumerated() {
            // A trailing empty part means the key itself is "+", e.g. "mod+shift++".
            if part.isEmpty {
                if i == parts.count - 1 { keyStr = "+" }
                continue
            }
            switch part {
            case "mod", "$mod", "mainmod", "$mainmod":
                let m = parseModifiers(mod)
                ctrl = ctrl || m.ctrl; shift = shift || m.shift; cmd = cmd || m.cmd; alt = alt || m.alt
            case "ctrl", "control", "shift", "cmd", "command", "super", "alt", "opt", "option", "hyper", "meh":
                let m = parseModifiers(part)
                ctrl = ctrl || m.ctrl; shift = shift || m.shift; cmd = cmd || m.cmd; alt = alt || m.alt
            default:
                keyStr = part
            }
        }

        guard let keyCode = keyCodeForString(keyStr) else { return nil }
        return KeyBinding(keyCode: keyCode, ctrl: ctrl, shift: shift, cmd: cmd, alt: alt)
    }

    public static func keyCodeForString(_ str: String) -> UInt16? {
        switch str {
        case "a": return 0
        case "b": return 11
        case "c": return 8
        case "d": return 2
        case "e": return 14
        case "f": return 3
        case "g": return 5
        case "h": return 4
        case "i": return 34
        case "j": return 38
        case "k": return 40
        case "l": return 37
        case "m": return 46
        case "n": return 45
        case "o": return 31
        case "p": return 35
        case "q": return 12
        case "r": return 15
        case "s": return 1
        case "t": return 17
        case "u": return 32
        case "v": return 9
        case "w": return 13
        case "x": return 7
        case "y": return 16
        case "z": return 6
        case "1": return 18
        case "2": return 19
        case "3": return 20
        case "4": return 21
        case "5": return 23
        case "6": return 22
        case "7": return 26
        case "8": return 28
        case "9": return 25
        case "0": return 29
        case "[": return 33
        case "]": return 30
        case "-", "minus": return 27
        case "=", "equal", "+": return 24
        case ";", "semicolon": return 41
        case "'", "quote": return 39
        case ",", "comma": return 43
        case ".", "period": return 47
        case "/", "slash": return 44
        case "\\", "backslash": return 42
        case "`", "grave": return 50
        case "space": return 49
        case "tab": return 48
        case "return", "enter": return 36
        case "escape", "esc": return 53
        case "backspace", "delete": return 51
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        case "f1": return 122
        case "f2": return 120
        case "f3": return 99
        case "f4": return 118
        case "f5": return 96
        case "f6": return 97
        case "f7": return 98
        case "f8": return 100
        case "f9": return 101
        case "f10": return 109
        case "f11": return 103
        case "f12": return 111
        default: return nil
        }
    }
}
