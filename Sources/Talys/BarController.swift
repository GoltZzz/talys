import Cocoa
import CoreAudio
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
    public var onToggleHideMenuBar: ((Bool) -> Void)?
    /// Looks up the live key binding for an action so menu hints match the real hotkeys.
    public var bindingProvider: ((KeyAction) -> KeyBinding?)?

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
            },
            onShowVolumeMenu: { [weak self] in
                self?.showVolumeMenu()
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

        let menuBarItem = NSMenuItem(title: "Hide macOS Menu Bar", action: #selector(toggleHideMenuBarClicked), keyEquivalent: "")
        menuBarItem.target = self
        menuBarItem.state = barConfig.hide_macos_menu_bar ? .on : .off
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

    public func showVolumeMenu() {
        let state = TalysDesktopState.shared
        let menu = NSMenu(title: "Sound")

        let header = NSMenuItem(title: state.outputDeviceName.isEmpty ? "Sound" : state.outputDeviceName, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        let sliderItem = NSMenuItem()
        sliderItem.view = makeVolumeSliderView(value: Double(state.volumePercent))
        menu.addItem(sliderItem)

        let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMuteClicked), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = state.isMuted ? .on : .off
        menu.addItem(muteItem)

        if state.outputDevices.count > 1 {
            menu.addItem(NSMenuItem.separator())
            let outputHeader = NSMenuItem(title: "Output", action: nil, keyEquivalent: "")
            outputHeader.isEnabled = false
            menu.addItem(outputHeader)
            for device in state.outputDevices {
                let item = NSMenuItem(title: device.name, action: #selector(outputDeviceClicked(_:)), keyEquivalent: "")
                item.target = self
                item.tag = Int(device.id)
                item.state = device.name == state.outputDeviceName ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(NSMenuItem.separator())
        let settingsItem = NSMenuItem(title: "Sound Settings...", action: #selector(soundSettingsClicked), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func makeVolumeSliderView(value: Double) -> NSView {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 30))

        let low = NSImageView(image: NSImage(systemSymbolName: "speaker.fill", accessibilityDescription: nil) ?? NSImage())
        low.contentTintColor = .secondaryLabelColor
        low.frame = NSRect(x: 16, y: 7, width: 14, height: 16)
        container.addSubview(low)

        let slider = NSSlider(value: value, minValue: 0, maxValue: 100, target: self, action: #selector(volumeSliderChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        slider.frame = NSRect(x: 36, y: 5, width: 168, height: 20)
        container.addSubview(slider)

        let high = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill", accessibilityDescription: nil) ?? NSImage())
        high.contentTintColor = .secondaryLabelColor
        high.frame = NSRect(x: 208, y: 7, width: 20, height: 16)
        container.addSubview(high)

        return container
    }

    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        AudioController.shared.setVolume(Float(sender.doubleValue / 100))
    }

    @objc private func toggleMuteClicked() {
        AudioController.shared.toggleMute()
    }

    @objc private func outputDeviceClicked(_ sender: NSMenuItem) {
        AudioController.shared.selectOutput(AudioDeviceID(sender.tag))
    }

    @objc private func soundSettingsClicked() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
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

    @objc private func toggleHideMenuBarClicked() {
        barConfig.hide_macos_menu_bar.toggle()
        onToggleHideMenuBar?(barConfig.hide_macos_menu_bar)
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
