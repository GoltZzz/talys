import Cocoa
import Observation
import SwiftUI

/// Formats key combos for config.toml ("mod+shift+1") and for display ("⌥⇧1").
enum Shortcut {
    /// Canonical config name for each key code, preferring words over punctuation that reads badly in TOML.
    private static let names: [UInt16: String] = {
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init)
        let others = ["[", "]", "minus", "equal", "semicolon", "quote", "comma", "period", "slash", "backslash",
                      "grave", "space", "tab", "return", "escape", "backspace", "left", "right", "up", "down"]
        let fKeys = (1...12).map { "f\($0)" }
        var map: [UInt16: String] = [:]
        for name in letters + others + fKeys {
            if let code = ConfigManager.keyCodeForString(name) { map[code] = name }
        }
        return map
    }()

    private static let labels: [String: String] = [
        "minus": "-", "equal": "=", "semicolon": ";", "quote": "'", "comma": ",", "period": ".",
        "slash": "/", "backslash": "\\", "grave": "`", "space": "Space", "tab": "⇥", "return": "↩",
        "escape": "⎋", "backspace": "⌫", "left": "←", "right": "→", "up": "↑", "down": "↓",
    ]

    static let escapeKey: UInt16 = 53
    static let backspaceKey: UInt16 = 51

    static func isFunctionKey(_ code: UInt16) -> Bool {
        names[code].map { $0.hasPrefix("f") && $0.count > 1 && $0.dropFirst().allSatisfy(\.isNumber) } ?? false
    }

    /// Config string for a captured combo, written relative to `mod` when the combo includes all of mod's keys.
    static func string(for binding: KeyBinding, mod: String) -> String? {
        guard let key = names[binding.keyCode] else { return nil }
        var ctrl = binding.ctrl, alt = binding.alt, cmd = binding.cmd, shift = binding.shift
        var parts: [String] = []

        let m = ConfigManager.parseModifiers(mod)
        let modUsed = m.ctrl || m.alt || m.cmd || m.shift
        if modUsed, (!m.ctrl || ctrl), (!m.alt || alt), (!m.cmd || cmd), (!m.shift || shift) {
            parts.append("mod")
            if m.ctrl { ctrl = false }
            if m.alt { alt = false }
            if m.cmd { cmd = false }
            if m.shift { shift = false }
        }
        if ctrl { parts.append("ctrl") }
        if alt { parts.append("alt") }
        if cmd { parts.append("cmd") }
        if shift { parts.append("shift") }
        return (parts + [key]).joined(separator: "+")
    }

    static func symbols(ctrl: Bool, alt: Bool, shift: Bool, cmd: Bool) -> String {
        (ctrl ? "⌃" : "") + (alt ? "⌥" : "") + (shift ? "⇧" : "") + (cmd ? "⌘" : "")
    }

    static func keyLabel(_ code: UInt16) -> String {
        names[code].map { labels[$0] ?? $0.uppercased() } ?? "key \(code)"
    }

    static func display(_ binding: KeyBinding) -> String {
        symbols(ctrl: binding.ctrl, alt: binding.alt, shift: binding.shift, cmd: binding.cmd) + keyLabel(binding.keyCode)
    }

    /// One keycap per modifier plus the key, in macOS order: ⌃ ⌥ ⇧ ⌘ key.
    static func caps(_ binding: KeyBinding) -> [String] {
        modifierCaps(ctrl: binding.ctrl, alt: binding.alt, shift: binding.shift, cmd: binding.cmd) + [keyLabel(binding.keyCode)]
    }

    static func modifierCaps(ctrl: Bool, alt: Bool, shift: Bool, cmd: Bool) -> [String] {
        [(ctrl, "⌃"), (alt, "⌥"), (shift, "⇧"), (cmd, "⌘")].filter(\.0).map(\.1)
    }
}

/// Everything the settings window shows, read from config.toml and written straight back to it.
@Observable
@MainActor
final class SettingsModel {
    enum Target: Hashable {
        case action(String)
        case exec(Int)
    }

    struct Conflict: Identifiable {
        let id = UUID()
        let target: Target
        let keys: String
        let owner: Target
    }

