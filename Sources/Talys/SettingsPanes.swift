import Cocoa
import SwiftUI

// The pages of the settings window.

struct GeneralPane: View {
    let model: SettingsModel

    var body: some View {
        let s = SettingsSection.general
        SettingsPage(title: s.title, subtitle: s.subtitle, symbol: s.symbol) {
            SettingsCard(title: "Layout", footer: "Cycle through them any time with the Cycle Layout shortcut.") {
                // Four across when there's room, otherwise two by two; never three and an orphan.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        ForEach(LayoutGeometry.all, id: \.value) { layoutCard($0).frame(minWidth: 140) }
                    }
                    Grid(horizontalSpacing: 10, verticalSpacing: 10) {
                        ForEach([0, 2], id: \.self) { row in
                            GridRow {
                                layoutCard(LayoutGeometry.all[row])
                                layoutCard(LayoutGeometry.all[row + 1])
                            }
                        }
                    }
                }
                .padding(12)
            }

            SettingsCard(title: "Modifier key",
                         footer: "Every shortcut written as mod+… uses this key, so changing it moves them all at once.") {
                SettingRow(title: "mod", subtitle: modExample) {
                    SegmentedChoice(selection: mod, options: [
                        ("alt", "⌥"), ("cmd", "⌘"), ("ctrl", "⌃"), ("ctrl+alt", "⌃⌥"), ("meh", "Meh"), ("hyper", "Hyper"),
                    ])
                }
            }

            SettingsCard(title: "Windows that don't fit") {
                SettingRow(title: "When a window is too big", subtitle: "Some apps refuse to shrink below a minimum size.") {
                    SegmentedChoice(selection: model.text(\.general.overflow, "general", "overflow"), options: [
                        ("workspace", "Next workspace"), ("float", "Float on top"),
                    ])
                }
                RowDivider()
                SettingRow(title: "Follow it to the new workspace",
                           disabled: model.config.general.overflow.lowercased() == "float") {
                    ThemedToggle(isOn: model.toggle(\.general.overflow_follow, "general", "overflow_follow"))
                }
            }

            SettingsCard(title: "Config file",
                         footer: "Changes here save to this file and apply right away. Edits made by hand show up when you come back to this window.") {
                SettingRow(title: "config.toml",
                           subtitle: ConfigManager.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
                           subtitleOneLine: true) {
                    HStack(spacing: 8) {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ConfigManager.configURL]) }
                            .buttonStyle(.themed())
                        Button("Open") { NSWorkspace.shared.open(ConfigManager.configURL) }
                            .buttonStyle(.themed(.primary))
                    }
                    .fixedSize()
                }
            }
        }
    }

    private func layoutCard(_ layout: (value: String, label: String, blurb: String)) -> some View {
        LayoutCard(label: layout.label, blurb: layout.blurb, layout: layout.value,
                   selected: LayoutGeometry.normalize(model.config.general.layout) == layout.value) {
            model.text(\.general.layout, "general", "layout").wrappedValue = layout.value
        }
    }

    /// Hand-written spellings such as "option" still select their button.
    private var mod: Binding<String> {
        let raw = model.text(\.general.mod, "general", "mod")
        return Binding(
            get: {
                let m = ConfigManager.parseModifiers(raw.wrappedValue)
                switch (m.ctrl, m.alt, m.shift, m.cmd) {
                case (false, true, false, false): return "alt"
                case (false, false, false, true): return "cmd"
                case (true, false, false, false): return "ctrl"
                case (true, true, false, false): return "ctrl+alt"
                case (true, true, true, false): return "meh"
                case (true, true, true, true): return "hyper"
                default: return raw.wrappedValue
                }
            },
            set: { raw.wrappedValue = $0 }
        )
    }

    private var modExample: String {
        let m = ConfigManager.parseModifiers(model.config.general.mod)
        return "mod+1 is \(Shortcut.symbols(ctrl: m.ctrl, alt: m.alt, shift: m.shift, cmd: m.cmd))1."
    }
}

// MARK: - Keybindings

struct KeybindRow: View {
    let model: SettingsModel
    let name: String
    let title: String

