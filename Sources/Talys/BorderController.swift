import Cocoa
import QuartzCore
@preconcurrency import ApplicationServices

/// Draws a Hyprland-style border around the focused managed window using a click-through overlay window.
@MainActor
public final class BorderController {
    public static let shared = BorderController()

    private var config = BordersConfig()
    private var window: NSWindow?
    private let gradientLayer = CAGradientLayer()
    private let maskLayer = CAShapeLayer()
    private var target: AXUIElement?
    private var lastFrame: CGRect = .null

    private init() {
        ThemeManager.shared.onThemeChanged = { [weak self] _ in
            self?.applyColors()
        }
    }

    public func updateConfig(_ config: BordersConfig) {
        self.config = config
        applyColors()
        lastFrame = .null
        refresh()
    }

    public func setTarget(_ element: AXUIElement?) {
        target = element
        lastFrame = .null
        refresh()
    }

    public func isTarget(_ element: AXUIElement) -> Bool {
        guard let target else { return false }
        return CFEqual(target, element)
    }

    public func clearTarget(ifMatching element: AXUIElement) {
        if isTarget(element) { setTarget(nil) }
    }

    /// Re-reads the target's frame; cheap enough to call on every animation step and move/resize event.
    public func refresh() {
        guard config.enabled,
              TalysDesktopState.shared.isTilingEnabled,
              let target,
              let axFrame = AccessibilityHelper.getFrame(for: target),
              !ParkingLot.isParked(axFrame),
              axFrame.width > 1, axFrame.height > 1
        else {
            hide()
            return
        }
        show(axFrame: axFrame)
    }

    public func hide() {
        window?.orderOut(nil)
        lastFrame = .null
    }

    private func show(axFrame: CGRect) {
        let window = self.window ?? makeWindow()
        let width = CGFloat(config.width)

        // AX frames are top-left origin on the primary screen; Cocoa is bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoaFrame = CGRect(
            x: axFrame.origin.x,
            y: primaryHeight - axFrame.origin.y - axFrame.height,
            width: axFrame.width,
            height: axFrame.height
        ).insetBy(dx: -width, dy: -width)

        if cocoaFrame != lastFrame {
            lastFrame = cocoaFrame
            window.setFrame(cocoaFrame, display: false)

            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let bounds = CGRect(origin: .zero, size: cocoaFrame.size)
            gradientLayer.frame = bounds
            maskLayer.frame = bounds
            let radius = CGFloat(config.radius) + width / 2
            maskLayer.path = CGPath(
                roundedRect: bounds.insetBy(dx: width / 2, dy: width / 2),
                cornerWidth: radius, cornerHeight: radius, transform: nil
            )
            maskLayer.lineWidth = width
            CATransaction.commit()
        }

        if !window.isVisible {
            window.orderFrontRegardless()
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.ignoresMouseEvents = true
        w.level = .floating
        w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .transient, .fullScreenAuxiliary]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.addSublayer(gradientLayer)
        w.contentView = view

        maskLayer.fillColor = nil
        maskLayer.strokeColor = NSColor.black.cgColor
        gradientLayer.mask = maskLayer
        gradientLayer.startPoint = CGPoint(x: 0, y: 1)
        gradientLayer.endPoint = CGPoint(x: 1, y: 0)

        self.window = w
        applyColors()
        return w
    }

    private func applyColors() {
        let theme = ThemeManager.shared.current
        let second = config.gradient ? theme.borderActive2 : theme.borderActive
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientLayer.colors = [theme.borderActive.cgColor, second.cgColor]
        CATransaction.commit()
    }
}
