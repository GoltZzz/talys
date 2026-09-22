import Cocoa

@MainActor
public final class StatusBarController: NSObject {
    private var statusItem: NSStatusItem!
    private var enabledMenuItem: NSMenuItem!
    private var workspaceMenuItems: [UInt8: NSMenuItem] = [:]
    private var activeWorkspace: UInt8 = 1

    public var onToggleEnabled: ((Bool) -> Void)?
    public var onReloadConfig: (() -> Void)?
    public var onRetileAll: (() -> Void)?
    public var onSwitchWorkspace: ((UInt8) -> Void)?

    public override init() {
        super.init()
        setupStatusItem()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateButtonTitle()

        let menu = NSMenu()

        let headerItem = NSMenuItem(title: "Talys Window Manager", action: nil, keyEquivalent: "")
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        enabledMenuItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabledClicked), keyEquivalent: "")
        enabledMenuItem.target = self
        enabledMenuItem.state = .on
        menu.addItem(enabledMenuItem)

        let wsMenu = NSMenu()
        for ws in 1...9 {
            let item = NSMenuItem(title: "Workspace \(ws)", action: #selector(workspaceClicked(_:)), keyEquivalent: "\(ws)")
            item.tag = Int(ws)
            item.target = self
            if ws == 1 { item.state = .on }
            workspaceMenuItems[UInt8(ws)] = item
            wsMenu.addItem(item)
        }
        let wsSubmenuItem = NSMenuItem(title: "Workspaces", action: nil, keyEquivalent: "")
        wsSubmenuItem.submenu = wsMenu
        menu.addItem(wsSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        let retileItem = NSMenuItem(title: "Retile All", action: #selector(retileClicked), keyEquivalent: "r")
        retileItem.target = self
        menu.addItem(retileItem)

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

        statusItem.menu = menu
    }

    public func updateActiveWorkspace(_ ws: UInt8) {
        self.activeWorkspace = ws
        updateButtonTitle()
        for (num, item) in workspaceMenuItems {
            item.state = (num == ws) ? .on : .off
        }
    }

    private func updateButtonTitle() {
        if let button = statusItem.button {
            button.imagePosition = .imageLeading
            if let image = NSImage(systemSymbolName: "rectangle.split.2x1", accessibilityDescription: "Talys") {
                image.isTemplate = true
                button.image = image
            }
            button.title = " \(activeWorkspace)"
        }
    }

    public func setEnabledState(_ enabled: Bool) {
        enabledMenuItem.state = enabled ? .on : .off
    }

    @objc private func toggleEnabledClicked() {
        let newState = enabledMenuItem.state != .on
        enabledMenuItem.state = newState ? .on : .off
        onToggleEnabled?(newState)
    }

    @objc private func workspaceClicked(_ sender: NSMenuItem) {
        let ws = UInt8(sender.tag)
        onSwitchWorkspace?(ws)
    }

    @objc private func retileClicked() {
        onRetileAll?()
    }

    @objc private func reloadConfigClicked() {
        onReloadConfig?()
    }

    @objc private func editConfigClicked() {
        let url = ConfigManager.configURL
        if !FileManager.default.fileExists(atPath: url.path) {
            _ = ConfigManager.loadConfig()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func quitClicked() {
        NSApplication.shared.terminate(nil)
    }
}
