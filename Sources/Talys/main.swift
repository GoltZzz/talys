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
                }
            }
        }

        let config = ConfigManager.loadConfig()
        ConfigManager.applyConfig(config, to: tilingController, keyboard: keyboardManager)

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
        bar.onSwitchWorkspace = { ws in
            // Clicking the active workspace pill shouldn't bounce you elsewhere.
            TilingController.shared.switchWorkspace(ws, backAndForth: false)
        }
        self.barController = bar

        LauncherController.shared.commandProvider = { [weak self] in
            self?.launcherCommands() ?? []
        }

        SystemMetricsService.shared.start()
        lifecycleObserver.start()

        tilingController.retileAll()

        print("[Talys] Daemon running with workspaces 1..9, Omarchy floating status bar, animations, and window rules.")
    }

    private func reloadConfig() {
        let cfg = ConfigManager.loadConfig()
        ConfigManager.applyConfig(cfg, to: tilingController, keyboard: keyboardManager)
        barController?.updateConfig(cfg.bar)
        print("[Talys] Configuration reloaded.")
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
            .command("layout", "Cycle Layout", subtitle: "Dwindle → Master-Stack → Monocle", symbol: "square.split.bottomrightquarter") {
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
            .command("quit", "Quit Talys", subtitle: "Stop the window manager", symbol: "xmark.circle.fill") {
                NSApplication.shared.terminate(nil)
            },
        ]
        return items
    }

    func applicationWillTerminate(_ notification: Notification) {
        SystemMetricsService.shared.stop()
        barController?.hide()
        BorderController.shared.hide()
        lifecycleObserver.stop()
        keyboardManager.stop()
        WindowAnimator.shared.stop()
        tilingController.unparkAll()
        print("[Talys] Stopped.")
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

        let app = NSApplication.shared
        let del = AppDelegate()
        delegate = del
        app.delegate = del
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
