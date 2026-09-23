import Cocoa

public final class WindowAnimator: @unchecked Sendable {
    public static let shared = WindowAnimator()

    public var isEnabled: Bool = true
    public var duration: TimeInterval = 0.18

    private struct AnimatingWindow {
        let element: AXUIElement
        let startFrame: CGRect
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
                AccessibilityHelper.setFrame(for: item.element, frame: item.targetFrame)
            }
            return
        }

        var toAnimate: [AnimatingWindow] = []

        for item in frames {
            let start = item.currentFrame
            let target = item.targetFrame

            // Never fly a window in from (or out to) the parking lot.
            if ParkingLot.isParked(start) || ParkingLot.isParked(target) {
                AccessibilityHelper.setFrame(for: item.element, frame: target)
                continue
            }

            let dx = abs(start.origin.x - target.origin.x)
            let dy = abs(start.origin.y - target.origin.y)
            let dw = abs(start.size.width - target.size.width)
            let dh = abs(start.size.height - target.size.height)

            if dx < 2 && dy < 2 && dw < 2 && dh < 2 {
                AccessibilityHelper.setFrame(for: item.element, frame: target)
                continue
            }

            toAnimate.append(AnimatingWindow(
                element: item.element,
                startFrame: start,
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
            let current = isFinished ? item.targetFrame : interpolate(from: item.startFrame, to: item.targetFrame, t: t)
            AccessibilityHelper.setFrame(for: item.element, frame: current)
        }

        // The timer runs on the main queue, so the border can follow the window each frame.
        MainActor.assumeIsolated {
            BorderController.shared.refresh()
        }
    }

    private func interpolate(from: CGRect, to: CGRect, t: Double) -> CGRect {
        let x = from.origin.x + (to.origin.x - from.origin.x) * t
        let y = from.origin.y + (to.origin.y - from.origin.y) * t
        let w = from.size.width + (to.size.width - from.size.width) * t
        let h = from.size.height + (to.size.height - from.size.height) * t
        return CGRect(x: x, y: y, width: w, height: h)
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
