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

@MainActor
public final class TilingController {
    public static let shared = TilingController()

    private var windowMap: [TalysWindowId: WindowRecord] = [:]
    private var nextId: TalysWindowId = 1
    private var rulesMatcher = WindowRulesMatcher()
    private var healthCheckTimer: DispatchSourceTimer?

    /// Scratchpad windows live outside the Zig engine; they're shown centered on top of any workspace.
    private var scratchpad: [TalysWindowId] = []
    private var scratchpadVisible = false
    /// Windows currently sitting in the parking lot (hidden workspaces and the stashed scratchpad).
    private var parked: Set<TalysWindowId> = []
    /// Where the last layout put each tiled window on the active workspace.
    private var layoutTargets: [TalysWindowId: CGRect] = [:]
    /// Newly added windows, until when they're held to their tile. Some apps restore a saved frame a beat
    /// after showing the window; each such move is undone as it happens (see `windowFrameChanged`).
    private var settling: [TalysWindowId: TimeInterval] = [:]
    private static let settleDuration: TimeInterval = 1.0
    /// Workspace we last switched away from, for back-and-forth.
    private var previousWorkspace: UInt8?
    /// Smallest size each window's app has accepted, learned the first time it refused a smaller tile.
    /// There's no API to override an app's minimum, so layouts size tiles around it instead.
    private var minSizes: [TalysWindowId: CGSize] = [:]
    private var relayoutPending = false
    /// Scrolling layout: windows whose column is out of view. They wait in the parking lot like hidden workspaces.
    private var scrolledOff: Set<TalysWindowId> = []
    /// Windows sliding out of view, parked once they get there.
    private var parkOnArrival: Set<TalysWindowId> = []
    /// Less than this much of a column on screen isn't worth showing; it's parked instead.
    private static let minVisibleWidth: CGFloat = 40
    /// Mirrors the engine's `min_tile`: no tiled window gets less than this.
    private static let minTile = CGSize(width: 300, height: 150)
    /// A window that can't fit its workspace moves to the next one with room (else it floats).
    private var overflowToWorkspace = true
    /// Newly opened windows that overflow take the view with them; otherwise the bar flashes their workspace.
    private var overflowFollow = true
    /// Workspace to switch to once the current layout pass is done.
    private var pendingFollow: UInt8?
    /// True while picking up windows that were already open (startup, retile); those never take the view along.
    private var adoptingExisting = false

    public var onWorkspaceChanged: ((UInt8) -> Void)?
    public var barConfig: BarConfig = BarConfig()

    public var isEnabled: Bool = true {
        didSet {
            TalysDesktopState.shared.isTilingEnabled = isEnabled
            if isEnabled {
                retileAll()
            } else {
                // Untiled, nothing would ever bring hidden workspaces back; show everything.
                unparkAll()
            }
            BorderController.shared.refresh()
        }
    }

    /// True while the user is on a macOS Space other than Talys's home one (see `SpaceMonitor`).
    public private(set) var isAwayFromHome = false

    /// Tiling runs only when enabled and on the home Space; elsewhere Talys can't see its windows.
    private var isActive: Bool { isEnabled && !isAwayFromHome }

    private let lock = NSLock()

