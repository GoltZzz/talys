import Cocoa
@preconcurrency import ApplicationServices

/// Where windows of hidden workspaces (and the stashed scratchpad) live.
///
/// macOS refuses to move a window fully off-screen, so instead of flinging it to a far-away
/// coordinate (which macOS clamps back, leaving a strip on the left edge) we park its top-left
/// corner on the bottom-right pixel of the right-most display, keeping its real size so it can
/// snap straight back. The sliver macOS insists on showing is covered by `CurtainController`.
public enum ParkingLot {
    /// How far from the park point macOS may nudge a window and it still counts as parked.
    static let slack: CGFloat = 100

    /// Bounds (AX / global top-left coordinates) of the display hosting the parking lot.
    public static func hostDisplay() -> (id: CGDirectDisplayID, bounds: CGRect) {
        var count: UInt32 = 0
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        CGGetActiveDisplayList(16, &ids, &count)
        let displays = ids.prefix(Int(count)).map { ($0, CGDisplayBounds($0)) }
        let best = displays.max { a, b in
            a.1.maxX != b.1.maxX ? a.1.maxX < b.1.maxX : a.1.maxY < b.1.maxY
        }
        let main = CGMainDisplayID()
        return best.map { (id: $0.0, bounds: $0.1) } ?? (id: main, bounds: CGDisplayBounds(main))
    }

    /// Top-left position (AX coordinates) for a parked window.
    public static func parkPoint() -> CGPoint {
        let b = hostDisplay().bounds
        return CGPoint(x: b.maxX - 1, y: b.maxY - 1)
    }

    /// True for frames sitting in the parking lot (or the legacy far-offscreen spot).
    public static func isParked(_ frame: CGRect) -> Bool {
        if frame.origin.x < -10000 || frame.origin.y < -10000 { return true }
        let p = parkPoint()
        return frame.minX >= p.x - slack && frame.minY >= p.y - slack
    }
}

/// A tiny click-absorbing panel over the parking corner that paints the matching crop of the
/// desktop wallpaper, so parked windows are invisible and can't be grabbed by accident.
@MainActor
public final class CurtainController {
    public static let shared = CurtainController()

    private var panel: FloatingBarPanel?
    private let view = WallpaperCropView()

    private init() {}

    /// Re-measures what the parked windows still show on screen and covers exactly that.
    public func cover(_ elements: [AXUIElement]) {
        let host = ParkingLot.hostDisplay()
        var exposed = CGRect.null
        for element in elements {
            guard let frame = AccessibilityHelper.getFrame(for: element) else { continue }
            let visible = frame.intersection(host.bounds)
            if !visible.isNull, visible.width > 0, visible.height > 0 {
                exposed = exposed.union(visible)
            }
        }

        // Anything bigger means a window refused to park; don't paint wallpaper over real content.
        guard !exposed.isNull, exposed.width <= ParkingLot.slack + 1, exposed.height <= ParkingLot.slack + 1 else {
            panel?.orderOut(nil)
            return
        }

        let axRect = exposed.insetBy(dx: -1, dy: -1).intersection(host.bounds)
        let primaryHeight = CGDisplayBounds(CGMainDisplayID()).height
        let cocoaRect = NSRect(x: axRect.minX, y: primaryHeight - axRect.maxY, width: axRect.width, height: axRect.height)

        let panel = self.panel ?? makePanel()
        self.panel = panel
        let screen = NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == host.id }
        view.configure(screen: screen, panelOrigin: cocoaRect.origin)
        panel.setFrame(cocoaRect, display: true)
        view.needsDisplay = true
        panel.orderFrontRegardless()
    }

    public func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> FloatingBarPanel {
        let panel = FloatingBarPanel(contentRect: .zero)
        panel.ignoresMouseEvents = false
        panel.contentView = view
        return panel
    }
}

/// Draws the part of the screen's wallpaper that lies under the panel, honouring the desktop's scaling options.
private final class WallpaperCropView: NSView {
    private var screen: NSScreen?
    private var panelOrigin: NSPoint = .zero
    private var imageURL: URL?
    private var image: NSImage?

    func configure(screen: NSScreen?, panelOrigin: NSPoint) {
        self.screen = screen
        self.panelOrigin = panelOrigin
        let url = screen.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }
        if url != imageURL {
            imageURL = url
            image = url.flatMap { NSImage(contentsOf: $0) }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let screen else {
            NSColor.black.setFill()
            bounds.fill()
            return
        }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        (options[.fillColor] as? NSColor ?? .black).setFill()
        bounds.fill()
        guard let image, image.size.width > 0, image.size.height > 0 else { return }

        let s = screen.frame
        let size = image.size
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) } ?? .scaleProportionallyUpOrDown
        let clip = (options[.allowClipping] as? Bool) ?? true

        var drawRect: NSRect
        switch scaling {
        case .scaleAxesIndependently:
            drawRect = s
        case .scaleNone:
            drawRect = NSRect(x: s.midX - size.width / 2, y: s.midY - size.height / 2, width: size.width, height: size.height)
        default:
            let k = clip ? max(s.width / size.width, s.height / size.height) : min(s.width / size.width, s.height / size.height)
            let w = size.width * k, h = size.height * k
            drawRect = NSRect(x: s.midX - w / 2, y: s.midY - h / 2, width: w, height: h)
        }
        drawRect.origin.x -= panelOrigin.x
        drawRect.origin.y -= panelOrigin.y
        image.draw(in: drawRect)
    }
}
