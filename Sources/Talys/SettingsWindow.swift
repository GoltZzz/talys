import Cocoa
import SwiftUI

/// The settings window: a native editor for config.toml whose changes save and apply immediately.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()

    let model = SettingsModel()
    private var window: NSWindow?
    private var flagsMonitor: Any?

    func configure(keyboard: KeyboardManager, onChange: @escaping () -> Void) {
        model.keyboard = keyboard
        model.onChange = onChange
    }

    func show() {
        model.reload()
        let window = self.window ?? makeWindow()
        self.window = window
        installEditMenuIfNeeded()
        if flagsMonitor == nil {
            // Shows held modifiers in the recorder before the key itself is pressed.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
                self?.model.liveModifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                return event
            }
        }
        updateAppearance()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Native controls (menus, text selection, scrollers) follow the theme's lightness.
    func updateAppearance() {
        let base = ThemeManager.shared.current.base
        let luminance = 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b
        window?.appearance = NSAppearance(named: luminance < 0.5 ? .darkAqua : .aqua)
    }

    private func makeWindow() -> NSWindow {
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = []
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Talys Settings"
        // The themed sidebar draws right up to the top edge; the traffic lights sit on it.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.setContentSize(NSSize(width: 900, height: 640))
        window.contentMinSize = NSSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("TalysSettings")
        return window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Pick up edits made to config.toml by hand while the window was in the background.
        if model.recording == nil { model.reload() }
    }

    func windowDidResignKey(_ notification: Notification) {
        model.stopRecording()
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
        if let monitor = flagsMonitor {
            NSEvent.removeMonitor(monitor)
            flagsMonitor = nil
        }
    }

    /// Talys runs without a menu bar of its own, so text fields get no copy/paste shortcuts unless a main menu
    /// provides them. Deliberately has no Quit item, so ⌘Q in this window doesn't stop the window manager.
    private func installEditMenuIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        let main = NSMenu()
        main.addItem(NSMenuItem(title: "Talys", action: nil, keyEquivalent: ""))
        main.items[0].submenu = NSMenu(title: "Talys")

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
    }
}


// MARK: - Root

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, keybindings, commands, rules, appearance, bar

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .keybindings: return "Keybindings"
        case .commands: return "Commands"
        case .rules: return "Window Rules"
        case .appearance: return "Appearance"
        case .bar: return "Bar"
        }
    }

    var subtitle: String {
        switch self {
        case .general: return "How windows are laid out and which key drives Talys."
        case .keybindings: return "Click a shortcut and press the new keys. Esc cancels, ⌫ clears."
        case .commands: return "Shell commands you can launch from a shortcut."
        case .rules: return "Float, tile or place specific apps when their windows open."
        case .appearance: return "Theme, gaps, borders and motion. The preview updates as you go."
        case .bar: return "The floating Talys bar at the top of the screen."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "square.grid.2x2.fill"
        case .keybindings: return "keyboard.fill"
        case .commands: return "terminal.fill"
        case .rules: return "macwindow.on.rectangle"
        case .appearance: return "paintpalette.fill"
        case .bar: return "menubar.rectangle"
        }
    }
}

