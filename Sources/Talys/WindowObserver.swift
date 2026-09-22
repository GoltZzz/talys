import Cocoa
@preconcurrency import ApplicationServices

public final class AppWindowObserver: @unchecked Sendable {
    public let pid: pid_t
    private var observer: AXObserver?
    private var runLoopSource: CFRunLoopSource?

    public init(pid: pid_t) {
        self.pid = pid
    }

    public func start() {
        var obs: AXObserver?
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let err = AXObserverCreate(pid, observerCallback, &obs)
        guard err == .success, let axObserver = obs else {
            return
        }

        self.observer = axObserver
        let appElement = AXUIElementCreateApplication(pid)

        let notifications = [
            kAXWindowCreatedNotification,
            kAXUIElementDestroyedNotification,
            kAXFocusedWindowChangedNotification
        ]

        for notif in notifications {
            AXObserverAddNotification(axObserver, appElement, notif as CFString, selfPtr)
        }

        let source = AXObserverGetRunLoopSource(axObserver)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    public func stop() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        observer = nil
    }

    fileprivate func handleNotification(element: AXUIElement, notification: String) {
        if notification == (kAXWindowCreatedNotification as String) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if AccessibilityHelper.isStandardWindow(element) {
                    let title = AccessibilityHelper.getTitle(for: element) ?? "Window"
                    TilingController.shared.addWindow(element: element, pid: self.pid, title: title)
                }
            }
        } else if notification == (kAXUIElementDestroyedNotification as String) {
            DispatchQueue.main.async {
                TilingController.shared.removeWindow(element: element)
            }
        } else if notification == (kAXFocusedWindowChangedNotification as String) {
            DispatchQueue.main.async {
                TilingController.shared.setFocusedWindow(element: element)
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
