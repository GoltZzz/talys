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
    /// Workspace we last switched away from, for back-and-forth.
    private var previousWorkspace: UInt8?

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

    private let lock = NSLock()

    public init() {
        talys_engine_init()
        startHealthCheckTimer()
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
        var axY = primaryHeight - visible.origin.y - visible.size.height
        let axW = visible.size.width
        var axH = visible.size.height

        let cfg = barConfig ?? TilingController.shared.barConfig
        if cfg.enabled {
            let reservedTop = cfg.margin_top + cfg.height + cfg.gap
            axY += reservedTop
            axH -= reservedTop
        }

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
        guard isEnabled else { return false }
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

        let currentWs = talys_engine_get_active_workspace()
        let targetWs = matchedRule?.workspace ?? currentWs

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

            // Snap the new window straight into its tile; neighbours still animate.
            applyLayout(snapping: [wid])
            // Some apps restore their saved frame right after showing the window; re-assert once.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.windowMap[wid] != nil else { return }
                    self.applyLayout(snapping: [wid])
                }
            }
        }
        TalysDesktopState.shared.updateOccupiedWorkspaces()
        return true
    }

    /// Picks up any on-screen windows of `app` we aren't tracking yet (addWindow ignores known ones).
    /// Returns how many on-screen windows of the app are tracked afterwards.
    @discardableResult
    public func adoptWindows(of app: NSRunningApplication) -> Int {
        guard isEnabled else { return 0 }
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
        // Stray focus events from windows we just parked must not steal the border, title, or the
        // workspace's remembered focus.
        guard !parked.contains(record.id) else { return }
        BorderController.shared.setTarget(record.element)
        if !isScratchpad(record.id) {
            talys_engine_set_focus(record.id)
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

    /// True when the key window is a stashed scratchpad window, which the engine doesn't know about.
    private var scratchpadWindowFocused: Bool {
        guard let front = AccessibilityHelper.getFocusedWindow(), let record = findRecord(for: front.element) else { return false }
        return isScratchpad(record.id)
    }

    public func toggleFloat() {
        guard !scratchpadWindowFocused else { return }
        syncCurrentFocus()
        let currentFocus = talys_engine_get_focus()
        guard currentFocus != 0 else { return }

        let isFloating = talys_engine_toggle_float(currentFocus)
        print("[TilingController] Window [ID \(currentFocus)] floating: \(isFloating)")
        applyLayout()
    }

    public func closeFocusedWindow() {
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
        TalysDesktopState.shared.updateLayoutModeFromEngine()
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

    /// Switches instantly: hidden windows are parked at full size, shown ones snap into their tiles.
    /// Asking for the active workspace jumps back to the previous one when `backAndForth` is set.
    public func switchWorkspace(_ requested: UInt8, backAndForth: Bool = true) {
        guard isEnabled else { return }
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
        }
        let shown = Set(showIds.prefix(counts.show_count))
        parked.subtract(shown)
        applyLayout(snapping: shown)
        refreshCurtain()

        // Each workspace remembers its own focus in the engine; restore it, or park keyboard focus
        // on the desktop so keystrokes can't reach a hidden window.
        let newFocus = talys_engine_get_focus()
        if newFocus != 0, let record = records[newFocus] {
            AccessibilityHelper.focusWindow(element: record.element, pid: record.pid)
            BorderController.shared.setTarget(record.element)
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
        guard isEnabled, !scratchpadWindowFocused else { return }
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
            WindowAnimator.shared.stop()
            park(record)
            applyLayout()
            refreshCurtain()
            focusEngineWindow()
            TalysDesktopState.shared.updateOccupiedWorkspaces()
        }
    }

    public func setGaps(inner: Double, outer: Double) {
        talys_engine_set_gaps(inner, outer)
        applyLayout()
    }

    public func retileAll() {
        guard isEnabled else { return }
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
        previousWorkspace = nil

        lock.lock()
        talys_engine_reset()
        // Scratchpad windows aren't in the engine; keep their records (and IDs) so they stay stashed.
        windowMap = windowMap.filter { scratchpad.contains($0.key) }
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

    /// `snapping`: windows placed instantly instead of animated (e.g. freshly opened ones).
    public func applyLayout(snapping: Set<TalysWindowId> = []) {
        guard isEnabled else { return }
        let screenRect = Self.getAxScreenRect()
        let maxCount = 128

        var outIds = [TalysWindowId](repeating: 0, count: maxCount)
        var outRects = [TalysRect](repeating: TalysRect(x: 0, y: 0, width: 0, height: 0), count: maxCount)

        let count = Int(talys_engine_calculate_layout(screenRect, maxCount, &outIds, &outRects))
        guard count > 0 else {
            BorderController.shared.refresh()
            return
        }

        lock.lock()
        let records = windowMap
        lock.unlock()

        var animationFrames: [(element: AXUIElement, currentFrame: CGRect, targetFrame: CGRect)] = []

        for i in 0..<count {
            let wid = outIds[i]
            let r = outRects[i]
            guard let record = records[wid] else { continue }

            let targetFrame = CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
            let currentFrame = snapping.contains(wid) ? targetFrame : (AccessibilityHelper.getFrame(for: record.element) ?? targetFrame)

            animationFrames.append((element: record.element, currentFrame: currentFrame, targetFrame: targetFrame))
        }

        WindowAnimator.shared.animate(frames: animationFrames)
        BorderController.shared.refresh()
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
        guard isEnabled, let front = AccessibilityHelper.getFocusedWindow(), let record = findRecord(for: front.element) else { return }

        if isScratchpad(record.id) {
            scratchpad.removeAll { $0 == record.id }
            parked.remove(record.id)
            talys_engine_add_window(record.id)
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
        guard isEnabled, !scratchpad.isEmpty else { return }
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

    /// Covers whatever sliver of the parked windows macOS keeps on screen. Re-checks shortly after,
    /// since some apps settle their position a beat later.
    private func refreshCurtain() {
        coverParked()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated { TilingController.shared.coverParked() }
        }
    }

    private func coverParked() {
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