struct SettingsView: View {
    @Bindable var model: SettingsModel
    @State private var section: SettingsSection = .general
    @State private var search = ""
    @State private var showCheatSheet = false

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                SettingsSidebar(section: $section, search: $search, showCheatSheet: $showCheatSheet)
                    .frame(width: 230)
                Rectangle().fill(Color.white.opacity(0.06)).frame(width: 1)
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .top) { WindowDragArea().frame(height: 28) }
            }

            if showCheatSheet {
                CheatSheetOverlay(model: model) { withAnimation(.easeOut(duration: 0.18)) { showCheatSheet = false } }
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
            if let conflict = model.conflict {
                ConflictDialog(model: model, conflict: conflict)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.conflict?.id)
        .overlay(alignment: .bottom) {
            if let error = model.saveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Palette.crust)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Palette.red))
                    .padding(16)
            }
        }
        .background(background)
        .environment(\.colorScheme, isDark ? .dark : .light)
        .onChange(of: ThemeManager.shared.current.name, initial: true) {
            SettingsWindowController.shared.updateAppearance()
        }
        .onChange(of: search) {
            if !search.isEmpty, model.recording != nil { model.stopRecording() }
        }
    }

    private var isDark: Bool {
        let base = ThemeManager.shared.current.base
        return 0.2126 * base.r + 0.7152 * base.g + 0.0722 * base.b < 0.5
    }

    private var background: some View {
        ZStack {
            VisualEffectBlur(material: .underWindowBackground, blendingMode: .behindWindow)
            Palette.base.opacity(0.93)
            RadialGradient(colors: [Palette.accent.opacity(0.10), .clear], center: .topTrailing, startRadius: 0, endRadius: 520)
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var detail: some View {
        if let error = model.loadError {
            LoadErrorView(error: error) { model.reload() }
        } else if !search.trimmingCharacters(in: .whitespaces).isEmpty {
            SearchResultsPage(model: model, query: search) { target in
                search = ""
                section = target
            }
        } else {
            Group {
                switch section {
                case .general: GeneralPane(model: model)
                case .keybindings: KeybindingsPane(model: model) { showCheatSheet = true }
                case .commands: CommandsPane(model: model)
                case .rules: RulesPane(model: model)
                case .appearance: AppearancePane(model: model)
                case .bar: BarPane(model: model)
                }
            }
            .id(section)
            .transition(.opacity.combined(with: .offset(y: 6)))
        }
    }
}

private struct SettingsSidebar: View {
    @Binding var section: SettingsSection
    @Binding var search: String
    @Binding var showCheatSheet: Bool
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                TalysEggMark()
                    .stroke(LinearGradient(colors: [Palette.accent, Palette.secondary], startPoint: .top, endPoint: .bottom),
                            style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
                    .frame(width: 20, height: 24)
                Text("talys")
                    .font(.system(size: 19, weight: .heavy, design: .rounded))
                    .foregroundStyle(Palette.text)
                Text("settings")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.overlay0)
                    .padding(.top, 5)
            }
            .padding(.top, 44)
            .padding(.horizontal, 18)
            .padding(.bottom, 16)

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(searchFocused ? Palette.accent : Palette.overlay0)
                TextField("", text: $search, prompt: Text("Search settings").foregroundStyle(Palette.overlay0))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.text)
                    .focused($searchFocused)
                    .onExitCommand { search = ""; searchFocused = false }
                if search.isEmpty {
                    Text("⌘F")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(Palette.overlay0)
                } else {
                    Button { search = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(Palette.overlay0)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Palette.crust.opacity(0.7)))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(searchFocused ? Palette.accent.opacity(0.7) : Color.white.opacity(0.06), lineWidth: 1)
            )
            .padding(.horizontal, 12)
            .padding(.bottom, 14)
            .background {
                Button("") { searchFocused = true }
                    .keyboardShortcut("f", modifiers: .command)
                    .opacity(0)
            }

            VStack(spacing: 2) {
                ForEach(SettingsSection.allCases) { item in
                    SidebarItem(item: item, selected: search.isEmpty && section == item) {
                        search = ""
                        withAnimation(.easeOut(duration: 0.18)) { section = item }
                    }
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { showCheatSheet = true }
                } label: {
                    Label("Cheat Sheet", systemImage: "list.bullet.rectangle.portrait")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.themed())
                .keyboardShortcut("/", modifiers: .command)
                .help("All shortcuts at a glance (⌘/)")

                Button {
                    NSWorkspace.shared.open(ConfigManager.configURL)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "doc.text")
                        Text(ConfigManager.configURL.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(Palette.overlay0)
                }
                .buttonStyle(.plain)
                .help("Open config.toml in your editor")
            }
            .padding(14)
        }
        .frame(maxHeight: .infinity)
        .background(Palette.mantle.opacity(0.55))
        .background(alignment: .top) { WindowDragArea().frame(height: 40) }
    }
}

private struct SidebarItem: View {
    let item: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(selected ? Palette.crust : Palette.accent)
                    .frame(width: 26, height: 26)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? AnyShapeStyle(LinearGradient(colors: [Palette.accent, Palette.secondary],
                                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(Palette.accent.opacity(0.12)))
                    )
                Text(item.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Palette.text : Palette.subtext0)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(selected ? Palette.surface0.opacity(0.9) : hovering ? Palette.surface0.opacity(0.45) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private struct ConflictDialog: View {
    let model: SettingsModel
    let conflict: SettingsModel.Conflict

    var body: some View {
        ZStack {
            Color.black.opacity(0.4).ignoresSafeArea()
                .onTapGesture { model.conflict = nil }
            VStack(spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(Palette.yellow)
                HStack(spacing: 8) {
                    KeycapRow(caps: newCaps, size: 13)
                    Text("is already in use")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Palette.text)
                }
                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.subtext0)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Cancel") { model.conflict = nil }
                        .buttonStyle(.themed())
                        .keyboardShortcut(.cancelAction)
                    Button("Replace") { resolve(swap: false) }
                        .buttonStyle(.themed(.destructive))
                    Button("Swap") { resolve(swap: true) }
                        .buttonStyle(.themed(.primary))
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.top, 4)
            }
            .padding(24)
            .frame(width: 380)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Palette.base))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Palette.yellow.opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)
        }
    }

    private var newCaps: [String] {
        ConfigManager.parseKeyBinding(conflict.keys, mod: model.config.general.mod).map(Shortcut.caps) ?? [conflict.keys]
    }

    private var message: String {
        let owner = model.title(for: conflict.owner)
        let previous = model.display(for: conflict.target).text
        let swap = model.keys(for: conflict.target).isEmpty
            ? "Swap leaves it without a shortcut"
            : "Swap gives it \(previous)"
        return "It's assigned to \(owner). \(swap); Replace unbinds it."
    }

    private func resolve(swap: Bool) {
        model.resolve(conflict, swap: swap)
        model.conflict = nil
    }
}