    var body: some View {
        SettingRow(title: title) {
            HStack(spacing: 6) {
                if !model.isDefault(name) {
                    IconButton(symbol: "arrow.uturn.backward", help: "Reset to \(defaultDisplay)") {
                        withAnimation(.spring(response: 0.25)) { model.resetToDefault(name) }
                    }
                    .transition(.scale.combined(with: .opacity))
                }
                ShortcutRecorder(model: model, target: .action(name))
            }
        }
    }

    private var defaultDisplay: String {
        let keys = ConfigManager.defaultKeybindings[name] ?? ""
        return ConfigManager.parseKeyBinding(keys, mod: model.config.general.mod).map(Shortcut.display) ?? keys
    }
}

struct KeybindingsPane: View {
    let model: SettingsModel
    let openCheatSheet: () -> Void

    var body: some View {
        let s = SettingsSection.keybindings
        SettingsPage(title: s.title, subtitle: s.subtitle, symbol: s.symbol) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(Palette.secondary)
                Text("Include your mod key and it's saved as mod+…, so it moves when you change mod.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.subtext0)
                Spacer()
                Button("Cheat Sheet", systemImage: "list.bullet.rectangle.portrait", action: openCheatSheet)
                    .buttonStyle(.themed(.ghost))
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.secondary.opacity(0.08)))

            ForEach(SettingsModel.actionGroups) { group in
                if group.title.hasPrefix("Switch Workspace") || group.title.hasPrefix("Move Window to Workspace") {
                    SettingsCard(title: group.title) {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 8)], spacing: 8) {
                            ForEach(group.actions, id: \.name) { action in
                                WorkspaceTile(model: model, name: action.name,
                                              number: action.name.split(separator: "_").last.map(String.init) ?? "")
                            }
                        }
                        .padding(10)
                    }
                } else {
                    SettingsCard(title: group.title) {
                        ForEach(Array(group.actions.enumerated()), id: \.element.name) { i, action in
                            if i > 0 { RowDivider() }
                            KeybindRow(model: model, name: action.name, title: action.title)
                        }
                    }
                }
            }
        }
    }
}

/// Compact cell for the nine workspace shortcuts.
private struct WorkspaceTile: View {
    let model: SettingsModel
    let name: String
    let number: String

    var body: some View {
        HStack(spacing: 8) {
            Text(number)
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Palette.accent.opacity(0.14)))
            Spacer(minLength: 0)
            if !model.isDefault(name) {
                IconButton(symbol: "arrow.uturn.backward", help: "Reset to default") { model.resetToDefault(name) }
            }
            ShortcutRecorder(model: model, target: .action(name))
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.crust.opacity(0.35)))
    }
}

// MARK: - Commands

struct CommandsPane: View {
    let model: SettingsModel

    var body: some View {
        let s = SettingsSection.commands
        SettingsPage(title: s.title, subtitle: s.subtitle, symbol: s.symbol) {
            if model.config.bind.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Palette.accent)
                    Text("No commands yet")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text("Bind a key to open your terminal, a browser, or any shell command.")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.subtext0)
                    Button("Add Command", systemImage: "plus") { model.addExecBind() }
                        .buttonStyle(.themed(.primary))
                }
                .frame(maxWidth: .infinity)
                .padding(36)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Palette.surface1, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                )
            } else {
                SettingsCard(title: "Shell commands",
                             footer: "Each command runs with /bin/sh when you press its shortcut. Homebrew paths are on PATH.",
                             trailing: AnyView(Button("Add", systemImage: "plus") { model.addExecBind() }.buttonStyle(.themed(.ghost)))) {
                    ForEach(model.config.bind.indices, id: \.self) { index in
                        if index > 0 { RowDivider() }
                        HStack(spacing: 10) {
                            Image(systemName: "chevron.right.2")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Palette.green)
                            ThemedTextField(placeholder: "open -na Ghostty", text: model.execCommand(index), monospaced: true)
                            ShortcutRecorder(model: model, target: .exec(index))
                            IconButton(symbol: "trash", tint: Palette.red, help: "Remove this command") {
                                withAnimation { model.removeExecBind(at: index) }
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                    }
                }
            }
        }
    }
}

// MARK: - Window rules

struct RulesPane: View {
    let model: SettingsModel