    struct ActionGroup: Identifiable {
        let title: String
        let actions: [(name: String, title: String)]
        var id: String { title }
    }

    static let actionGroups: [ActionGroup] = {
        var groups = [
            ActionGroup(title: "Focus", actions: [
                ("focus_left", "Focus Left"), ("focus_down", "Focus Down"),
                ("focus_up", "Focus Up"), ("focus_right", "Focus Right"),
            ]),
            ActionGroup(title: "Move Windows", actions: [
                ("swap_left", "Swap Left"), ("swap_down", "Swap Down"),
                ("swap_up", "Swap Up"), ("swap_right", "Swap Right"),
            ]),
            ActionGroup(title: "Windows", actions: [
                ("toggle_float", "Toggle Floating"), ("toggle_fullscreen", "Toggle Fullscreen"),
                ("close_window", "Close Window"), ("resize_shrink", "Shrink Split"),
                ("resize_grow", "Grow Split"), ("retile", "Retile All"),
            ]),
            ActionGroup(title: "Layout", actions: [
                ("cycle_layout", "Cycle Layout"), ("cycle_column_width", "Cycle Column Width"),
                ("stack_left", "Stack Into Left Column"), ("stack_right", "Stack Into Right Column"),
            ]),
            ActionGroup(title: "Switch Workspace", actions: (1...9).map { ("switch_workspace_\($0)", "Workspace \($0)") }),
            ActionGroup(title: "Move Window to Workspace", actions: (1...9).map { ("move_to_workspace_\($0)", "Workspace \($0)") }),
            ActionGroup(title: "Scratchpad", actions: [
                ("toggle_scratchpad", "Show or Hide Scratchpad"), ("move_to_scratchpad", "Send Window to Scratchpad"),
            ]),
            ActionGroup(title: "Talys", actions: [
                ("launcher", "Open Launcher"), ("open_settings", "Open Settings"),
                ("cycle_theme", "Next Theme"), ("toggle_animations", "Toggle Animations"),
            ]),
        ]
        // Actions added to the action map later still show up, just without a friendly group.
        let listed = Set(groups.flatMap { $0.actions.map(\.name) })
        let rest = ConfigManager.actionMap.keys.filter { !listed.contains($0) }.sorted()
        if !rest.isEmpty {
            groups.append(ActionGroup(title: "Other", actions: rest.map { ($0, $0.replacingOccurrences(of: "_", with: " ").capitalized) }))
        }
        return groups
    }()

    private static let actionTitles: [String: String] = {
        var titles: [String: String] = [:]
        for group in actionGroups {
            for action in group.actions {
                titles[action.name] = group.title.hasPrefix("Switch") || group.title.hasPrefix("Move Window")
                    ? "\(group.title): \(action.title)" : action.title
            }
        }
        return titles
    }()

    var config = TalysConfig()
    var loadError: String?
    var recording: Target?
    var recordingHint: String?
    var liveModifiers: NSEvent.ModifierFlags = []
    var conflict: Conflict?
    var saveError: String?

    @ObservationIgnored weak var keyboard: KeyboardManager?
    /// Called (debounced) after each write so the running WM picks the change up.
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var applyTask: Task<Void, Never>?

    func reload() {
        do {
            // Rules still being filled in aren't in the file yet (see saveWindowRules); keep them on screen.
            let drafts = config.window_rules.filter { ($0.app ?? "").isEmpty && ($0.title ?? "").isEmpty }
            config = try ConfigManager.decodeConfig()
            config.window_rules += drafts
            loadError = nil
        } catch {
            loadError = "\(error)"
        }
    }

    // MARK: - Writing

    private func write(_ edit: (inout ConfigFile) -> Void) {
        var file = ConfigFile.load()
        edit(&file)
        do {
            try file.save()
            saveError = nil
        } catch {
            saveError = "Could not save config.toml: \(error.localizedDescription)"
            return
        }
        scheduleApply()
    }