    public init() {
        talys_engine_init()
        startHealthCheckTimer()
        WindowAnimator.shared.onPlaced = { element, frame in
            MainActor.assumeIsolated { TilingController.shared.windowPlaced(element: element, target: frame) }
        }
        TalysDesktopState.shared.activeWorkspace = talys_engine_get_active_workspace()
        TalysDesktopState.shared.updateLayoutModeFromEngine()
        TalysDesktopState.shared.updateOccupiedWorkspaces()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { TilingController.shared.repark() }
        }
    }

    deinit {
        healthCheckTimer?.cancel()
    }

    public func setBarConfig(_ config: BarConfig) {
        self.barConfig = config
        // Only relayout: retileAll() re-queries on-screen windows and would drop ones parked on hidden workspaces.
        applyLayout()
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

    public static func getAxScreenRect(screen: NSScreen? = NSScreen.main, barConfig: BarConfig? = nil) -> TalysRect {
        guard let screen = screen else {
            return TalysRect(x: 0, y: 0, width: 1920, height: 1080)
        }

        let primaryScreen = NSScreen.screens.first ?? screen
        let primaryHeight = primaryScreen.frame.height
        let visible = screen.visibleFrame

        let axX = visible.origin.x
        let axW = visible.size.width
        var axY = primaryHeight - visible.maxY
        let axBottom = primaryHeight - visible.minY

        // The bar hangs from the screen's real top edge (not the visible frame's), and the engine insets
        // this rect by the outer gap. Back that out so windows sit exactly `bar.gap` below the bar.
        let cfg = barConfig ?? TilingController.shared.barConfig
        if cfg.enabled {
            let screenTop = primaryHeight - screen.frame.maxY
            let barBottom = screenTop + BarController.coveredHeight(on: screen, config: cfg)
            axY = barBottom + cfg.gap - TilingController.shared.outerGap
        }

        return TalysRect(x: axX, y: axY, width: axW, height: max(0, axBottom - axY))
    }

    public func setWindowRules(_ rules: [WindowRule]) {
        self.rulesMatcher = WindowRulesMatcher(rules: rules)
    }

    public func setOverflow(toWorkspace: Bool, follow: Bool) {
        overflowToWorkspace = toWorkspace
        overflowFollow = follow
    }

    public func setAnimations(enabled: Bool, durationMs: Double) {
        WindowAnimator.shared.isEnabled = enabled
        WindowAnimator.shared.duration = max(0.01, durationMs / 1000.0)
    }

    /// Runtime switch; the config's `[animations] enabled` sets it again on the next reload.
    public func toggleAnimations() {
        WindowAnimator.shared.stop()
        WindowAnimator.shared.isEnabled.toggle()
        // A cut-off slide leaves windows between tiles; put them where they belong.
        applyLayout()
        print("[TilingController] Animations \(WindowAnimator.shared.isEnabled ? "on" : "off")")
    }

    public func syncCurrentFocus() {
        guard let front = AccessibilityHelper.getFocusedWindow() else {
            BorderController.shared.setTarget(nil)
            return
        }
        setFocusedWindow(element: front.element)
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
            if let record = windowMap.removeValue(forKey: wid) {
                BorderController.shared.clearTarget(ifMatching: record.element)
            }
        }
        lock.unlock()
        scratchpad.removeAll { staleIds.contains($0) }
        parked.subtract(staleIds)
        forget(staleIds)
        updateScratchpadState()

        for wid in staleIds {
            talys_engine_remove_window(wid)
            print("[TilingController] Cleaned up stale window [ID \(wid)]")
        }

        if !staleIds.isEmpty {
            applyLayout()
            TalysDesktopState.shared.updateOccupiedWorkspaces()
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

    /// Returns true when the window was newly added.
    @discardableResult
    public func addWindow(element: AXUIElement, pid: pid_t, title: String) -> Bool {
        guard isActive else { return false }
        guard AccessibilityHelper.isStandardWindow(element) else { return false }

        lock.lock()
        for (_, record) in windowMap {
            if CFEqual(record.element, element) {
                lock.unlock()
                return false
            }
        }

        let wid = nextId
        nextId += 1
        let record = WindowRecord(id: wid, element: element, pid: pid, title: title)
        windowMap[wid] = record
        lock.unlock()

        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName
        let matchedRule = rulesMatcher.match(appName: appName, windowTitle: title)

        applyRememberedMinSize(wid, pid: pid)

        let currentWs = talys_engine_get_active_workspace()
        var targetWs = matchedRule?.workspace ?? currentWs
        // A rule's workspace that's already full cascades on to the next one with room.
        if targetWs != currentWs, overflowToWorkspace, !talys_engine_fits_on_workspace(wid, targetWs, Self.getAxScreenRect()) {
            let room = talys_engine_find_room(wid, targetWs, 0, Self.getAxScreenRect())
            if room != 0 {
                print("[TilingController] Workspace \(targetWs) is full; window [ID \(wid)] goes to \(room) instead")
                targetWs = room
            }
        }

        if targetWs != currentWs {
            talys_engine_add_window_to_workspace(wid, targetWs)
            park(record)
            refreshCurtain()
            print("[TilingController] Window rule assigned [ID \(wid)] \"\(title)\" to workspace \(targetWs)")
        } else {
            talys_engine_add_window(wid)
            print("[TilingController] Added window [ID \(wid)] \"\(title)\" (pid: \(pid)) to workspace \(currentWs)")

            if matchedRule?.floating == true {
                _ = talys_engine_toggle_float(wid)
                print("[TilingController] Window rule applied: auto-float [ID \(wid)]")
            }

            // Marked settling first: the layout may overflow it to another workspace, and new windows take the view along.
            let now = ProcessInfo.processInfo.systemUptime
            settling = settling.filter { $0.value > now }
            settling[wid] = now + Self.settleDuration
            // Snap the new window straight into its tile; neighbours still animate.
            applyLayout(snapping: [wid])
        }
        TalysDesktopState.shared.updateOccupiedWorkspaces()
        return true
    }

    /// Picks up any on-screen windows of `app` we aren't tracking yet (addWindow ignores known ones).
    /// Returns how many on-screen windows of the app are tracked afterwards.
    @discardableResult
    public func adoptWindows(of app: NSRunningApplication) -> Int {
        guard isActive else { return 0 }
        let windows = AccessibilityHelper.getStandardWindows(for: app)
        for w in windows {
            addWindow(element: w.element, pid: w.pid, title: w.title)
        }
        return windows.count
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
            BorderController.shared.clearTarget(ifMatching: element)
            if parked.remove(wid) != nil { refreshCurtain() }
            forget([wid])
            if isScratchpad(wid) {
                scratchpad.removeAll { $0 == wid }
                updateScratchpadState()
                return
            }
            talys_engine_remove_window(wid)
            print("[TilingController] Removed window [ID \(wid)]")
            applyLayout()
            TalysDesktopState.shared.updateOccupiedWorkspaces()
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
            if let record = windowMap.removeValue(forKey: wid) {
                BorderController.shared.clearTarget(ifMatching: record.element)
            }
        }
        lock.unlock()
        scratchpad.removeAll { toRemove.contains($0) }
        parked.subtract(toRemove)
        forget(toRemove)
        refreshCurtain()
        updateScratchpadState()

        for wid in toRemove {
            talys_engine_remove_window(wid)
        }
        if !toRemove.isEmpty {
            print("[TilingController] Cleaned up \(toRemove.count) window(s) for terminated pid \(pid)")
            applyLayout()
            TalysDesktopState.shared.updateOccupiedWorkspaces()
        }
    }

    public func setFocusedWindow(element: AXUIElement) {
        guard let record = findRecord(for: element) else {
            BorderController.shared.setTarget(nil)
            return
        }
        guard !isAwayFromHome else { return }
        if parked.contains(record.id) {
            // Stray focus events from windows we just parked must not steal the border, title, or the
            // workspace's remembered focus. A scrolled-off window that really has focus (Cmd+Tab, the Dock)
            // is scrolled into view instead.
            guard scrolledOff.contains(record.id),
                  let front = AccessibilityHelper.getFocusedWindow(), CFEqual(front.element, element) else { return }
        }
        BorderController.shared.setTarget(record.element)
        if !isScratchpad(record.id) {
            let scrolls = isScrolling && talys_engine_get_focus() != record.id
            talys_engine_set_focus(record.id)
            if scrolls { applyLayout() }
        }
        showActiveWindowInfo(record)
    }

    private func showActiveWindowInfo(_ record: WindowRecord?) {
        guard let record else {
            TalysDesktopState.shared.activeWindowTitle = ""
            TalysDesktopState.shared.activeAppIcon = nil
            return
        }
        let app = NSRunningApplication(processIdentifier: record.pid)
        let appName = app?.localizedName ?? ""
        TalysDesktopState.shared.activeWindowTitle = record.title.isEmpty ? appName : "\(appName) — \(record.title)"
        TalysDesktopState.shared.activeAppIcon = app?.icon
    }

    public func focusDirection(_ direction: UInt8) {
        guard isActive else { return }
        syncCurrentFocus()
        let screenRect = Self.getAxScreenRect()
        let targetWid = talys_engine_focus_direction(direction, screenRect)

        if targetWid != 0 {
            lock.lock()
            let record = windowMap[targetWid]
            lock.unlock()

            if let record = record {
                print("[TilingController] Focusing direction \(direction) -> window [ID \(targetWid)] \"\(record.title)\"")
                if isScrolling { applyLayout() }
                AccessibilityHelper.focusWindow(element: record.element, pid: record.pid)
            }
        }
    }

    public func swapDirection(_ direction: UInt8) {
        guard isActive else { return }
        syncCurrentFocus()
        let screenRect = Self.getAxScreenRect()
        if talys_engine_swap_direction(direction, screenRect) {
            print("[TilingController] Swapped direction \(direction)")
            applyLayout()
        }
    }

    /// True when the key window is a stashed scratchpad window, which the engine doesn't know about.
    private var scratchpadWindowFocused: Bool {
        guard let front = AccessibilityHelper.getFocusedWindow(), let record = findRecord(for: front.element) else { return false }
        return isScratchpad(record.id)
    }

    public func toggleFloat() {
        guard !isAwayFromHome, !scratchpadWindowFocused else { return }
        syncCurrentFocus()
        let currentFocus = talys_engine_get_focus()
        guard currentFocus != 0 else { return }

        let isFloating = talys_engine_toggle_float(currentFocus)
        print("[TilingController] Window [ID \(currentFocus)] floating: \(isFloating)")
        applyLayout()
    }

    public func closeFocusedWindow() {
        // The engine's focus is a home window; closing it from another Space would close the wrong thing.
        guard !isAwayFromHome else { return }
        if let front = AccessibilityHelper.getFocusedWindow(), let record = findRecord(for: front.element), isScratchpad(record.id) {
            AccessibilityHelper.closeWindow(element: record.element)
            return
        }
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
        guard isActive else { return }
        syncCurrentFocus()
        talys_engine_resize_focused(delta)
        applyLayout()
    }

    public func toggleFullscreen() {
        guard isActive else { return }
        talys_engine_toggle_fullscreen()
        print("[TilingController] Fullscreen: \(talys_engine_is_fullscreen())")
        applyLayout()
    }

    public func cycleLayout() {
        guard isActive else { return }
        talys_engine_cycle_layout()
        TalysDesktopState.shared.updateLayoutModeFromEngine()
        let mode = Int32(talys_engine_get_layout_mode())
        let modeName = switch mode {
        case TALYS_LAYOUT_DWINDLE: "Dwindle"
        case TALYS_LAYOUT_MASTER_STACK: "Master-Stack"
        case TALYS_LAYOUT_MONOCLE: "Monocle"
        case TALYS_LAYOUT_SCROLLING: "Scrolling"
        default: "Unknown"
        }
        print("[TilingController] Cycled layout mode -> \(modeName)")
        applyLayout()
    }

    private var isScrolling: Bool {
        talys_engine_get_layout_mode() == UInt8(TALYS_LAYOUT_SCROLLING)
    }

    /// Scrolling layout: steps the focused column through 1/3, 1/2 and 2/3 of the screen.
    public func cycleColumnWidth() {
        guard isActive, isScrolling else { return }
        syncCurrentFocus()
        talys_engine_cycle_column_width()
        applyLayout()
    }

    /// Scrolling layout: stacks the focused window into the column on that side, or pulls it out into its own.
    public func consumeOrExpel(_ direction: UInt8) {
        guard isActive, isScrolling else { return }
        syncCurrentFocus()
        if talys_engine_consume_or_expel(direction) {
            applyLayout()
        }
    }

    /// Switches instantly: hidden windows are parked at full size, shown ones snap into their tiles.
    /// Asking for the active workspace jumps back to the previous one when `backAndForth` is set.
    public func switchWorkspace(_ requested: UInt8, backAndForth: Bool = true) {
        guard isActive else { return }
        let currentWs = talys_engine_get_active_workspace()
        var target = requested
        if target == currentWs {
            guard backAndForth, let previous = previousWorkspace, previous != currentWs else { return }
            target = previous
        }

        let maxCount = 128
        var hideIds = [TalysWindowId](repeating: 0, count: maxCount)
        var showIds = [TalysWindowId](repeating: 0, count: maxCount)
        var counts = TalysSwitchResult(hide_count: 0, show_count: 0)

        let ok = talys_engine_switch_workspace(target, &hideIds, maxCount, &showIds, maxCount, &counts)
        guard ok else { return }
        previousWorkspace = currentWs

        print("[TilingController] Switching workspace \(currentWs) -> \(target) (hiding \(counts.hide_count), showing \(counts.show_count))")

        lock.lock()
        let records = windowMap
        lock.unlock()

        // A half-finished animation would drag hidden windows back on screen.
        WindowAnimator.shared.stop()
        for wid in hideIds.prefix(counts.hide_count) {
            if let record = records[wid] { park(record) }
            scrolledOff.remove(wid)
        }
        let shown = Set(showIds.prefix(counts.show_count))
        parked.subtract(shown)
        scrolledOff.subtract(shown)
        applyLayout(snapping: shown)
        refreshCurtain()

        // Each workspace remembers its own focus in the engine; restore it, or park keyboard focus
        // on the desktop so keystrokes can't reach a hidden window.
        let newFocus = talys_engine_get_focus()
        if newFocus != 0, let record = records[newFocus] {
            AccessibilityHelper.focusWindow(element: record.element, pid: record.pid)
            BorderController.shared.setTarget(record.element, expectedFrame: layoutTargets[newFocus])
            showActiveWindowInfo(record)
        } else {
            NSApp.activate()
            BorderController.shared.setTarget(nil)
            showActiveWindowInfo(nil)
        }

        TalysDesktopState.shared.activeWorkspace = target
        TalysDesktopState.shared.updateOccupiedWorkspaces()

        onWorkspaceChanged?(target)
    }

    public func moveToWorkspace(_ target: UInt8) {
        guard isActive, !scratchpadWindowFocused else { return }
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
            var landed = target
            // Full already: cascade on to the next workspace with room (never back to where it came from).
            if overflowToWorkspace, !talys_engine_fits_on_workspace(currentFocus, target, Self.getAxScreenRect()) {
                let room = talys_engine_find_room(currentFocus, target, currentWs, Self.getAxScreenRect())
                if room != 0, talys_engine_move_to_workspace(currentFocus, room) {
                    landed = room
                    TalysDesktopState.shared.flashWorkspace(room)
                }
            }
            print("[TilingController] Moved window [ID \(currentFocus)] \"\(record.title)\" to workspace \(landed)")
            WindowAnimator.shared.stop()
            park(record)
            scrolledOff.remove(record.id)
            applyLayout()
            refreshCurtain()
            focusEngineWindow()
            TalysDesktopState.shared.updateOccupiedWorkspaces()
        }
    }

    /// Mirrors the engine's outer gap so the screen rect can line windows up under the bar.
    public private(set) var outerGap: Double = 10.0

    public func setGaps(inner: Double, outer: Double) {
        outerGap = outer
        talys_engine_set_gaps(inner, outer)
        applyLayout()
    }

    public func retileAll() {
        guard isActive else { return }
        print("[TilingController] Retiling all windows...")

        // The engine is about to forget which workspace each window was on; bring parked ones
        // back on screen so they're re-adopted here instead of stranded in the parking lot.
        lock.lock()
        let stranded = parked.filter { !scratchpad.contains($0) }.compactMap { windowMap[$0] }
        lock.unlock()
        for (i, record) in stranded.enumerated() {
            AccessibilityHelper.setFrame(for: record.element, frame: scratchpadFrame(index: i))
        }
        parked = parked.filter { scratchpad.contains($0) }
        scrolledOff.removeAll()
        previousWorkspace = nil

        lock.lock()
        talys_engine_reset()
        // Scratchpad windows aren't in the engine; keep their records (and IDs) so they stay stashed.
        windowMap = windowMap.filter { scratchpad.contains($0.key) }
        lock.unlock()
        minSizes = minSizes.filter { scratchpad.contains($0.key) }

        adoptingExisting = true
        let windows = AccessibilityHelper.getAllStandardWindows()
        for w in windows {
            addWindow(element: w.element, pid: w.pid, title: w.title)
        }
        adoptingExisting = false

        if let focused = AccessibilityHelper.getFocusedWindow() {
            setFocusedWindow(element: focused.element)
        }

        applyLayout()
    }

    /// `snapping`: windows placed instantly instead of animated (e.g. freshly opened ones).
    public func applyLayout(snapping: Set<TalysWindowId> = []) {
        guard isActive else { return }
        let screenRect = Self.getAxScreenRect()
        let screen = CGRect(x: screenRect.x, y: screenRect.y, width: screenRect.width, height: screenRect.height)
        let tiles = layoutFloatingWhatDoesntFit(screenRect)
        layoutTargets.removeAll()
        parkOnArrival.removeAll()
        guard !tiles.isEmpty else {
            BorderController.shared.refresh()
            return
        }

        lock.lock()
        let records = windowMap
        lock.unlock()

        var animationFrames: [(element: AXUIElement, currentFrame: CGRect, targetFrame: CGRect)] = []
        var curtainChanged = false

        for (wid, targetFrame) in tiles {
            guard let record = records[wid] else { continue }

            // Scrolling layout: columns out of view wait in the parking lot, like hidden workspaces.
            if targetFrame.intersection(screen).width < Self.minVisibleWidth {
                scrolledOff.insert(wid)
                if parked.contains(wid) { continue }
                if snapping.contains(wid) || !WindowAnimator.shared.isEnabled {
                    park(record)
                    curtainChanged = true
                } else {
                    // Slide out of view first; `windowPlaced` parks it on arrival.
                    parkOnArrival.insert(wid)
                    let current = AccessibilityHelper.getFrame(for: record.element) ?? targetFrame
                    animationFrames.append((element: record.element, currentFrame: current, targetFrame: targetFrame))
                }
                continue
            }

            layoutTargets[wid] = targetFrame
            var currentFrame = snapping.contains(wid) ? targetFrame : (AccessibilityHelper.getFrame(for: record.element) ?? targetFrame)
            if scrolledOff.remove(wid) != nil, parked.remove(wid) != nil {
                curtainChanged = true
                // Scrolled back into view: slide in from the edge it left by.
                if !snapping.contains(wid) {
                    let dx = targetFrame.midX < screen.midX ? -targetFrame.width : targetFrame.width
                    currentFrame = targetFrame.offsetBy(dx: dx, dy: 0)
                }
            }
            animationFrames.append((element: record.element, currentFrame: currentFrame, targetFrame: targetFrame))
        }

        WindowAnimator.shared.animate(frames: animationFrames)
        if curtainChanged { refreshCurtain() }
        BorderController.shared.refresh()
        followOverflow()
    }

    /// Switches to the workspace a newly opened window overflowed to, once the layout pass that moved it is done.
    private func followOverflow() {
        guard let ws = pendingFollow else { return }
        pendingFollow = nil
        DispatchQueue.main.async {
            MainActor.assumeIsolated { TilingController.shared.switchWorkspace(ws, backAndForth: false) }
        }
    }

    /// Runs the engine's layout. In tiling layouts where a window's minimum size can't fit any split, the newest
    /// such window moves to the next workspace with room (or floats, centred on top, when there's none or
    /// overflow is set to float) and the layout reruns, until everything left fits.
    private func layoutFloatingWhatDoesntFit(_ screenRect: TalysRect) -> [(TalysWindowId, CGRect)] {
        let maxCount = 128
        var outIds = [TalysWindowId](repeating: 0, count: maxCount)
        var outRects = [TalysRect](repeating: TalysRect(x: 0, y: 0, width: 0, height: 0), count: maxCount)

        while true {
            let count = Int(talys_engine_calculate_layout(screenRect, maxCount, &outIds, &outRects))
            let tiles = (0..<count).map { i in
                (outIds[i], CGRect(x: outRects[i].x, y: outRects[i].y, width: outRects[i].width, height: outRects[i].height))
            }

            let mode = Int32(talys_engine_get_layout_mode())
            guard count > 1, mode == TALYS_LAYOUT_DWINDLE || mode == TALYS_LAYOUT_MASTER_STACK, !talys_engine_is_fullscreen() else {
                return tiles
            }
            // Same floor the engine lays out with, so a window it couldn't fit is never left in a sliver.
            let tooSmall = tiles.filter { wid, tile in
                let min = minSizes[wid] ?? .zero
                return Swift.max(min.width, Self.minTile.width) > tile.width + 1
                    || Swift.max(min.height, Self.minTile.height) > tile.height + 1
            }
            guard let newest = tooSmall.map(\.0).max() else { return tiles }

            lock.lock()
            let record = windowMap[newest]
            lock.unlock()

            if overflowToWorkspace, moveToWorkspaceWithRoom(newest, record: record, screenRect: screenRect) {
                continue
            }

            _ = talys_engine_toggle_float(newest)
            if let record {
                print("[TilingController] Window [ID \(newest)] \"\(record.title)\" can't shrink to fit a tile; floating it")
                AccessibilityHelper.setFrame(for: record.element, frame: centredFrame(fitting: minSizes[newest] ?? .zero, in: screenRect))
            }
        }
    }

    /// Sends a window that doesn't fit here to the next workspace with room. A freshly opened one takes the view
    /// along (when `overflowFollow`); anything else just flashes its new workspace in the bar.
    private func moveToWorkspaceWithRoom(_ wid: TalysWindowId, record: WindowRecord?, screenRect: TalysRect) -> Bool {
        let currentWs = talys_engine_get_active_workspace()
        let room = talys_engine_find_room(wid, currentWs, 0, screenRect)
        guard room != 0, talys_engine_move_to_workspace(wid, room) else { return false }

        print("[TilingController] Window [ID \(wid)] \"\(record?.title ?? "")\" doesn't fit workspace \(currentWs); moved to \(room)")
        let now = ProcessInfo.processInfo.systemUptime
        let isNew = !adoptingExisting && (settling[wid].map { $0 > now } ?? false)
        settling.removeValue(forKey: wid)
        scrolledOff.remove(wid)
        parkOnArrival.remove(wid)
        if let record {
            WindowAnimator.shared.stop()
            park(record)
            refreshCurtain()
        }
        if isNew && overflowFollow {
            pendingFollow = room
        } else {
            TalysDesktopState.shared.flashWorkspace(room)
        }
        TalysDesktopState.shared.updateOccupiedWorkspaces()
        return true
    }

    /// Hands a new window the minimum size its app is known to need, so it's placed right from the start.
    private func applyRememberedMinSize(_ wid: TalysWindowId, pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let size = MinSizeStore.shared.size(forApp: app) else { return }
        minSizes[wid] = size
        talys_engine_set_min_size(wid, size.width, size.height)
    }

    private func centredFrame(fitting min: CGSize, in screenRect: TalysRect) -> CGRect {
        let bounds = CGRect(x: screenRect.x, y: screenRect.y, width: screenRect.width, height: screenRect.height)
            .insetBy(dx: outerGap, dy: outerGap)
        let w = Swift.min(bounds.width, Swift.max(min.width, bounds.width * 0.5))
        let h = Swift.min(bounds.height, Swift.max(min.height, bounds.height * 0.6))
        return CGRect(x: bounds.midX - w / 2, y: bounds.midY - h / 2, width: w, height: h)
    }

    /// Drops what's known about windows that are gone.
    private func forget(_ wids: [TalysWindowId]) {
        for wid in wids {
            minSizes.removeValue(forKey: wid)
            scrolledOff.remove(wid)
            parkOnArrival.remove(wid)
        }
    }

    /// Called once the animator has given a window its final frame.
    fileprivate func windowPlaced(element: AXUIElement, target: CGRect) {
        guard isActive, let record = findRecord(for: element) else { return }
        if parkOnArrival.remove(record.id) != nil {
            if scrolledOff.contains(record.id) {
                park(record)
                refreshCurtain()
            }
            return
        }
        guard layoutTargets[record.id] == target, let actual = AccessibilityHelper.getFrame(for: element) else { return }
        learnMinSize(record.id, actual: actual.size, requested: target.size)
        keepOnScreen(element: element, record: record, actual: actual, target: target)
    }

    /// An app that ends up bigger than the tile it was given has hit its minimum size on that axis. Record it
    /// and lay out again, so the tile grows to fit (or the window floats if nothing can).
    private func learnMinSize(_ wid: TalysWindowId, actual: CGSize, requested: CGSize) {
        let old = minSizes[wid] ?? .zero
        var new = old
        if actual.width > requested.width + 1 { new.width = Swift.max(old.width, actual.width) }
        if actual.height > requested.height + 1 { new.height = Swift.max(old.height, actual.height) }
        guard new != old else { return }

        minSizes[wid] = new
        talys_engine_set_min_size(wid, new.width, new.height)
        lock.lock()
        let pid = windowMap[wid]?.pid
        lock.unlock()
        if let pid, let app = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier {
            MinSizeStore.shared.record(new, forApp: app)
        }
        print("[TilingController] Window [ID \(wid)] won't go below \(Int(new.width))×\(Int(new.height)); relaying out")
        guard !relayoutPending else { return }
        relayoutPending = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let tc = TilingController.shared
                tc.relayoutPending = false
                tc.applyLayout()
            }
        }
    }

    /// A window moved or resized. Parked ones get the curtain re-fitted; settling ones that the app pulled out
    /// of their tile are snapped back.
    public func windowFrameChanged(element: AXUIElement) {
        guard isActive, let record = findRecord(for: element) else { return }
        let wid = record.id

        if parked.contains(wid) {
            coverParked()
            return
        }

        guard let deadline = settling[wid] else { return }
        guard ProcessInfo.processInfo.systemUptime < deadline else {
            settling.removeValue(forKey: wid)
            return
        }
        guard !talys_engine_is_floating(wid),
              !WindowAnimator.shared.isAnimating(element),
              let target = layoutTargets[wid],
              let frame = AccessibilityHelper.getFrame(for: element) else { return }

        let drift = max(abs(frame.minX - target.minX), abs(frame.minY - target.minY),
                        abs(frame.width - target.width), abs(frame.height - target.height))
        guard drift >= 2 else { return }
        AccessibilityHelper.setFrame(for: element, frame: target)

        // Still bigger than its tile after being put back: the app can't go that small. Learn it rather than
        // fighting it (which leaves it stuck behind its neighbour).
        if let after = AccessibilityHelper.getFrame(for: element),
           after.width > target.width + 1 || after.height > target.height + 1 {
            learnMinSize(wid, actual: after.size, requested: target.size)
            keepOnScreen(element: element, record: record, actual: after, target: target)
        }
    }

    /// Until the relayout that makes room for it, a window stuck at its minimum size may hang off the screen
    /// edge. Slide it back inside the usable area and remember where it ended up, so the settle check doesn't
    /// keep fighting the app.
    private func keepOnScreen(element: AXUIElement, record: WindowRecord, actual: CGRect, target: CGRect) {
        guard actual.width > target.width + 1 || actual.height > target.height + 1 else { return }

        let r = Self.getAxScreenRect()
        let bounds = CGRect(x: r.x, y: r.y, width: r.width, height: r.height).insetBy(dx: outerGap, dy: outerGap)
        var origin = actual.origin
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - actual.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - actual.height))

        if origin != actual.origin {
            AccessibilityHelper.setPosition(for: element, to: origin)
        }
        layoutTargets[record.id] = CGRect(origin: origin, size: actual.size)
    }

    // MARK: - Home Space

    /// Pauses on other Spaces, then picks up where it left off, adopting windows that appeared meanwhile.
    public func setAwayFromHome(_ away: Bool) {
        guard away != isAwayFromHome else { return }
        isAwayFromHome = away
        TalysDesktopState.shared.isAwayFromHome = away

        if away {
            print("[TilingController] Paused: not on the home desktop.")
            WindowAnimator.shared.stop()
            BorderController.shared.setTarget(nil)
            CurtainController.shared.hide()
            showActiveWindowInfo(nil)
            return
        }

        print("[TilingController] Resumed on the home desktop.")
        guard isEnabled else { return }
        adoptingExisting = true
        for w in AccessibilityHelper.getAllStandardWindows() {
            addWindow(element: w.element, pid: w.pid, title: w.title)
        }
        adoptingExisting = false
        applyLayout()
        refreshCurtain()
        syncCurrentFocus()
    }

    // MARK: - Scratchpad

    private func isScratchpad(_ wid: TalysWindowId) -> Bool {
        scratchpad.contains(wid)
    }

    private func updateScratchpadState() {
        if scratchpad.isEmpty { scratchpadVisible = false }
        TalysDesktopState.shared.scratchpadCount = scratchpad.count
        TalysDesktopState.shared.scratchpadVisible = scratchpadVisible
    }

    /// Sends the focused window to the scratchpad, or back to the active workspace if it's already there.
    public func moveFocusedToScratchpad() {
        guard isActive, let front = AccessibilityHelper.getFocusedWindow(), let record = findRecord(for: front.element) else { return }

        if isScratchpad(record.id) {
            scratchpad.removeAll { $0 == record.id }
            parked.remove(record.id)
            talys_engine_add_window(record.id)
            if let min = minSizes[record.id] {
                talys_engine_set_min_size(record.id, min.width, min.height)
            }
            talys_engine_set_focus(record.id)
            print("[TilingController] Window [ID \(record.id)] \"\(record.title)\" left the scratchpad")
            updateScratchpadState()
            applyLayout()
            TalysDesktopState.shared.updateOccupiedWorkspaces()
            return
        }

        talys_engine_remove_window(record.id)
        scratchpad.append(record.id)
        print("[TilingController] Window [ID \(record.id)] \"\(record.title)\" moved to scratchpad")

        if scratchpadVisible {
            AccessibilityHelper.setFrame(for: record.element, frame: scratchpadFrame(index: scratchpad.count - 1))
        } else {
            park(record)
            refreshCurtain()
            focusEngineWindow()
        }
        updateScratchpadState()
        applyLayout()
        TalysDesktopState.shared.updateOccupiedWorkspaces()
    }

    public func toggleScratchpad() {
        guard isActive, !scratchpad.isEmpty else { return }
        scratchpadVisible.toggle()

        lock.lock()
        let records = scratchpad.compactMap { windowMap[$0] }
        lock.unlock()

        if scratchpadVisible {
            for (i, record) in records.enumerated() {
                parked.remove(record.id)
                AccessibilityHelper.setFrame(for: record.element, frame: scratchpadFrame(index: i))
            }
            refreshCurtain()
            if let top = records.last {
                AccessibilityHelper.focusWindow(element: top.element, pid: top.pid)
                BorderController.shared.setTarget(top.element)
            }
        } else {
            for record in records {
                park(record)
            }
            refreshCurtain()
            focusEngineWindow()
        }
        print("[TilingController] Scratchpad \(scratchpadVisible ? "shown" : "hidden") (\(records.count) window(s))")
        updateScratchpadState()
    }

    private func focusEngineWindow() {
        let focus = talys_engine_get_focus()
        lock.lock()
        let record = windowMap[focus]
        lock.unlock()
        if let record {
            AccessibilityHelper.focusWindow(element: record.element, pid: record.pid)
            BorderController.shared.setTarget(record.element)
        } else {
            NSApp.activate()
            BorderController.shared.setTarget(nil)
        }
        showActiveWindowInfo(record)
    }

    // MARK: - Parking

    private func park(_ record: WindowRecord) {
        parked.insert(record.id)
        AccessibilityHelper.setPosition(for: record.element, to: ParkingLot.parkPoint())
    }

    /// Covers whatever sliver of the parked windows macOS keeps on screen. Apps that settle their position
    /// a beat later are re-covered when they move (see `windowFrameChanged`).
    private func refreshCurtain() {
        coverParked()
    }

    private func coverParked() {
        // The curtain shows on every Space, but parked windows only exist on the home one.
        guard !isAwayFromHome else {
            CurtainController.shared.hide()
            return
        }
        lock.lock()
        let elements = parked.compactMap { windowMap[$0]?.element }
        lock.unlock()
        if elements.isEmpty {
            CurtainController.shared.hide()
        } else {
            CurtainController.shared.cover(elements)
        }
    }

    /// Displays changed, so the parking lot moved; bring every parked window along.
    public func repark() {
        lock.lock()
        let records = parked.compactMap { windowMap[$0] }
        lock.unlock()
        for record in records { park(record) }
        refreshCurtain()
    }

    /// Puts every parked window back on screen (centered, cascaded) so quitting never strands one.
    public func unparkAll() {
        lock.lock()
        let records = parked.compactMap { windowMap[$0] }
        lock.unlock()
        for (i, record) in records.enumerated() {
            AccessibilityHelper.setFrame(for: record.element, frame: scratchpadFrame(index: i))
        }
        parked.removeAll()
        CurtainController.shared.hide()
    }

    /// Centered at ~60% of the usable screen, cascading slightly when several windows are stashed.
    private func scratchpadFrame(index: Int) -> CGRect {
        let screen = Self.getAxScreenRect()
        let w = screen.width * 0.6
        let h = screen.height * 0.7
        let offset = Double(index % 5) * 28
        return CGRect(
            x: screen.x + (screen.width - w) / 2 + offset,
            y: screen.y + (screen.height - h) / 2 + offset,
            width: w,
            height: h
        )
    }
}