    var body: some View {
        let s = SettingsSection.rules
        SettingsPage(title: s.title, subtitle: s.subtitle, symbol: s.symbol) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle.fill").foregroundStyle(Palette.secondary)
                Text("Rules apply to newly opened windows. App and title match any part of the name, ignoring case. The first matching rule wins.")
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.subtext0)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.secondary.opacity(0.08)))

            ForEach(model.config.window_rules.indices, id: \.self) { index in
                RuleCard(model: model, index: index)
            }

            Menu {
                Button("Blank Rule") { model.addWindowRule() }
                Divider()
                Section("Running apps") {
                    ForEach(runningApps, id: \.self) { name in
                        Button(name) { model.addWindowRule(app: name) }
                    }
                }
            } label: {
                Label("Add Rule", systemImage: "plus")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Palette.crust)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.accent))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }

    private var runningApps: [String] {
        let names = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.localizedName)
        return Array(Set(names)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }
}

private struct RuleCard: View {
    let model: SettingsModel
    let index: Int

    var body: some View {
        let rule = model.config.window_rules[index]
        let saved = !(rule.app ?? "").isEmpty || !(rule.title ?? "").isEmpty
        SettingsCard {
            HStack(spacing: 10) {
                appIcon(rule.app)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text([rule.app, rule.title].compactMap { $0 }.first { !$0.isEmpty } ?? "New rule")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(saved ? summary(rule) : "Not saved until an app or title is set")
                        .font(.system(size: 11))
                        .foregroundStyle(saved ? Palette.subtext0 : Palette.yellow)
                }
                Spacer()
                IconButton(symbol: "trash", tint: Palette.red, help: "Remove this rule") {
                    withAnimation { model.removeWindowRule(at: index) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            RowDivider()
            SettingRow(title: "App") {
                ThemedTextField(placeholder: "Spotify", text: optionalText(model.rule(index, \.app, default: nil)))
                    .frame(width: 240)
            }
            RowDivider()
            SettingRow(title: "Window title contains") {
                ThemedTextField(placeholder: "Optional", text: optionalText(model.rule(index, \.title, default: nil)))
                    .frame(width: 240)
            }
            RowDivider()
            SettingRow(title: "Tiling") {
                SegmentedChoice(selection: model.rule(index, \.floating, default: nil), options: [
                    (nil, "Default"), (true, "Float"), (false, "Tile"),
                ])
            }
            RowDivider()
            SettingRow(title: "Open on workspace") {
                ThemedMenu(selection: workspace, options: [("", "Current")] + (1...9).map { ("\($0)", "Workspace \($0)") })
            }
        }
    }

    private func summary(_ rule: WindowRule) -> String {
        var parts: [String] = []
        switch rule.floating {
        case true?: parts.append("floats")
        case false?: parts.append("tiles")
        case nil: break
        }
        if let ws = rule.workspace { parts.append("opens on workspace \(ws)") }
        return parts.isEmpty ? "No changes yet" : parts.joined(separator: ", ").prefix(1).uppercased() + parts.joined(separator: ", ").dropFirst()
    }

    @ViewBuilder
    private func appIcon(_ name: String?) -> some View {
        if let image = icon(for: name) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "macwindow")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.accent.opacity(0.14)))
        }
    }

    private func icon(for name: String?) -> NSImage? {
        guard let name, !name.isEmpty else { return nil }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName?.localizedCaseInsensitiveCompare(name) == .orderedSame
        }), let icon = app.icon {
            return icon
        }
        for dir in ["/Applications", "/System/Applications", "/Applications/Utilities"] {
            let path = "\(dir)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    private var workspace: Binding<String> {
        let raw = model.rule(index, \.workspace, default: nil)
        return Binding(
            get: { raw.wrappedValue.map { "\($0)" } ?? "" },
            set: { raw.wrappedValue = UInt8($0) }
        )
    }

    private func optionalText(_ binding: Binding<String?>) -> Binding<String> {
        Binding(get: { binding.wrappedValue ?? "" }, set: { binding.wrappedValue = $0.isEmpty ? nil : $0 })
    }
}

// MARK: - Appearance

struct AppearancePane: View {
    let model: SettingsModel

