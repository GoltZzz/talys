import Cocoa
import CTalysEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var barController: BarController?
    private let tilingController = TilingController.shared
    private let keyboardManager = KeyboardManager()
    private let lifecycleObserver = AppLifecycleObserver()

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("=== Talys macOS Window Manager v0.3 ===")

        if !ensureAccessibilityPermissions(prompt: true) {
            print("[Talys] Accessibility permission not yet granted. Please grant access in System Settings > Privacy & Security > Accessibility and relaunch.")
            exit(1)
        }
        print("[Talys] Accessibility permissions verified.")

        keyboardManager.onAction = { action in
            Task { @MainActor in
                let tc = TilingController.shared
                switch action {
                case .focusDirection(let dir):
                    tc.focusDirection(dir)
                case .swapDirection(let dir):
                    tc.swapDirection(dir)
                case .toggleFloat:
                    tc.toggleFloat()
                case .closeWindow:
                    tc.closeFocusedWindow()
                case .retile:
                    tc.retileAll()
                case .resize(let delta):
                    tc.resizeFocused(delta)
                case .toggleFullscreen:
                    tc.toggleFullscreen()
                case .cycleLayout:
                    tc.cycleLayout()
                case .switchWorkspace(let ws):
                    tc.switchWorkspace(ws)
                case .moveToWorkspace(let ws):
                    tc.moveToWorkspace(ws)
                case .exec(let command):
                    ShellRunner.run(command)
                case .toggleLauncher:
                    LauncherController.shared.toggle()
                case .toggleScratchpad:
                    tc.toggleScratchpad()
                case .moveToScratchpad:
                    tc.moveFocusedToScratchpad()
                case .cycleTheme:
                    ThemeManager.shared.cycle()
                case .toggleAnimations:
                    tc.toggleAnimations()
                case .cycleColumnWidth:
                    tc.cycleColumnWidth()
                case .consumeOrExpel(let dir):
                    tc.consumeOrExpel(dir)
                }
            }
        }

        SpotlightTakeover.shared.prepareOnLaunch()

        let config = ConfigManager.loadConfig()
        applyConfig(config)

        guard keyboardManager.start() else {
            print("[Talys] Could not start keyboard manager. Exiting.")
            exit(1)
        }

        let bar = BarController(config: config.bar)
        bar.onToggleEnabled = { enabled in
            TilingController.shared.isEnabled = enabled
            print("[Talys] Tiling \(enabled ? "enabled" : "disabled")")
        }
        bar.onRetileAll = {
            TilingController.shared.retileAll()
        }
        bar.onCycleLayout = {
            TilingController.shared.cycleLayout()
        }
        bar.onReloadConfig = { [weak self] in
            self?.reloadConfig()
        }
        bar.onSelectTheme = { [weak self] name in
            self?.selectTheme(name)
        }
        bar.onToggleHideMenuBar = { hide in
            MenuBarAutoHide.shared.apply(enabled: hide)
            ConfigManager.persistHideMenuBar(hide)
        }
        bar.onSwitchWorkspace = { ws in
            // Clicking the active workspace pill shouldn't bounce you elsewhere.
            TilingController.shared.switchWorkspace(ws, backAndForth: false)
        }
        bar.bindingProvider = { [weak self] action in
            self?.keyboardManager.bindings.first { $0.value.description == action.description }?.key
        }
        self.barController = bar

        LauncherController.shared.commandProvider = { [weak self] in
            self?.launcherCommands() ?? []
        }

        SystemMetricsService.shared.start()
        AudioController.shared.start()
        lifecycleObserver.start()

        SpaceMonitor.shared.onAwayChanged = { away in
            TilingController.shared.setAwayFromHome(away)
        }
        SpaceMonitor.shared.start()
        SpaceMonitor.shared.noticeExtraSpacesIfNeeded()

        tilingController.retileAll()

        print("[Talys] Daemon running with workspaces 1..9, Omarchy floating status bar, animations, and window rules.")
    }

    private func reloadConfig() {
        let cfg = ConfigManager.loadConfig()
        applyConfig(cfg)
        barController?.updateConfig(cfg.bar)
        print("[Talys] Configuration reloaded.")
    }

    private func applyConfig(_ config: TalysConfig) {
        ConfigManager.applyConfig(config, to: tilingController, keyboard: keyboardManager)
        SpotlightTakeover.shared.adjustBindings(&keyboardManager.bindings, config: config)
        MissionControlShortcuts.shared.sync(with: keyboardManager.bindings)
        MenuBarAutoHide.shared.apply(enabled: config.bar.enabled && config.bar.hide_macos_menu_bar)
    }

    private func selectTheme(_ name: String) {
        if ThemeManager.shared.apply(named: name) {
            ConfigManager.persistTheme(name)
        }
    }

    private func launcherCommands() -> [LauncherItem] {
        let tc = TilingController.shared
        let current = ThemeManager.shared.current.name
        var items: [LauncherItem] = ThemeManager.shared.availableThemes().map { theme in
            .command("theme.\(theme.name)", "Theme: \(theme.displayName)",
                     subtitle: theme.name == current ? "Current theme" : "Switch theme",
                     symbol: "paintpalette.fill") { [weak self] in
                self?.selectTheme(theme.name)
            }
        }
        items += [
            .command("scratchpad", "Toggle Scratchpad", subtitle: "Show or hide stashed windows", symbol: "tray.full.fill") {
                tc.toggleScratchpad()
            },
            .command("retile", "Retile All Windows", subtitle: "Re-scan and tile the current workspace", symbol: "square.grid.2x2.fill") {
                tc.retileAll()
            },
            .command("layout", "Cycle Layout", subtitle: "Dwindle → Master-Stack → Scrolling → Monocle", symbol: "square.split.bottomrightquarter") {
                tc.cycleLayout()
            },
            .command("tiling", tc.isEnabled ? "Disable Tiling" : "Enable Tiling", subtitle: "Toggle the tiling engine", symbol: "power") {
                tc.isEnabled.toggle()
            },
            .command("reload", "Reload Config", subtitle: ConfigManager.configURL.path, symbol: "arrow.clockwise") { [weak self] in
                self?.reloadConfig()
            },
            .command("edit", "Edit Config", subtitle: ConfigManager.configURL.path, symbol: "doc.text.fill") {
                NSWorkspace.shared.open(ConfigManager.configURL)
            },
            spotlightCommand(),
        ]
        if let missionControl = missionControlCommand() {
            items.append(missionControl)
        }
        items += [
            .command("quit", "Quit Talys", subtitle: "Stop the window manager", symbol: "xmark.circle.fill") {
                NSApplication.shared.terminate(nil)
            },
        ]
        return items
    }

    private func spotlightCommand() -> LauncherItem {
        let takeover = SpotlightTakeover.shared
        if takeover.isAccepted {
            return .command("spotlight", "Restore Spotlight Shortcut", subtitle: "Give Cmd+Space back to Spotlight", symbol: "magnifyingglass") { [weak self] in
                takeover.release()
                self?.reloadConfig()
            }
        }
        return .command("spotlight", "Use Cmd+Space for Launcher", subtitle: "Take Cmd+Space over from Spotlight", symbol: "command") { [weak self] in
            takeover.enable()
            self?.reloadConfig()
        }
    }

    /// Offered only when there's something to hand back or take over.
    private func missionControlCommand() -> LauncherItem? {
        let shortcuts = MissionControlShortcuts.shared
        if shortcuts.isAccepted {
            return .command("missioncontrol", "Restore Mission Control Shortcuts", subtitle: "Give clashing Ctrl shortcuts back to macOS", symbol: "rectangle.3.group") {
                shortcuts.release()
            }
        }
        guard shortcuts.hasClashes else { return nil }
        return .command("missioncontrol", "Turn Off Clashing Mission Control Shortcuts", subtitle: "While Talys runs; restored on quit", symbol: "rectangle.3.group") {
            shortcuts.enable()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        SpotlightTakeover.shared.restore()
        MissionControlShortcuts.shared.restore()
        MenuBarAutoHide.shared.restore()
        SpaceMonitor.shared.stop()
        SystemMetricsService.shared.stop()
        barController?.hide()
        BorderController.shared.hide()
        lifecycleObserver.stop()
        keyboardManager.stop()
        WindowAnimator.shared.stop()
        tilingController.unparkAll()
        print("[Talys] Stopped.")
        LogFile.shared.stop()
    }
}

@main
struct TalysApp {
    @MainActor static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--check-config") {
            ConfigManager.checkConfig(path: args.indices.contains(i + 1) ? args[i + 1] : nil)
            return
        }
        if args.contains("--restore-shortcuts") {
            // For uninstalling after a crash or force quit, when no quit ran to give the shortcuts back.
            SpotlightTakeover.shared.restore()
            MissionControlShortcuts.shared.restore()
            MenuBarAutoHide.shared.restore()
            return
        }

        LogFile.shared.start()
        let app = NSApplication.shared
        let del = AppDelegate()
        delegate = del
        app.delegate = del
        app.setActivationPolicy(.accessory)
        installQuitSignalHandlers()
        app.run()
    }

    /// Ctrl+C, `kill` and logout send signals that skip `applicationWillTerminate`; route them through a normal
    /// quit so system shortcuts and hidden windows are given back.
    @MainActor
    private static var signalSources: [DispatchSourceSignal] = []

    @MainActor
    private static func installQuitSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApplication.shared.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }
}
