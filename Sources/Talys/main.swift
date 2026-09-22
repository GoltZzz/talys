import Cocoa
import CTalysEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusBarController: StatusBarController?
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
                }
            }
        }

        let config = ConfigManager.loadConfig()
        ConfigManager.applyConfig(config, to: tilingController, keyboard: keyboardManager)

        guard keyboardManager.start() else {
            print("[Talys] Could not start keyboard manager. Exiting.")
            exit(1)
        }

        let status = StatusBarController()
        status.onToggleEnabled = { enabled in
            TilingController.shared.isEnabled = enabled
            print("[Talys] Tiling \(enabled ? "enabled" : "disabled")")
        }
        status.onRetileAll = {
            TilingController.shared.retileAll()
        }
        status.onReloadConfig = { [weak self] in
            guard let self = self else { return }
            let cfg = ConfigManager.loadConfig()
            ConfigManager.applyConfig(cfg, to: self.tilingController, keyboard: self.keyboardManager)
            print("[Talys] Configuration reloaded.")
        }
        status.onSwitchWorkspace = { ws in
            TilingController.shared.switchWorkspace(ws)
        }
        self.statusBarController = status

        tilingController.onWorkspaceChanged = { [weak self] ws in
            self?.statusBarController?.updateActiveWorkspace(ws)
        }

        lifecycleObserver.start()

        tilingController.retileAll()

        print("[Talys] Daemon running with workspaces 1..9, animations, window rules, and menu bar item.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleObserver.stop()
        keyboardManager.stop()
        WindowAnimator.shared.stop()
        print("[Talys] Stopped.")
    }
}

@main
struct TalysApp {
    @MainActor static var delegate: AppDelegate?

    @MainActor
    static func main() {
        let app = NSApplication.shared
        let del = AppDelegate()
        delegate = del
        app.delegate = del
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