private struct LoadErrorView: View {
    let error: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 34))
                .foregroundStyle(Palette.red)
            Text("config.toml has an error")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.text)
            Text("Fix it in a text editor, then reload. Settings won't overwrite a file it can't read.")
                .font(.system(size: 12.5))
                .foregroundStyle(Palette.subtext0)
                .multilineTextAlignment(.center)
            Text(error)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Palette.red)
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: 480, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.crust.opacity(0.7)))
            HStack {
                Button("Open config.toml") { NSWorkspace.shared.open(ConfigManager.configURL) }
                    .buttonStyle(.themed())
                Button("Reload", action: retry)
                    .buttonStyle(.themed(.primary))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search

private struct SearchResultsPage: View {
    let model: SettingsModel
    let query: String
    let open: (SettingsSection) -> Void

    private static let index: [(title: String, section: SettingsSection, keywords: String)] = [
        ("Layout", .general, "smart dwindle master stack scrolling monocle tiling"),
        ("Modifier key (mod)", .general, "mod alt option cmd command ctrl control hyper meh"),
        ("When a window doesn't fit", .general, "overflow too big float workspace"),
        ("Follow overflowing windows", .general, "overflow follow"),
        ("Config file", .general, "toml open finder editor path"),
        ("Theme", .appearance, "colors palette catppuccin tokyo night gruvbox rose pine nord"),
        ("Gap between windows", .appearance, "inner gaps spacing padding"),
        ("Gap at screen edges", .appearance, "outer gaps margin padding"),
        ("Active window border", .appearance, "borders outline highlight focus"),
        ("Border gradient", .appearance, "borders colors"),
        ("Border width", .appearance, "borders thickness"),
        ("Border corner radius", .appearance, "borders rounded corners"),
        ("Animate window movement", .appearance, "animations motion"),
        ("Animation duration", .appearance, "animations speed ms"),
        ("Menu bar", .bar, "macos talys hide menubar"),
        ("Show the Talys bar", .bar, "status bar enabled"),
        ("12-hour clock", .bar, "time am pm clock"),
        ("Bar height", .bar, "size"),
        ("Bar top margin", .bar, "position offset"),
        ("Bar side margin", .bar, "position width inset"),
        ("Gap below bar", .bar, "spacing"),
        ("Shell commands", .commands, "exec bind terminal launch app run"),
        ("Window rules", .rules, "float tile app workspace assign"),
        ("Keybindings", .keybindings, "shortcut hotkey keys rebind"),
    ]

    var body: some View {
        SettingsPage(title: "Search", subtitle: "Results for “\(query)”", symbol: "magnifyingglass") {
            if settings.isEmpty && actions.isEmpty && commands.isEmpty {
                Text("Nothing matches. Try a setting name, an action such as “focus”, or a key such as “tab”.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Palette.subtext0)
            }
            if !settings.isEmpty {
                SettingsCard(title: "Settings") {
                    ForEach(Array(settings.enumerated()), id: \.offset) { i, entry in
                        if i > 0 { RowDivider() }
                        SearchLink(title: entry.title, section: entry.section) { open(entry.section) }
                    }
                }
            }
            if !actions.isEmpty {
                SettingsCard(title: "Keybindings") {
                    ForEach(Array(actions.enumerated()), id: \.offset) { i, action in
                        if i > 0 { RowDivider() }
                        KeybindRow(model: model, name: action.name, title: action.title)
                    }
                }
            }
            if !commands.isEmpty {
                SettingsCard(title: "Commands") {
                    ForEach(Array(commands.enumerated()), id: \.offset) { i, index in
                        if i > 0 { RowDivider() }
                        SettingRow(title: model.config.bind[index].exec) {
                            ShortcutRecorder(model: model, target: .exec(index))
                        }
                    }
                }
            }
        }
    }

    private var q: String { query.trimmingCharacters(in: .whitespaces) }

    private func matches(_ text: String) -> Bool {
        text.localizedCaseInsensitiveContains(q) || FuzzyMatcher.score(q, in: text) != nil
    }

    private var settings: [(title: String, section: SettingsSection, keywords: String)] {
        Self.index.filter { matches($0.title) || $0.keywords.localizedCaseInsensitiveContains(q) || matches($0.section.title) }
    }

    /// Matches the action's name, its group, or the keys it's bound to ("tab", "⌥1").
    private var actions: [(name: String, title: String)] {
        SettingsModel.actionGroups.flatMap { group in
            group.actions.filter { action in
                let fullTitle = model.title(for: .action(action.name))
                return matches(fullTitle) || matches(group.title) || action.name.localizedCaseInsensitiveContains(q)
                    || model.keys(for: .action(action.name)).localizedCaseInsensitiveContains(q)
                    || model.display(for: .action(action.name)).text.localizedCaseInsensitiveContains(q)
            }
            .map { ($0.name, model.title(for: .action($0.name))) }
        }
    }

    private var commands: [Int] {
        model.config.bind.indices.filter { matches(model.config.bind[$0].exec) }
    }
}

private struct SearchLink: View {
    let title: String
    let section: SettingsSection
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 22)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                Spacer()
                Text(section.title)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.overlay0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(hovering ? Palette.accent : Palette.overlay0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(hovering ? Palette.surface1.opacity(0.25) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
