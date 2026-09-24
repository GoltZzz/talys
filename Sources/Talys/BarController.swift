import Cocoa
import CoreAudio
import SwiftUI

@MainActor
public final class BarController: NSObject {
    private var panel: FloatingBarPanel?
    private var hostingView: NSHostingView<TalysBarView>?
    private var wallpaperView: WallpaperStripView?
    private var wallpaperTimer: Timer?
    private var barConfig: BarConfig

    public var onToggleEnabled: ((Bool) -> Void)?
    public var onReloadConfig: (() -> Void)?
    public var onRetileAll: (() -> Void)?
    public var onSwitchWorkspace: ((UInt8) -> Void)?
    public var onCycleLayout: (() -> Void)?
    public var onSelectTheme: ((String) -> Void)?
    /// Turns the Talys bar off and gives the macOS menu bar back.
    public var onRestoreMenuBar: (() -> Void)?
    public var onOpenSettings: (() -> Void)?
    /// Looks up the live key binding for an action so menu hints match the real hotkeys.
    public var bindingProvider: ((KeyAction) -> KeyBinding?)?

    public init(config: BarConfig = BarConfig()) {
        self.barConfig = config
        super.init()
        setupObservers()
        if barConfig.enabled {
            setupPanel()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    public func updateConfig(_ config: BarConfig) {
        self.barConfig = config
        if config.enabled {
            if panel == nil {
                setupPanel()
            } else {
                updatePanelFrame()
            }
        } else {
            panel?.orderOut(nil)
            panel = nil
        }
    }

    public func show() {
        panel?.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    /// Height of the strip the bar's window covers, measured down from the screen's top edge: the bar itself,
    /// or the macOS menu bar if that's taller (notched screens), so the menu bar's hover reveal stays hidden.
    static func coveredHeight(on screen: NSScreen, config: BarConfig) -> CGFloat {
        let menuBar = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top)
        return max(config.margin_top + config.height, menuBar)
    }

    private func panelRect(on screen: NSScreen) -> NSRect {
        let frame = screen.frame
        let height = Self.coveredHeight(on: screen, config: barConfig)
        return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }

    /// The bar's own area inside the panel, `margin_top` below the top edge.
    private func barRect(in panelRect: NSRect) -> NSRect {
        NSRect(x: 0, y: panelRect.height - barConfig.margin_top - barConfig.height,
               width: panelRect.width, height: barConfig.height)
    }

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }

        let rect = panelRect(on: screen)
        let newPanel = FloatingBarPanel(contentRect: rect)

        let barView = TalysBarView(
            onSwitchWorkspace: { [weak self] ws in
                self?.onSwitchWorkspace?(ws)
            },
            onCycleLayout: { [weak self] in
                self?.onCycleLayout?( )
            },
            onShowBrandMenu: { [weak self] in
                self?.showBrandMenu()
            },
            onShowVolumeMenu: { [weak self] in
                self?.showVolumeMenu()
            },
            onShowWiFiMenu: { [weak self] in
                self?.showWiFiMenu()
            }
        )

        let container = NSView(frame: NSRect(origin: .zero, size: rect.size))
        let wallpaper = WallpaperStripView(frame: container.bounds)
        wallpaper.autoresizingMask = [.width, .height]
        container.addSubview(wallpaper)

        let hosting = NSHostingView(rootView: barView)
        hosting.frame = barRect(in: rect)
        hosting.autoresizingMask = [.width, .minYMargin]
        container.addSubview(hosting)
        newPanel.contentView = container

        self.panel = newPanel
        self.hostingView = hosting
        self.wallpaperView = wallpaper

        newPanel.orderFrontRegardless()
        wallpaper.refresh()
        print("[BarController] Talys floating bar panel displayed (height: \(barConfig.height)pt)")
    }

