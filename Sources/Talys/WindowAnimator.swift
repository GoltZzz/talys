import Cocoa

public final class WindowAnimator: @unchecked Sendable {
    public static let shared = WindowAnimator()

    public var isEnabled: Bool = true
    public var duration: TimeInterval = 0.12
    /// Called on the main queue once a window has been given its final frame.
    public var onPlaced: ((AXUIElement, CGRect) -> Void)?

    /// Only the position slides; resizing through AX makes the app relayout, which stutters every frame.
    private struct AnimatingWindow {
        let element: AXUIElement
        let startOrigin: CGPoint
        let targetFrame: CGRect
    }

    private var activeTimer: DispatchSourceTimer?
    private var startTime: TimeInterval = 0
    private var windows: [AnimatingWindow] = []
    private let lock = NSLock()

    public init() {}

    public func animate(frames: [(element: AXUIElement, currentFrame: CGRect, targetFrame: CGRect)]) {
        lock.lock()
        defer { lock.unlock() }

        activeTimer?.cancel()
        activeTimer = nil
        windows.removeAll()

        guard isEnabled && duration > 0.02 else {
            for item in frames {
                place(item.element, item.targetFrame)
            }
            return
        }

        var toAnimate: [AnimatingWindow] = []

        for item in frames {
            let start = item.currentFrame
            let target = item.targetFrame

            // Never fly a window in from (or out to) the parking lot.
            if ParkingLot.isParked(start) || ParkingLot.isParked(target) {
                place(item.element, target)
                continue
            }

            let dx = abs(start.origin.x - target.origin.x)
            let dy = abs(start.origin.y - target.origin.y)
            let dw = abs(start.size.width - target.size.width)
            let dh = abs(start.size.height - target.size.height)

            if dx < 2 && dy < 2 && dw < 2 && dh < 2 {
                place(item.element, target)
                continue
            }

            // Slide at the smaller of the two sizes on each axis, so a window never covers its neighbours
            // mid-slide: shrinking windows shrink first, growing ones grow once they've arrived.
            let slideSize = CGSize(width: min(start.width, target.width), height: min(start.height, target.height))
            if abs(slideSize.width - start.width) >= 1 || abs(slideSize.height - start.height) >= 1 {
                AccessibilityHelper.setSize(for: item.element, to: slideSize)
            }

            toAnimate.append(AnimatingWindow(
                element: item.element,
                startOrigin: start.origin,
                targetFrame: target
            ))
        }

        guard !toAnimate.isEmpty else { return }

        self.windows = toAnimate
        self.startTime = ProcessInfo.processInfo.systemUptime

        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(16))
        timer.setEventHandler { [weak self] in
            self?.stepAnimation()
        }
        self.activeTimer = timer
        timer.resume()
    }

    private func stepAnimation() {
        lock.lock()
        let elapsed = ProcessInfo.processInfo.systemUptime - startTime
        let progress = min(1.0, elapsed / duration)
        let t = 1.0 - pow(1.0 - progress, 3.0)
        let items = self.windows
        let isFinished = progress >= 1.0

        if isFinished {
            activeTimer?.cancel()
            activeTimer = nil
            windows.removeAll()
        }
        lock.unlock()

        for item in items {
            if isFinished {
                place(item.element, item.targetFrame)
            } else {
                AccessibilityHelper.setPosition(for: item.element, to: interpolate(from: item.startOrigin, to: item.targetFrame.origin, t: t))
            }
        }

        // The timer runs on the main queue, so the border can follow the window each frame.
        MainActor.assumeIsolated {
            BorderController.shared.refresh()
        }
    }

    private func place(_ element: AXUIElement, _ frame: CGRect) {
        AccessibilityHelper.setFrame(for: element, frame: frame)
        onPlaced?(element, frame)
    }

    private func interpolate(from: CGPoint, to: CGPoint, t: Double) -> CGPoint {
        CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
    }

    /// True while `element` is mid-animation, so its in-between frames aren't mistaken for an app moving it.
    public func isAnimating(_ element: AXUIElement) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return windows.contains { CFEqual($0.element, element) }
    }

    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        activeTimer?.cancel()
        activeTimer = nil
        windows.removeAll()
    }
}
