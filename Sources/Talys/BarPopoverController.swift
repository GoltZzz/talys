import Cocoa
import SwiftUI

/// The drop-down panels that hang off bar items. Only one is open at a time.
enum BarPopover {
    case sound
    case wifi
}

/// Borderless window that keeps its top edge fixed while SwiftUI grows or shrinks the content.
private final class BarPopoverWindow: NSPanel {
    var pinnedTop: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let pinnedTop { rect.origin.y = pinnedTop - rect.height }
        super.setFrame(rect, display: flag)
    }

    /// NSHostingView resizes the window through here when content grows after the first layout
    /// (device and network lists arriving), which would otherwise keep the bottom edge fixed.
    override func setContentSize(_ size: NSSize) {
        guard pinnedTop != nil else { return super.setContentSize(size) }
        setFrame(frameRect(forContentRect: NSRect(origin: frame.origin, size: size)), display: true)
    }

    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        var rect = frameRect
        if let pinnedTop { rect.origin.y = pinnedTop - rect.height }
        super.setFrame(rect, display: displayFlag, animate: animateFlag)
    }
}

/// Shows and dismisses the bar's drop-down panels (sound, Wi-Fi) under their items.
@MainActor
final class BarPopoverController {
    static let shared = BarPopoverController()

    private var window: BarPopoverWindow?
    private(set) var current: BarPopover?
    private var monitors: [Any] = []
    /// Set when a click outside closed a panel, so the same click on its bar item doesn't reopen it.
    private var lastDismissal = Date.distantPast
    private var lastDismissed: BarPopover?

    /// Padding the SwiftUI view leaves around the card for its shadow.
    private let shadowInset: CGFloat = 20

    private init() {}

    var isVisible: Bool { window != nil }

    /// Opens `kind` centred on `anchorX`, with the card's top edge at `top`, or closes it if it's already open.
    /// Opening one panel while another is open swaps them.
    func toggle(_ kind: BarPopover, anchorX: CGFloat, top: CGFloat, on screen: NSScreen?) {
        if current == kind {
            close()
            return
        }
        // The click on this item already closed it via the outside-click monitor; don't bounce it back open.
        if lastDismissed == kind, Date().timeIntervalSince(lastDismissal) < 0.3 { return }
        close(animated: false)
        show(kind, anchorX: anchorX, top: top, on: screen)
    }

    func show(_ kind: BarPopover, anchorX: CGFloat, top: CGFloat, on screen: NSScreen?) {
        guard window == nil, let screen = screen ?? NSScreen.main else { return }

        // Room below the card's top edge, so tall panels can cap their scrolling lists to fit.
        let availableHeight = top - screen.visibleFrame.minY - 8
        let hosting = NSHostingView(rootView: content(for: kind, availableHeight: availableHeight))
        // Min/max size ties the window to the content, so it resizes as details and lists load.
        hosting.sizingOptions = [.minSize, .intrinsicContentSize, .maxSize]
        let size = hosting.fittingSize

        let window = BarPopoverWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.level = .popUpMenu
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.contentView = hosting

        // Keep the card on screen; the window extends past it by the shadow inset on every side.
        let visible = screen.frame
        let margin: CGFloat = 8
        let minX = visible.minX + margin - shadowInset
        let maxX = visible.maxX - margin + shadowInset - size.width
        let x = min(max(anchorX - size.width / 2, minX), maxX)
        let windowTop = top + shadowInset
        window.pinnedTop = windowTop
        window.setFrame(NSRect(x: x, y: windowTop - size.height, width: size.width, height: size.height), display: false)

        self.window = window
        self.current = kind
        window.makeKeyAndOrderFront(nil)

        didOpen(kind)
        installMonitors()
    }

    func close(animated: Bool = true) {
        guard let window, let kind = current else { return }
        self.window = nil
        self.current = nil
        removeMonitors()
        didClose(kind)

        guard animated else {
            window.orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    // MARK: - Per-panel wiring

    private func content(for kind: BarPopover, availableHeight: CGFloat) -> AnyView {
        switch kind {
        case .sound: AnyView(AudioPanelView())
        case .wifi: AnyView(WiFiPanelView(availableHeight: availableHeight))
        }
    }

    private func didOpen(_ kind: BarPopover) {
        switch kind {
        case .sound:
            InputLevelMeter.shared.start()
            AudioSourceMonitor.shared.start()
        case .wifi:
            WiFiController.shared.start()
        }
    }

    private func didClose(_ kind: BarPopover) {
        switch kind {
        case .sound:
            InputLevelMeter.shared.stop()
            AudioSourceMonitor.shared.stop()
        case .wifi:
            WiFiController.shared.stop()
        }
    }

    // MARK: - Dismissal

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated { BarPopoverController.shared.dismissFromOutside() }
        }) {
            monitors.append(global)
        }

        // Clicks in Talys's own windows (the bar) and Esc.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { event in
            let isEsc = event.type == .keyDown && event.keyCode == 53
            let isKey = event.type == .keyDown
            let windowNumber = event.windowNumber
            let swallow = MainActor.assumeIsolated { () -> Bool in
                let controller = BarPopoverController.shared
                if isKey {
                    if isEsc { controller.close() }
                    return isEsc
                }
                if windowNumber != controller.window?.windowNumber { controller.dismissFromOutside() }
                return false
            }
            return swallow ? nil : event
        }) {
            monitors.append(local)
        }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    private func dismissFromOutside() {
        lastDismissal = Date()
        lastDismissed = current
        close()
    }
}
