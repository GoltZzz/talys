import Cocoa
@preconcurrency import ApplicationServices

public final class AppWindowObserver: @unchecked Sendable {
    public let pid: pid_t
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?

    public init(pid: pid_t) {
        self.pid = pid
    }

    /// Returns false when the app isn't accepting AX registrations yet (common right after launch).
    @discardableResult
    public func start() -> Bool {
        var obs: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let err = AXObserverCreate(pid, observerCallback, &obs)
        guard err == .success, let axObserver = obs else {
            return false
        }

        self.observer = axObserver
        let appElement = AXUIElementCreateApplication(pid)

        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowMovedNotification,
            kAXWindowResizedNotification
        ]

        var createdRegistered = false
        for notif in notifications {
            let result = AXObserverAddNotification(axObserver, appElement, notif as CFString, selfPtr)
            if notif == kAXWindowCreatedNotification {
                createdRegistered = result == .success || result == .notificationAlreadyRegistered
            }
        }

        guard createdRegistered else {
            self.observer = nil
            return false
        }

        let source = AXObserverGetRunLoopSource(axObserver)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        return true
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        observer = nil
    }

    /// New windows must survive this long before they're tiled, so flash windows (open panels,
    /// Finder's momentary "Recents", splash screens) don't reshuffle the layout.
    private static let transientGrace: TimeInterval = 0.12

    @MainActor
    private func addCreatedWindow(_ element: AXUIElement, attempt: Int) {
        if AccessibilityHelper.isStandardWindow(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.transientGrace) {
                MainActor.assumeIsolated {
                    guard AccessibilityHelper.isElementValid(element),
                          AccessibilityHelper.isStandardWindow(element) else { return }
                    let title = AccessibilityHelper.getTitle(for: element) ?? "Window"
                    TilingController.shared.addWindow(element: element, pid: self.pid, title: title)
                }
            }
        } else if attempt < 5 && AccessibilityHelper.isElementValid(element) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) {
                MainActor.assumeIsolated {
                    self.addCreatedWindow(element, attempt: attempt + 1)
                }
            }
        }
    }

    fileprivate func handleNotification(element: AXUIElement, notification: String) {
        if notification == (kAXWindowCreatedNotification as String) {
            // AX callbacks arrive on the main run loop; handle immediately, retrying briefly
            // for windows whose subrole isn't set yet at creation time.
            MainActor.assumeIsolated {
                self.addCreatedWindow(element, attempt: 0)
            }
        } else if notification == (kAXUIElementDestroyedNotification as String) {
            DispatchQueue.main.async {
                Task { @MainActor in
                    TilingController.shared.removeWindow(element: element)
                }
            }
        } else if notification == (kAXWindowMovedNotification as String) || notification == (kAXWindowResizedNotification as String) {
            MainActor.assumeIsolated {
                if BorderController.shared.isTarget(element) {
                    BorderController.shared.refresh()
                }
            }
        } else if notification == (kAXFocusedWindowChangedNotification as String) {
            DispatchQueue.main.async {
                Task { @MainActor in
                    TilingController.shared.setFocusedWindow(element: element)
                }
            }
        }
    }
}

private func observerCallback(
    _ observer: AXObserver,
    _ element: AXUIElement,
    _ notification: CFString,
    _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon = refcon else { return }
    let appObserver = Unmanaged<AppWindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    appObserver.handleNotification(element: element, notification: notification as String)
}