    private func scheduleApply() {
        applyTask?.cancel()
        applyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.onChange?()
        }
    }

    /// Two-way binding to a config field that writes `section.key` whenever it changes.
    func binding<T: Equatable>(_ path: WritableKeyPath<TalysConfig, T>, _ section: String, _ key: String,
                               _ encode: @escaping (T) -> TOMLValue) -> Binding<T> {
        Binding(
            get: { self.config[keyPath: path] },
            set: { value in
                guard self.config[keyPath: path] != value else { return }
                self.config[keyPath: path] = value
                self.write { $0.set(section, key, encode(value)) }
            }
        )
    }

    func number(_ path: WritableKeyPath<TalysConfig, Double>, _ section: String, _ key: String) -> Binding<Double> {
        binding(path, section, key) { .double($0) }
    }

    func toggle(_ path: WritableKeyPath<TalysConfig, Bool>, _ section: String, _ key: String) -> Binding<Bool> {
        binding(path, section, key) { .bool($0) }
    }

    func text(_ path: WritableKeyPath<TalysConfig, String>, _ section: String, _ key: String) -> Binding<String> {
        binding(path, section, key) { .string($0) }
    }

    var theme: Binding<String> {
        Binding(
            get: { ThemeManager.normalize(self.config.themeName) },
            set: { name in
                self.config.general.theme = name
                ThemeManager.shared.apply(named: name)
                ConfigManager.persistTheme(name)
                self.scheduleApply()
            }
        )
    }

    // MARK: - Arrays

    func saveExecBinds() {
        let entries = config.bind.map { [("keys", TOMLValue.string($0.keys)), ("exec", TOMLValue.string($0.exec))] }
        write { $0.replaceArray("bind", with: entries) }
    }

    func addExecBind() {
        config.bind.append(ExecBind(keys: "", exec: ""))
        saveExecBinds()
    }

    func removeExecBind(at index: Int) {
        guard config.bind.indices.contains(index) else { return }
        if recording == .exec(index) { stopRecording() }
        config.bind.remove(at: index)
        saveExecBinds()
    }

    func execCommand(_ index: Int) -> Binding<String> {
        Binding(
            get: { self.config.bind.indices.contains(index) ? self.config.bind[index].exec : "" },
            set: { value in
                guard self.config.bind.indices.contains(index) else { return }
                self.config.bind[index].exec = value
                self.saveExecBinds()
            }
        )
    }

    /// Rules without an app or title would match every window, so those stay out of the file until filled in.
    func saveWindowRules() {
        let entries: [[(String, TOMLValue)]] = config.window_rules.compactMap { rule in
            let app = rule.app?.trimmingCharacters(in: .whitespaces) ?? ""
            let title = rule.title?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !app.isEmpty || !title.isEmpty else { return nil }
            var entry: [(String, TOMLValue)] = []
            if !app.isEmpty { entry.append(("app", .string(app))) }
            if !title.isEmpty { entry.append(("title", .string(title))) }
            if let floating = rule.floating { entry.append(("floating", .bool(floating))) }
            if let workspace = rule.workspace { entry.append(("workspace", .int(Int(workspace)))) }
            if let aspect = rule.aspect { entry.append(("aspect", .string(aspect))) }
            if let maxWidth = rule.max_width { entry.append(("max_width", .double(maxWidth))) }
            if let weight = rule.weight { entry.append(("weight", .double(weight))) }
            return entry
        }
        write { $0.replaceArray("window_rules", with: entries) }
    }

    func addWindowRule(app: String = "") {
        config.window_rules.append(WindowRule(app: app))
        saveWindowRules()
    }

    func removeWindowRule(at index: Int) {
        guard config.window_rules.indices.contains(index) else { return }
        config.window_rules.remove(at: index)
        saveWindowRules()
    }

    func rule<T>(_ index: Int, _ path: WritableKeyPath<WindowRule, T>, default fallback: T) -> Binding<T> {
        Binding(
            get: { self.config.window_rules.indices.contains(index) ? self.config.window_rules[index][keyPath: path] : fallback },
            set: { value in
                guard self.config.window_rules.indices.contains(index) else { return }
                self.config.window_rules[index][keyPath: path] = value
                self.saveWindowRules()
            }
        )
    }

    // MARK: - Keybindings

    func keys(for target: Target) -> String {
        switch target {
        case .action(let name):
            return config.keybindings[name] ?? ConfigManager.defaultKeybindings[name] ?? ""
        case .exec(let index):
            return config.bind.indices.contains(index) ? config.bind[index].keys : ""
        }
    }

    func isDefault(_ name: String) -> Bool {
        keys(for: .action(name)) == (ConfigManager.defaultKeybindings[name] ?? "")
    }

    /// "⌥⇧1", "Not set", or the raw string when it doesn't parse.
    func display(for target: Target) -> (text: String, valid: Bool) {
        let str = keys(for: target)
        guard !str.isEmpty else { return ("Not set", true) }
        guard let binding = ConfigManager.parseKeyBinding(str, mod: config.general.mod) else { return (str, false) }
        return (Shortcut.display(binding), true)
    }

    /// Keycaps for the shortcut; empty when unbound, the raw string as one cap when it doesn't parse.
    func caps(for target: Target) -> (caps: [String], valid: Bool) {
        let str = keys(for: target)
        guard !str.isEmpty else { return ([], true) }
        guard let binding = ConfigManager.parseKeyBinding(str, mod: config.general.mod) else { return ([str], false) }
        return (Shortcut.caps(binding), true)
    }

    func title(for target: Target) -> String {
        switch target {
        case .action(let name):
            return Self.actionTitles[name] ?? name
        case .exec(let index):
            let cmd = config.bind.indices.contains(index) ? config.bind[index].exec : ""
            return cmd.isEmpty ? "a shell command" : "the command “\(cmd)”"
        }
    }

    func resetToDefault(_ name: String) {
        config.keybindings.removeValue(forKey: name)
        write { $0.remove("keybindings", name) }
    }

    func startRecording(_ target: Target) {
        recording = target
        recordingHint = nil
        liveModifiers = []
        keyboard?.captureHandler = { [weak self] binding in self?.captured(binding) }
    }

    func stopRecording() {
        recording = nil
        recordingHint = nil
        liveModifiers = []
        keyboard?.captureHandler = nil
    }

    private func captured(_ binding: KeyBinding) {
        guard let target = recording else { return }
        let bare = !binding.ctrl && !binding.alt && !binding.cmd && !binding.shift

        if bare, binding.keyCode == Shortcut.escapeKey {
            stopRecording()
            return
        }
        if bare, binding.keyCode == Shortcut.backspaceKey {
            stopRecording()
            assign("", to: target)
            return
        }
        // Without ⌃, ⌥ or ⌘ the combo would swallow ordinary typing in every app.
        if !binding.ctrl, !binding.alt, !binding.cmd, !Shortcut.isFunctionKey(binding.keyCode) {
            recordingHint = "Include ⌃, ⌥ or ⌘. Press Esc to cancel or ⌫ to clear."
            return
        }
        guard let keys = Shortcut.string(for: binding, mod: config.general.mod) else {
            recordingHint = "Talys can't bind that key. Try another."
            return
        }

        stopRecording()
        if let owner = owner(of: binding, excluding: target) {
            conflict = Conflict(target: target, keys: keys, owner: owner)
        } else {
            assign(keys, to: target)
        }
    }

    private func owner(of binding: KeyBinding, excluding target: Target) -> Target? {
        let mod = config.general.mod
        let candidates = ConfigManager.actionMap.keys.sorted().map(Target.action) + config.bind.indices.map(Target.exec)
        return candidates.first { candidate in
            candidate != target && ConfigManager.parseKeyBinding(keys(for: candidate), mod: mod) == binding
        }
    }

    private func assign(_ keys: String, to target: Target) {
        switch target {
        case .action(let name):
            config.keybindings[name] = keys
            write { $0.set("keybindings", name, .string(keys)) }
        case .exec(let index):
            guard config.bind.indices.contains(index) else { return }
            config.bind[index].keys = keys
            saveExecBinds()
        }
    }

    /// `swap` hands the other binding this one's old keys; otherwise the other binding is left unbound.
    func resolve(_ conflict: Conflict, swap: Bool) {
        let previous = keys(for: conflict.target)
        assign(swap ? previous : "", to: conflict.owner)
        assign(conflict.keys, to: conflict.target)
    }
}
