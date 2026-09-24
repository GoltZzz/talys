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
    /// Where the target was just snapped to. Apps apply AX moves a beat late, so until the window reports
    /// this frame (or the grace period ends) the border draws here instead of at the stale frame.
    private var expected: (frame: CGRect, until: TimeInterval)?
    private static let expectGrace: TimeInterval = 0.4

    private init() {
        ThemeManager.shared.onThemeChanged = { [weak self] _ in
            self?.applyColors()
        }
        // macOS barely sends AX move events during a live drag, so follow the mouse instead.
        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]) { event in
            MainActor.assumeIsolated { BorderController.shared.handleMouse(event.type) }
        }
    }

    /// Where the target and the mouse were when the button went down; `moving` once the drag turned out to
    /// move the window (not resize it or select text in it).
    private var drag: (element: AXUIElement, frame: CGRect, mouse: CGPoint, moving: Bool)?

    private func handleMouse(_ type: NSEvent.EventType) {
        let mouse = NSEvent.mouseLocation
        switch type {
        case .leftMouseDown:
            drag = nil
            seedDrag(mouse)
        case .leftMouseDragged:
            expected = nil
            // Clicking an unfocused window moves the border to it only after the button went down.
            if let target, let current = drag, !current.moving, !CFEqual(current.element, target) {
                seedDrag(mouse)
            }
            guard var drag else { return refresh() }
            if !drag.moving {
                // AX answers a beat late, so only use it to learn that the window is being moved.
                guard let target, let now = AccessibilityHelper.getFrame(for: target),
                      now.origin != drag.frame.origin, abs(now.width - drag.frame.width) < 1,
                      abs(now.height - drag.frame.height) < 1 else { return refresh() }
                drag.moving = true
                self.drag = drag
            }
            // The window server moves the window exactly with the cursor; Cocoa's y axis points up, AX's down.
            let frame = drag.frame.offsetBy(dx: mouse.x - drag.mouse.x, dy: drag.mouse.y - mouse.y)
            guard config.enabled, TalysDesktopState.shared.isTilingEnabled else { return hide() }
            show(axFrame: frame)
        case .leftMouseUp:
            drag = nil
            refresh()
            // Catch the window's settled frame (a tiling snap-back, or an app that reports late).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        default:
            break
        }
    }

    private func seedDrag(_ mouse: CGPoint) {
        guard let target, let frame = AccessibilityHelper.getFrame(for: target) else { return }
        drag = (target, frame, mouse, false)
    }

    public func updateConfig(_ config: BordersConfig) {
        self.config = config
        applyColors()
        lastFrame = .null
        refresh()
    }

    public func setTarget(_ element: AXUIElement?, expectedFrame: CGRect? = nil) {
        target = element
        expected = expectedFrame.map { ($0, ProcessInfo.processInfo.systemUptime + Self.expectGrace) }
        lastFrame = .null
        refresh()
        if expected != nil {
            // Catch apps that never send a move event after settling.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.expectGrace + 0.02) { [weak self] in
                MainActor.assumeIsolated { self?.refresh() }
            }
        }
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
              let frame = currentFrame(of: target),
              !ParkingLot.isParked(frame),
              frame.width > 1, frame.height > 1
        else {
            hide()
            return
        }
        show(axFrame: frame)
    }

    private func currentFrame(of target: AXUIElement) -> CGRect? {
        let actual = AccessibilityHelper.getFrame(for: target)
        guard let expected else { return actual }
        let arrived = actual.map {
            max(abs($0.minX - expected.frame.minX), abs($0.minY - expected.frame.minY),
                abs($0.width - expected.frame.width), abs($0.height - expected.frame.height)) < 2
        } ?? false
        if arrived || ProcessInfo.processInfo.systemUptime >= expected.until {
            self.expected = nil
            return actual
        }
        return expected.frame
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
            let resized = cocoaFrame.size != lastFrame.size
            lastFrame = cocoaFrame
            // A pure move (dragging) only needs the window shifted; skip rebuilding the layers.
            guard resized else {
                window.setFrameOrigin(cocoaFrame.origin)
                if !window.isVisible { window.orderFrontRegardless() }
                return
            }
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
