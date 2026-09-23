import Cocoa
import SwiftUI

/// Borderless window that keeps its top edge fixed while SwiftUI grows or shrinks the content.
private final class AudioPanelWindow: NSPanel {
    var pinnedTop: CGFloat?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        var rect = frameRect
        if let pinnedTop { rect.origin.y = pinnedTop - rect.height }
        super.setFrame(rect, display: flag)
    }
}

/// Shows and dismisses the sound panel under the bar's volume item.
@MainActor
final class AudioPanelController {
    static let shared = AudioPanelController()

    private var window: AudioPanelWindow?
    private var monitors: [Any] = []
    /// Set when a click outside closed the panel, so the same click on the volume item doesn't reopen it.
    private var lastDismissal = Date.distantPast

    /// Padding the SwiftUI view leaves around the card for its shadow.
    private let shadowInset: CGFloat = 20

    private init() {}

    var isVisible: Bool { window != nil }

    /// Opens the panel centred on `anchorX`, with the card's top edge at `top`, or closes it if it's open.
    func toggle(anchorX: CGFloat, top: CGFloat, on screen: NSScreen?) {
        if isVisible {
            close()
        } else if Date().timeIntervalSince(lastDismissal) > 0.3 {
            show(anchorX: anchorX, top: top, on: screen)
        }
    }

    func show(anchorX: CGFloat, top: CGFloat, on screen: NSScreen?) {
        guard window == nil, let screen = screen ?? NSScreen.main else { return }

        let hosting = NSHostingView(rootView: AudioPanelView())
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize

        let window = AudioPanelWindow(
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
        window.makeKeyAndOrderFront(nil)

        InputLevelMeter.shared.start()
        AudioSourceMonitor.shared.start()
        installMonitors()
    }

    func close() {
        guard let window else { return }
        self.window = nil
        removeMonitors()
        InputLevelMeter.shared.stop()
        AudioSourceMonitor.shared.stop()

        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            window.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated { window.orderOut(nil) }
        })
    }

    private func installMonitors() {
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { _ in
            MainActor.assumeIsolated { AudioPanelController.shared.dismissFromOutside() }
        }) {
            monitors.append(global)
        }

        // Clicks in Talys's own windows (the bar) and Esc.
        if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { event in
            let isEsc = event.type == .keyDown && event.keyCode == 53
            let isKey = event.type == .keyDown
            let windowNumber = event.windowNumber
            let swallow = MainActor.assumeIsolated { () -> Bool in
                let controller = AudioPanelController.shared
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
        close()
    }
}
