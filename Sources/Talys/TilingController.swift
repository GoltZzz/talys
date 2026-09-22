import Cocoa
import CTalysEngine
@preconcurrency import ApplicationServices

public final class WindowRecord {
    public let id: TalysWindowId
    public let element: AXUIElement
    public let pid: pid_t
    public var title: String

    public init(id: TalysWindowId, element: AXUIElement, pid: pid_t, title: String) {
        self.id = id
        self.element = element
        self.pid = pid
        self.title = title
    }
}

public final class TilingController: @unchecked Sendable {
    public static let shared = TilingController()

    private var windowMap: [TalysWindowId: WindowRecord] = [:]
    private var nextId: TalysWindowId = 1
    private var rulesMatcher = WindowRulesMatcher()
    private var healthCheckTimer: DispatchSourceTimer?

    public var onWorkspaceChanged: ((UInt8) -> Void)?

    public var isEnabled: Bool = true {
        didSet {
            if isEnabled {
                retileAll()
            }
        }
    }

    private let lock = NSLock()

    public init() {
        talys_engine_init()
        startHealthCheckTimer()
    }

    deinit {
        healthCheckTimer?.cancel()
    }

    private func startHealthCheckTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 20, repeating: .seconds(20))
        timer.setEventHandler { [weak self] in
            self?.cleanupStaleWindows()
        }
        self.healthCheckTimer = timer
        timer.resume()
    }

    public static func getAxScreenRect(screen: NSScreen? = NSScreen.main) -> TalysRect {
        guard let screen = screen else {
            return TalysRect(x: 0, y: 0, width: 1920, height: 1080)
        }

        let primaryScreen = NSScreen.screens.first ?? screen
        let primaryHeight = primaryScreen.frame.height
        let visible = screen.visibleFrame

        let axX = visible.origin.x
        let axY = primaryHeight - visible.origin.y - visible.size.height
        let axW = visible.size.width
        let axH = visible.size.height

        return TalysRect(x: axX, y: axY, width: axW, height: axH)
    }

    public func setWindowRules(_ rules: [WindowRule]) {
        self.rulesMatcher = WindowRulesMatcher(rules: rules)
    }

    public func setAnimations(enabled: Bool, durationMs: Double) {
        WindowAnimator.shared.isEnabled = enabled
        WindowAnimator.shared.duration = max(0.01, durationMs / 1000.0)
    }

    public func syncCurrentFocus() {
        if let front = AccessibilityHelper.getFocusedWindow() {
            if let record = findRecord(for: front.element) {
                talys_engine_set_focus(record.id)
            }
        }
    }

    public func cleanupStaleWindows() {
        lock.lock()
        var staleIds: [TalysWindowId] = []
        for (wid, record) in windowMap {
            if !AccessibilityHelper.isElementValid(record.element) {
                staleIds.append(wid)
            }
        }
        for wid in staleIds {
            windowMap.removeValue(forKey: wid)
        }
        lock.unlock()

        for wid in staleIds {
            talys_engine_remove_window(wid)
            print("[TilingController] Cleaned up stale window [ID \(wid)]")
        }

        if !staleIds.isEmpty {
            applyLayout()
        }
    }

    public func findRecord(for element: AXUIElement) -> WindowRecord? {
        lock.lock()
        defer { lock.unlock() }
        for (_, record) in windowMap {
            if CFEqual(record.element, element) {
                return record
            }
        }
        return nil
    }

    public func addWindow(element: AXUIElement, pid: pid_t, title: String) {
        guard isEnabled else { return }
        guard AccessibilityHelper.isStandardWindow(element) else { return }

        lock.lock()
        for (_, record) in windowMap {
            if CFEqual(record.element, element) {
                lock.unlock()
                return
            }
        }

        let wid = nextId
        nextId += 1
        let record = WindowRecord(id: wid, element: element, pid: pid, title: title)
        windowMap[wid] = record
        lock.unlock()

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        let matchedRule = rulesMatcher.match(appName: appName, windowTitle: title)

        let currentWs = talys_engine_get_active_workspace()
        let targetWs = matchedRule?.workspace ?? currentWs

        if targetWs != currentWs {
            talys_engine_add_window_to_workspace(wid, targetWs)
            AccessibilityHelper.setFrame(for: element, frame: CGRect(x: -25000, y: -25000, width: 400, height: 300))
            print("[TilingController] Window rule assigned [ID \(wid)] \"\(title)\" to workspace \(targetWs)")
        } else {
            talys_engine_add_window(wid)
            print("[TilingController] Added window [ID \(wid)] \"\(title)\" (pid: \(pid)) to workspace \(currentWs)")

            if matchedRule?.floating == true {
                _ = talys_engine_toggle_float(wid)
                print("[TilingController] Window rule applied: auto-float [ID \(wid)]")
            }

            applyLayout()
        }
    }

    public func removeWindow(element: AXUIElement) {
        lock.lock()
        var foundWid: TalysWindowId?
        for (wid, record) in windowMap {
            if CFEqual(record.element, element) {
                foundWid = wid
                break
            }
        }

        if let wid = foundWid {
            windowMap.removeValue(forKey: wid)
            lock.unlock()
            talys_engine_remove_window(wid)
            print("[TilingController] Removed window [ID \(wid)]")
            applyLayout()
        } else {
            lock.unlock()
        }
    }

    public func removeWindows(for pid: pid_t) {
        lock.lock()
        var toRemove: [TalysWindowId] = []
        for (wid, record) in windowMap {
            if record.pid == pid {
                toRemove.append(wid)
            }
        }
        for wid in toRemove {
            windowMap.removeValue(forKey: wid)
        }
        lock.unlock()

        for wid in toRemove {
            talys_engine_remove_window(wid)
        }
        if !toRemove.isEmpty {
            print("[TilingController] Cleaned up \(toRemove.count) window(s) for terminated pid \(pid)")
            applyLayout()
        }
    }

    public func setFocusedWindow(element: AXUIElement) {
        if let record = findRecord(for: element) {
            talys_engine_set_focus(record.id)
        }
    }

    public func focusDirection(_ direction: UInt8) {
        guard isEnabled else { return }
        syncCurrentFocus()
        let screenRect = Self.getAxScreenRect()
        let targetWid = talys_engine_focus_direction(direction, screenRect)

        if targetWid != 0 {
            lock.lock()
            let record = windowMap[targetWid]
            lock.unlock()

            if let record = record {
                print("[TilingController] Focusing direction \(direction) -> window [ID \(targetWid)] \"\(record.title)\"")
                AccessibilityHelper.focusWindow(element: record.element, pid: record.pid)
            }
        }
    }

    public func swapDirection(_ direction: UInt8) {
        guard isEnabled else { return }
        syncCurrentFocus()
        let screenRect = Self.getAxScreenRect()
        if talys_engine_swap_direction(direction, screenRect) {
            print("[TilingController] Swapped direction \(direction)")
            applyLayout()
        }
    }

    public func toggleFloat() {
        syncCurrentFocus()
        let currentFocus = talys_engine_get_focus()
        guard currentFocus != 0 else { return }

        let isFloating = talys_engine_toggle_float(currentFocus)
        print("[TilingController] Window [ID \(currentFocus)] floating: \(isFloating)")
        applyLayout()
    }

    public func closeFocusedWindow() {
        syncCurrentFocus()
        let currentFocus = talys_engine_get_focus()
        guard currentFocus != 0 else { return }

        lock.lock()
        let record = windowMap[currentFocus]
        lock.unlock()

        if let record = record {
            print("[TilingController] Closing focused window [ID \(currentFocus)] \"\(record.title)\"")
            AccessibilityHelper.closeWindow(element: record.element)
        }
    }

    public func resizeFocused(_ delta: Double) {
        guard isEnabled else { return }
        syncCurrentFocus()
        talys_engine_resize_focused(delta)
        applyLayout()
    }

    public func toggleFullscreen() {
        guard isEnabled else { return }
        talys_engine_toggle_fullscreen()
        print("[TilingController] Fullscreen: \(talys_engine_is_fullscreen())")
        applyLayout()
    }

    public func cycleLayout() {
        guard isEnabled else { return }
        talys_engine_cycle_layout()
        let mode = Int32(talys_engine_get_layout_mode())
        let modeName = switch mode {
        case TALYS_LAYOUT_DWINDLE: "Dwindle"
        case TALYS_LAYOUT_MASTER_STACK: "Master-Stack"
        case TALYS_LAYOUT_MONOCLE: "Monocle"
        default: "Unknown"
        }
        print("[TilingController] Cycled layout mode -> \(modeName)")
        applyLayout()
    }

    public func switchWorkspace(_ target: UInt8) {
        guard isEnabled else { return }
        let currentWs = talys_engine_get_active_workspace()
        if target == currentWs { return }

        let maxCount = 128
        var hideIds = [TalysWindowId](repeating: 0, count: maxCount)
        var showIds = [TalysWindowId](repeating: 0, count: maxCount)
        var counts = TalysSwitchResult(hide_count: 0, show_count: 0)

        let ok = talys_engine_switch_workspace(target, &hideIds, maxCount, &showIds, maxCount, &counts)
        guard ok else { return }

        print("[TilingController] Switching workspace \(currentWs) -> \(target) (hiding \(counts.hide_count), showing \(counts.show_count))")

        lock.lock()
        let records = windowMap
        lock.unlock()

        for i in 0..<counts.hide_count {
            let wid = hideIds[i]
            if let record = records[wid] {
                AccessibilityHelper.setFrame(for: record.element, frame: CGRect(x: -25000, y: -25000, width: 400, height: 300))
            }
        }

        applyLayout()

        let newFocus = talys_engine_get_focus()
        if newFocus != 0, let record = records[newFocus] {
            AccessibilityHelper.focusWindow(element: record.element, pid: record.pid)
        }

        onWorkspaceChanged?(target)
    }

    public func moveToWorkspace(_ target: UInt8) {
        guard isEnabled else { return }
        syncCurrentFocus()
        let currentFocus = talys_engine_get_focus()
        guard currentFocus != 0 else { return }

        let currentWs = talys_engine_get_active_workspace()
        if target == currentWs { return }

        lock.lock()
        let record = windowMap[currentFocus]
        lock.unlock()

        guard let record = record else { return }

        if talys_engine_move_to_workspace(currentFocus, target) {
            print("[TilingController] Moved window [ID \(currentFocus)] \"\(record.title)\" to workspace \(target)")
            AccessibilityHelper.setFrame(for: record.element, frame: CGRect(x: -25000, y: -25000, width: 400, height: 300))
            applyLayout()
        }
    }

    public func setGaps(inner: Double, outer: Double) {
        talys_engine_set_gaps(inner, outer)
        applyLayout()
    }

    public func retileAll() {
        guard isEnabled else { return }
        print("[TilingController] Retiling all windows...")

        lock.lock()
        talys_engine_reset()
        windowMap.removeAll()
        nextId = 1
        lock.unlock()

        let windows = AccessibilityHelper.getAllStandardWindows()
        for w in windows {
            addWindow(element: w.element, pid: w.pid, title: w.title)
        }

        if let focused = AccessibilityHelper.getFocusedWindow() {
            setFocusedWindow(element: focused.element)
        }

        applyLayout()
    }

    public func applyLayout() {
        guard isEnabled else { return }
        let screenRect = Self.getAxScreenRect()
        let maxCount = 128

        var outIds = [TalysWindowId](repeating: 0, count: maxCount)
        var outRects = [TalysRect](repeating: TalysRect(x: 0, y: 0, width: 0, height: 0), count: maxCount)

        let count = Int(talys_engine_calculate_layout(screenRect, maxCount, &outIds, &outRects))
        guard count > 0 else { return }

        lock.lock()
        let records = windowMap
        lock.unlock()

        var animationFrames: [(element: AXUIElement, currentFrame: CGRect, targetFrame: CGRect)] = []

        for i in 0..<count {
            let wid = outIds[i]
            let r = outRects[i]
            guard let record = records[wid] else { continue }

            let targetFrame = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            let currentFrame = AccessibilityHelper.getFrame(for: record.element) ?? targetFrame

            animationFrames.append((element: record.element, currentFrame: currentFrame, targetFrame: targetFrame))
        }

        WindowAnimator.shared.animate(frames: animationFrames)
    }
}