    var body: some View {
        let s = SettingsSection.appearance
        SettingsPage(title: s.title, subtitle: s.subtitle, symbol: s.symbol) {
            DesktopPreview(config: model.config)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)

            SettingsCard(title: "Theme", footer: "Add your own in ~/.config/talys/themes/<name>.toml.") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                    ForEach(ThemeManager.shared.availableThemes(), id: \.name) { theme in
                        ThemeSwatch(theme: theme, selected: model.theme.wrappedValue == theme.name) {
                            model.theme.wrappedValue = theme.name
                        }
                    }
                }
                .padding(12)
            }

            SettingsCard(title: "Gaps") {
                SettingRow(title: "Between windows") {
                    ThemedSlider(value: model.number(\.gaps.inner, "gaps", "inner"), range: 0...48)
                }
                RowDivider()
                SettingRow(title: "Screen edges") {
                    ThemedSlider(value: model.number(\.gaps.outer, "gaps", "outer"), range: 0...64)
                }
            }

            SettingsCard(title: "Borders") {
                SettingRow(title: "Active window border", subtitle: "Outlines the focused window in the theme's accent.") {
                    ThemedToggle(isOn: model.toggle(\.borders.enabled, "borders", "enabled"))
                }
                RowDivider()
                SettingRow(title: "Gradient", disabled: !model.config.borders.enabled) {
                    ThemedToggle(isOn: model.toggle(\.borders.gradient, "borders", "gradient"))
                }
                RowDivider()
                SettingRow(title: "Width", disabled: !model.config.borders.enabled) {
                    ThemedSlider(value: model.number(\.borders.width, "borders", "width"), range: 0.5...10, step: 0.5)
                }
                RowDivider()
                SettingRow(title: "Corner radius", disabled: !model.config.borders.enabled) {
                    ThemedSlider(value: model.number(\.borders.radius, "borders", "radius"), range: 0...24)
                }
            }

            SettingsCard(title: "Animations") {
                SettingRow(title: "Animate window movement") {
                    ThemedToggle(isOn: model.toggle(\.animations.enabled, "animations", "enabled"))
                }
                RowDivider()
                SettingRow(title: "Duration", disabled: !model.config.animations.enabled) {
                    ThemedSlider(value: model.number(\.animations.duration_ms, "animations", "duration_ms"),
                                 range: 0...500, step: 10, unit: "ms")
                }
            }
        }
    }
}

// MARK: - Bar

struct BarPane: View {
    let model: SettingsModel

    var body: some View {
        let s = SettingsSection.bar
        let usesMacOS = model.config.bar.menu_bar.lowercased() == "macos"
        SettingsPage(title: s.title, subtitle: s.subtitle, symbol: s.symbol) {
            DesktopPreview(config: model.config, highlightBar: true)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)

            SettingsCard(title: "Menu bar", footer: "The macOS menu bar comes back when Talys quits.") {
                SettingRow(title: "Use at the top of the screen") {
                    SegmentedChoice(selection: menuBar, options: [
                        ("talys", "Talys bar"), ("macos", "macOS"), ("ask", "Ask on launch"),
                    ])
                }
                RowDivider()
                SettingRow(title: "Show the Talys bar", disabled: usesMacOS) {
                    ThemedToggle(isOn: model.toggle(\.bar.enabled, "bar", "enabled"))
                }
                RowDivider()
                SettingRow(title: "12-hour clock") {
                    ThemedToggle(isOn: model.toggle(\.bar.clock_12h, "bar", "clock_12h"))
                }
            }

            let sizeDisabled = usesMacOS || !model.config.bar.enabled
            SettingsCard(title: "Size and position") {
                SettingRow(title: "Height", disabled: sizeDisabled) {
                    ThemedSlider(value: model.number(\.bar.height, "bar", "height"), range: 20...60)
                }
                RowDivider()
                SettingRow(title: "Top margin", disabled: sizeDisabled) {
                    ThemedSlider(value: model.number(\.bar.margin_top, "bar", "margin_top"), range: 0...30)
                }
                RowDivider()
                SettingRow(title: "Side margin", disabled: sizeDisabled) {
                    ThemedSlider(value: model.number(\.bar.margin_horizontal, "bar", "margin_horizontal"), range: 0...80)
                }
                RowDivider()
                SettingRow(title: "Gap below bar", disabled: sizeDisabled) {
                    ThemedSlider(value: model.number(\.bar.gap, "bar", "gap"), range: 0...30)
                }
            }
        }
    }

    private var menuBar: Binding<String> {
        let raw = model.text(\.bar.menu_bar, "bar", "menu_bar")
        return Binding(get: { raw.wrappedValue.lowercased() }, set: { raw.wrappedValue = $0 })
    }
}
