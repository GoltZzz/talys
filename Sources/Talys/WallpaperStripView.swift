import Cocoa

/// Paints the slice of the desktop wallpaper behind the bar's window, so the bar can cover the macOS menu bar
/// without changing how the top of the screen looks.
///
/// The image is looked up in order: `bar.wallpaper`, the file macOS reports, a same-named file in
/// `bar.wallpaper_dir`, then the last one that loaded on this display (kept in ~/Library/Caches/talys, so a
/// wallpaper whose file was moved, renamed or deleted keeps working). Dynamic and aerial wallpapers show a still
/// frame; when nothing loads, the strip falls back to the Desktop fill color.
@MainActor
final class WallpaperStripView: NSView {
    /// `bar.wallpaper`: an image to use instead of the one macOS reports.
    var overridePath = "" { didSet { if overridePath != oldValue { refresh() } } }
    /// `bar.wallpaper_dir`: where to look for the wallpaper by name when macOS's path no longer exists.
    var searchDirectory = "" { didSet { if searchDirectory != oldValue { refresh() } } }

    private var image: NSImage?
    /// Every input the lookup depends on, including modification dates, so a file replaced in place is picked up too.
    private var imageKey: String?

    private static let cacheDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/talys", isDirectory: true)

    /// Reloads the wallpaper if it changed; cheap enough to call on a timer.
    func refresh() {
        guard let screen = window?.screen ?? NSScreen.main else { return }
        let reported = NSWorkspace.shared.desktopImageURL(for: screen)
        let override = Self.expand(overridePath)
        let directory = Self.expand(searchDirectory)
        let key = [override, reported, directory].map { url in
            "\(url?.path ?? "")|\(Self.modified(url)?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "#")
        if key != imageKey {
            imageKey = key
            image = loadImage(override: override, reported: reported, directory: directory, screen: screen)
        }
        // Scaling and fill options can change without the image changing.
        needsDisplay = true
    }

    private func loadImage(override: URL?, reported: URL?, directory: URL?, screen: NSScreen) -> NSImage? {
        let cache = Self.cacheURL(for: screen)
        let candidates = [override, reported, reported.flatMap { Self.find(named: $0, in: directory) }]
        for case let url? in candidates {
            guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else { continue }
            if let cache {
                try? FileManager.default.createDirectory(at: Self.cacheDirectory, withIntermediateDirectories: true)
                try? data.write(to: cache, options: .atomic)
            }
            return image
        }
        return cache.flatMap { try? Data(contentsOf: $0) }.flatMap(NSImage.init(data:))
    }

    /// A file in `directory` (or one level below it) with the same name as the missing wallpaper, ignoring the
    /// extension so a copy converted to another format still matches.
    private static func find(named missing: URL, in directory: URL?) -> URL? {
        guard let directory, !FileManager.default.fileExists(atPath: missing.path) else { return nil }
        let name = missing.deletingPathExtension().lastPathComponent.lowercased()
        let fm = FileManager.default
        let top = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                                               options: .skipsHiddenFiles)) ?? []
        let nested = top.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil,
                                                    options: .skipsHiddenFiles)) ?? [] }
        return (top + nested).first { $0.deletingPathExtension().lastPathComponent.lowercased() == name }
    }

    /// One cached wallpaper per display, keyed by the display's UUID so it survives reboots and re-plugging.
    private static func cacheURL(for screen: NSScreen) -> URL? {
        guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue(),
              let id = CFUUIDCreateString(nil, uuid) as String? else { return nil }
        return cacheDirectory.appendingPathComponent("wallpaper-\(id)")
    }

    private static func expand(_ path: String) -> URL? {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
    }

    private static func modified(_ url: URL?) -> Date? {
        url.flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date }
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
