import Foundation
import TOMLDecoder
import CTalysEngine

public struct GapsConfig: Codable, Sendable {
    public var inner: Double = 8.0
    public var outer: Double = 10.0

    public init(inner: Double = 8.0, outer: Double = 10.0) {
        self.inner = inner
        self.outer = outer
    }
}

public struct GeneralConfig: Codable, Sendable {
    public var layout: String = "dwindle"

    public init(layout: String = "dwindle") {
        self.layout = layout
    }
}

public struct WindowRule: Codable, Sendable {
    public var app: String?
    public var title: String?
    public var floating: Bool?
    public var workspace: UInt8?

    public init(app: String? = nil, title: String? = nil, floating: Bool? = nil, workspace: UInt8? = nil) {
        self.app = app
        self.title = title
        self.floating = floating
        self.workspace = workspace
    }
}

public struct AnimationsConfig: Codable, Sendable {
    public var enabled: Bool = true
    public var duration_ms: Double = 180.0

    public init(enabled: Bool = true, duration_ms: Double = 180.0) {
        self.enabled = enabled
        self.duration_ms = duration_ms
    }
}

public struct TalysConfig: Codable, Sendable {
    public var gaps: GapsConfig = GapsConfig()
    public var general: GeneralConfig = GeneralConfig()
    public var keybindings: [String: String] = [:]
    public var window_rules: [WindowRule] = []
    public var animations: AnimationsConfig = AnimationsConfig()
}

public enum ConfigManager {
    public static var configURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".config/talys/config.toml")
    }

    private static let defaultTomlContent = """
# Talys Configuration (~/.config/talys/config.toml)

[gaps]
inner = 8.0
outer = 10.0

[general]
layout = "dwindle" # Options: "dwindle", "master_stack", "monocle"

[animations]
enabled = true
duration_ms = 180.0

[keybindings]
focus_left = "alt+h"
focus_down = "alt+j"
focus_up = "alt+k"
focus_right = "alt+l"

swap_left = "alt+shift+h"
swap_down = "alt+shift+j"
swap_up = "alt+shift+k"
swap_right = "alt+shift+l"

toggle_float = "alt+space"
close_window = "alt+q"
retile = "alt+r"

resize_shrink = "alt+["
resize_grow = "alt+]"

toggle_fullscreen = "alt+f"
cycle_layout = "alt+tab"

switch_workspace_1 = "alt+1"
switch_workspace_2 = "alt+2"
switch_workspace_3 = "alt+3"
switch_workspace_4 = "alt+4"
switch_workspace_5 = "alt+5"
switch_workspace_6 = "alt+6"
switch_workspace_7 = "alt+7"
switch_workspace_8 = "alt+8"
switch_workspace_9 = "alt+9"

move_to_workspace_1 = "alt+shift+1"
move_to_workspace_2 = "alt+shift+2"
move_to_workspace_3 = "alt+shift+3"
move_to_workspace_4 = "alt+shift+4"
move_to_workspace_5 = "alt+shift+5"
move_to_workspace_6 = "alt+shift+6"
move_to_workspace_7 = "alt+shift+7"
move_to_workspace_8 = "alt+shift+8"
move_to_workspace_9 = "alt+shift+9"

# Example Window Rules:
# [[window_rules]]
# app = "Finder"
# floating = true
#
# [[window_rules]]
# app = "Calculator"
# floating = true
#
# [[window_rules]]
# app = "Spotify"
# workspace = 3
"""

    public static func loadConfig() -> TalysConfig {
        let fileManager = FileManager.default
        let url = configURL

        if !fileManager.fileExists(atPath: url.path) {
            do {
                let dir = url.deletingLastPathComponent()
                try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
                try defaultTomlContent.write(to: url, atomically: true, encoding: .utf8)
                print("[Config] Created default config at \(url.path)")
            } catch {
                print("[Config] Could not create default config: \(error)")
            }
        }

        guard let data = try? Data(contentsOf: url) else {
            print("[Config] Using default configuration.")
            return TalysConfig()
        }

        do {
            let decoder = TOMLDecoder()
            let config = try decoder.decode(TalysConfig.self, from: data)
            print("[Config] Successfully loaded configuration from \(url.path)")
            return config
        } catch {
            print("[Config] Error parsing config.toml: \(error). Using defaults.")
            return TalysConfig()
        }
    }

    public static func applyConfig(_ config: TalysConfig, to controller: TilingController, keyboard: KeyboardManager) {
        controller.setGaps(inner: config.gaps.inner, outer: config.gaps.outer)

        switch config.general.layout.lowercased() {
        case "master_stack", "master-stack":
            talys_engine_set_layout_mode(UInt8(TALYS_LAYOUT_MASTER_STACK))
        case "monocle":
            talys_engine_set_layout_mode(UInt8(TALYS_LAYOUT_MONOCLE))
        default:
            talys_engine_set_layout_mode(UInt8(TALYS_LAYOUT_DWINDLE))
        }

        controller.setWindowRules(config.window_rules)
        controller.setAnimations(enabled: config.animations.enabled, durationMs: config.animations.duration_ms)

        if !config.keybindings.isEmpty {
            var newBindings: [KeyBinding: KeyAction] = [:]

            var actionMap: [String: KeyAction] = [
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
            ]

            for ws in 1...9 {
                actionMap["switch_workspace_\(ws)"] = .switchWorkspace(UInt8(ws))
                actionMap["move_to_workspace_\(ws)"] = .moveToWorkspace(UInt8(ws))
            }

            for (name, keyStr) in config.keybindings {
                if let action = actionMap[name], let binding = parseKeyBinding(keyStr) {
                    newBindings[binding] = action
                }
            }

            keyboard.bindings = newBindings
            print("[Config] Applied \(newBindings.count) custom keybindings.")
        } else {
            keyboard.setupDefaultBindings()
        }

        controller.applyLayout()
    }

    public static func parseKeyBinding(_ str: String) -> KeyBinding? {
        let parts = str.lowercased().split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces) }
        var ctrl = false
        var shift = false
        var cmd = false
        var alt = false
        var keyStr = ""

        for part in parts {
            switch part {
            case "ctrl", "control": ctrl = true
            case "shift": shift = true
            case "cmd", "command": cmd = true
            case "alt", "opt", "option": alt = true
            default: keyStr = part
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
        case "space": return 49
        case "tab": return 48
        case "return", "enter": return 36
        case "escape", "esc": return 53
        case "left": return 123
        case "right": return 124
        case "down": return 125
        case "up": return 126
        default: return nil
        }
    }
}