    private func updatePanelFrame() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let rect = panelRect(on: screen)
        panel.setFrame(rect, display: false)
        hostingView?.frame = barRect(in: rect)
        wallpaperView?.refresh()
    }

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updatePanelFrame()
            }
        }
        // Each Space can have its own wallpaper.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.wallpaperView?.refresh()
            }
        }
        // macOS posts nothing public when the wallpaper changes, so check now and then.
        wallpaperTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.wallpaperView?.refresh()
            }
        }
    }

    public func showBrandMenu() {
        let menu = NSMenu(title: "Talys")

        let header = NSMenuItem(title: "Talys Window Manager", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        let isEnabled = TalysDesktopState.shared.isTilingEnabled
        let toggleItem = NSMenuItem(
            title: isEnabled ? "Disable Tiling" : "Enable Tiling",
            action: #selector(toggleEnabledClicked),
            keyEquivalent: ""
        )
        toggleItem.target = self
        menu.addItem(toggleItem)

        let menuBarItem = NSMenuItem(title: "Restore macOS Menu Bar", action: #selector(restoreMenuBarClicked), keyEquivalent: "")
        menuBarItem.target = self
        menu.addItem(menuBarItem)

        let retileItem = NSMenuItem(title: "Retile All", action: #selector(retileClicked), keyEquivalent: "")
        retileItem.target = self
        applyShortcut(for: .retile, to: retileItem)
        menu.addItem(retileItem)

        let cycleItem = NSMenuItem(title: "Cycle Layout", action: #selector(cycleLayoutClicked), keyEquivalent: "")
        cycleItem.target = self
        applyShortcut(for: .cycleLayout, to: cycleItem)
        menu.addItem(cycleItem)

        let wsMenu = NSMenu()
        for ws in 1...9 {
            let item = NSMenuItem(title: "Workspace \(ws)", action: #selector(workspaceClicked(_:)), keyEquivalent: "")
            item.tag = ws
            item.target = self
            applyShortcut(for: .switchWorkspace(UInt8(ws)), to: item)
            if ws == Int(TalysDesktopState.shared.activeWorkspace) {
                item.state = .on
            }
            wsMenu.addItem(item)
        }
        let wsItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        wsItem.submenu = wsMenu
        menu.addItem(wsItem)

        let themeMenu = NSMenu()
        let currentTheme = ThemeManager.shared.current.name
        for theme in ThemeManager.shared.availableThemes() {
            let item = NSMenuItem(title: theme.displayName, action: #selector(themeClicked(_:)), keyEquivalent: "")
            item.representedObject = theme.name
            item.target = self
            item.state = theme.name == currentTheme ? .on : .off
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Themes", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(settingsClicked), keyEquivalent: "")
        settingsItem.target = self
        applyShortcut(for: .openSettings, to: settingsItem)
        menu.addItem(settingsItem)

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigClicked), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let editConfigItem = NSMenuItem(title: "Edit Config File...", action: #selector(editConfigClicked), keyEquivalent: "")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Talys", action: #selector(quitClicked), keyEquivalent: "")
        quitItem.target = self
        menu.addItem(quitItem)

        // Show menu at the bottom edge of the Left Island / mouse location
        let mouseLocation = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: mouseLocation, in: nil)
    }

    /// Toggles the sound panel, centred under the pointer and hanging just below the bar.
    public func showVolumeMenu() {
        togglePopover(.sound)
    }

    /// Toggles the Wi-Fi panel, centred under the pointer and hanging just below the bar.
    public func showWiFiMenu() {
        togglePopover(.wifi)
    }

    private func togglePopover(_ kind: BarPopover) {
        let barBottom = panel.map { $0.frame.maxY - barConfig.margin_top - barConfig.height }
        let top = (barBottom ?? NSScreen.main?.frame.maxY ?? 0) - 6
        BarPopoverController.shared.toggle(kind, anchorX: NSEvent.mouseLocation.x, top: top, on: panel?.screen)
    }

    /// Shows the action's configured hotkey as the item's shortcut hint, or none if unbound.
    private func applyShortcut(for action: KeyAction, to item: NSMenuItem) {
        guard let binding = bindingProvider?(action),
              let key = Self.menuKeyEquivalent(for: binding.keyCode) else { return }
        var mask: NSEvent.ModifierFlags = []
        if binding.cmd { mask.insert(.command) }
        if binding.alt { mask.insert(.option) }
        if binding.ctrl { mask.insert(.control) }
        if binding.shift { mask.insert(.shift) }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    /// Maps a virtual key code to the string NSMenuItem needs to render it (⇥, ␣, ←, F1…).
    private static func menuKeyEquivalent(for keyCode: UInt16) -> String? {
        let special: [UInt16: Int] = [
            48: 0x09, 49: 0x20, 36: 0x0D, 53: 0x1B, 51: 0x08,
            123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
            125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
            122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey,
            96: NSF5FunctionKey, 97: NSF6FunctionKey, 98: NSF7FunctionKey, 100: NSF8FunctionKey,
            101: NSF9FunctionKey, 109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey,
        ]
        if let scalar = special[keyCode].flatMap(UnicodeScalar.init) {
            return String(Character(scalar))
        }
        let printable = "abcdefghijklmnopqrstuvwxyz0123456789-=[];',./\\`".map(String.init)
        return printable.first { ConfigManager.keyCodeForString($0) == keyCode }
    }

    @objc private func toggleEnabledClicked() {
        let newState = !TalysDesktopState.shared.isTilingEnabled
        TalysDesktopState.shared.isTilingEnabled = newState
        onToggleEnabled?(newState)
    }

    @objc private func restoreMenuBarClicked() {
        onRestoreMenuBar?()
    }

    @objc private func retileClicked() {
        onRetileAll?()
    }

    @objc private func cycleLayoutClicked() {
        onCycleLayout?()
    }

    @objc private func workspaceClicked(_ sender: NSMenuItem) {
        let ws = UInt8(sender.tag)
        onSwitchWorkspace?(ws)
    }

    @objc private func themeClicked(_ sender: NSMenuItem) {
        if let name = sender.representedObject as? String {
            onSelectTheme?(name)
        }
    }

    @objc private func settingsClicked() {
        onOpenSettings?()
    }

    @objc private func reloadConfigClicked() {
        onReloadConfig?()
    }

    @objc private func editConfigClicked() {
        let url = ConfigManager.configURL
        NSWorkspace.shared.open(url)
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
