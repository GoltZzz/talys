import Cocoa
import SwiftUI

@MainActor
public final class BarController: NSObject {
    private var panel: FloatingBarPanel?
    private var hostingView: NSHostingView<OmarchyBarView>?
    private var barConfig: BarConfig

    public var onToggleEnabled: ((Bool) -> Void)?
    public var onReloadConfig: (() -> Void)?
    public var onRetileAll: (() -> Void)?
    public var onSwitchWorkspace: ((UInt8) -> Void)?
    public var onCycleLayout: (() -> Void)?
    public var onSelectTheme: ((String) -> Void)?

    public init(config: BarConfig = BarConfig()) {
        self.barConfig = config
        super.init()
        if barConfig.enabled {
            setupPanel()
            setupScreenChangeObserver()
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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

    private func setupPanel() {
        guard let screen = NSScreen.main else { return }

        let screenFrame = screen.frame
        let panelHeight = barConfig.height
        let marginTop = barConfig.margin_top

        // Top of screen in Cocoa coordinates (origin at bottom-left)
        let panelY = screenFrame.origin.y + screenFrame.height - (marginTop + panelHeight)
        let panelRect = NSRect(
            x: screenFrame.origin.x,
            y: panelY,
            width: screenFrame.width,
            height: panelHeight
        )

        let newPanel = FloatingBarPanel(contentRect: panelRect)

        let barView = OmarchyBarView(
            onSwitchWorkspace: { [weak self] ws in
                self?.onSwitchWorkspace?(ws)
            },
            onCycleLayout: { [weak self] in
                self?.onCycleLayout?( )
            },
            onShowBrandMenu: { [weak self] in
                self?.showBrandMenu()
            }
        )

        let hosting = NSHostingView(rootView: barView)
        hosting.autoresizingMask = [.width, .height]
        newPanel.contentView = hosting

        self.panel = newPanel
        self.hostingView = hosting

        newPanel.orderFrontRegardless()
        print("[BarController] Omarchy floating bar panel displayed (height: \(panelHeight)pt)")
    }

    private func updatePanelFrame() {
        guard let panel = panel, let screen = NSScreen.main else { return }
        let screenFrame = screen.frame
        let panelHeight = barConfig.height
        let marginTop = barConfig.margin_top
        let panelY = screenFrame.origin.y + screenFrame.height - (marginTop + panelHeight)
        let panelRect = NSRect(
            x: screenFrame.origin.x,
            y: panelY,
            width: screenFrame.width,
            height: panelHeight
        )
        panel.setFrame(panelRect, display: true)
    }

    private func setupScreenChangeObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.updatePanelFrame()
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

        let retileItem = NSMenuItem(title: "Retile All", action: #selector(retileClicked), keyEquivalent: "r")
        retileItem.target = self
        menu.addItem(retileItem)

        let cycleItem = NSMenuItem(title: "Cycle Layout", action: #selector(cycleLayoutClicked), keyEquivalent: "")
        cycleItem.target = self
        menu.addItem(cycleItem)

        let wsMenu = NSMenu()
        for ws in 1...9 {
            let item = NSMenuItem(title: "Workspace \(ws)", action: #selector(workspaceClicked(_:)), keyEquivalent: "\(ws)")
            item.tag = ws
            item.target = self
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

        let reloadItem = NSMenuItem(title: "Reload Config", action: #selector(reloadConfigClicked), keyEquivalent: "")
        reloadItem.target = self
        menu.addItem(reloadItem)

        let editConfigItem = NSMenuItem(title: "Edit Config File...", action: #selector(editConfigClicked), keyEquivalent: "")
        editConfigItem.target = self
        menu.addItem(editConfigItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit Talys", action: #selector(quitClicked), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        // Show menu at the bottom edge of the Left Island / mouse location
        let mouseLocation = NSEvent.mouseLocation
        menu.popUp(positioning: nil, at: mouseLocation, in: nil)
    }

    @objc private func toggleEnabledClicked() {
        let newState = !TalysDesktopState.shared.isTilingEnabled
        TalysDesktopState.shared.isTilingEnabled = newState
        onToggleEnabled?(newState)
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
