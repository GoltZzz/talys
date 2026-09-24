import Cocoa

/// Paints the slice of the desktop wallpaper behind the bar's window, so the bar can cover the macOS menu bar
/// without changing how the top of the screen looks.
///
/// Dynamic and aerial wallpapers show a still frame; one macOS can't hand over as an image falls back to its fill color.
@MainActor
final class WallpaperStripView: NSView {
    private var image: NSImage?
    /// Wallpaper path and modification date, so a file replaced in place is picked up too.
    private var imageKey: String?

    /// Reloads the wallpaper if it changed; cheap enough to call on a timer.
    func refresh() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        let modified = url.flatMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
        }
        let key = "\(url?.path ?? "")|\(modified?.timeIntervalSince1970 ?? 0)"
        if key != imageKey {
            imageKey = key
            image = url.flatMap(NSImage.init(contentsOf:))
        }
        // Scaling and fill options can change without the image changing.
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window, let screen = window.screen ?? NSScreen.main else { return }
        let options = NSWorkspace.shared.desktopImageOptions(for: screen) ?? [:]
        (options[.fillColor] as? NSColor ?? .black).setFill()
        bounds.fill()

        guard let image, image.size.width > 0, image.size.height > 0 else { return }
        let scaling = (options[.imageScaling] as? NSNumber).flatMap { NSImageScaling(rawValue: $0.uintValue) }
            ?? .scaleProportionallyUpOrDown
        let clipping = (options[.allowClipping] as? NSNumber)?.boolValue ?? true
        let onScreen = Self.imageRect(for: image.size, in: screen.frame, scaling: scaling, clipping: clipping)
        let inView = onScreen.offsetBy(dx: -window.frame.minX, dy: -window.frame.minY)
        image.draw(in: inView, from: .zero, operation: .copy, fraction: 1)
    }

    /// Where macOS draws the wallpaper on the screen for the given Desktop "fill / fit / stretch / center" option.
    private static func imageRect(for size: NSSize, in screen: NSRect, scaling: NSImageScaling,
                                  clipping: Bool) -> NSRect {
        let fit = min(screen.width / size.width, screen.height / size.height)
        let fill = max(screen.width / size.width, screen.height / size.height)
        let scale: CGFloat
        switch scaling {
        case .scaleAxesIndependently:
            return screen
        case .scaleNone:
            scale = 1
        case .scaleProportionallyDown:
            scale = min(1, fit)
        default:
            scale = clipping ? fill : fit
        }
        let w = size.width * scale, h = size.height * scale
        return NSRect(x: screen.midX - w / 2, y: screen.midY - h / 2, width: w, height: h)
    }
}
