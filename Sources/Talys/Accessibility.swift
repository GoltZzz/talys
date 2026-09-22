import Cocoa
@preconcurrency import ApplicationServices

public func ensureAccessibilityPermissions(prompt: Bool = true) -> Bool {
    let checkOptPrompt = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
    let options = [checkOptPrompt: prompt] as CFDictionary
    return AXIsProcessTrustedWithOptions(options)
}

public struct ManagedWindow: @unchecked Sendable {
    public let element: AXUIElement
    public let pid: pid_t
    public let title: String
    public let frame: CGRect
}

public enum AccessibilityHelper {

    public static func getAllStandardWindows() -> [ManagedWindow] {
        var result: [ManagedWindow] = []

        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular
        }

        for app in apps {
            let appElement = AXUIElementCreateApplication(app.processIdentifier)
            var windowsRef: CFTypeRef?

            let axErr = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
            guard axErr == .success, let windows = windowsRef as? [AXUIElement] else {
                continue
            }

            for window in windows {
                guard isStandardWindow(window) else {
                    continue
                }

                let title = getTitle(for: window) ?? app.localizedName ?? "Untitled"
                let frame = getFrame(for: window) ?? .zero

                if frame.origin.x < -10000 || frame.origin.y < -10000 {
                    continue
                }

                result.append(ManagedWindow(
                    element: window,
                    pid: app.processIdentifier,
                    title: title,
                    frame: frame
                ))
            }
        }

        return result
    }

    public static func isStandardWindow(_ element: AXUIElement) -> Bool {
        guard let subrole = getSubrole(for: element) else { return false }
        if subrole != (kAXStandardWindowSubrole as String) {
            return false
        }

        var minimizedRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &minimizedRef) == .success,
           let isMinimized = minimizedRef as? Bool, isMinimized {
            return false
        }

        return true
    }

    public static func isElementValid(_ element: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return err == .success
    }

    public static func getFocusedWindow() -> (element: AXUIElement, pid: pid_t)? {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else { return nil }
        let appElement = AXUIElementCreateApplication(frontApp.processIdentifier)
        var windowRef: CFTypeRef?

        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let windowElem = windowRef {
            return (windowElem as! AXUIElement, frontApp.processIdentifier)
        }
        return nil
    }

    public static func getTitle(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &value) == .success {
            return value as? String
        }
        return nil
    }

    public static func getSubrole(for element: AXUIElement) -> String? {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &value) == .success {
            return value as? String
        }
        return nil
    }

    public static func getFrame(for element: AXUIElement) -> CGRect? {
        var posVal: CFTypeRef?
        var sizeVal: CFTypeRef?

        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &posVal) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeVal) == .success else {
            return nil
        }

        var origin = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(posVal as! AXValue, .cgPoint, &origin)
        AXValueGetValue(sizeVal as! AXValue, .cgSize, &size)

        return CGRect(origin: origin, size: size)
    }

    @discardableResult
    public static func setFrame(for element: AXUIElement, frame: CGRect) -> Bool {
        var origin = frame.origin
        var size = frame.size
        var ok = true

        if let posVal = AXValueCreate(.cgPoint, &origin) {
            let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
            if err != .success { ok = false }
        }
        if let sizeVal = AXValueCreate(.cgSize, &size) {
            let err = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, sizeVal)
            if err != .success { ok = false }
        }
        if let posVal = AXValueCreate(.cgPoint, &origin) {
            let err = AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, posVal)
            if err != .success { ok = false }
        }
        return ok
    }

    public static func focusWindow(element: AXUIElement, pid: pid_t) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate()
        }
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    public static func closeWindow(element: AXUIElement) {
        var closeButtonRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeButtonRef) == .success,
           let closeButton = closeButtonRef {
            let err = AXUIElementPerformAction(closeButton as! AXUIElement, kAXPressAction as CFString)
            if err == .success {
                return
            }
        }
        _ = AXUIElementPerformAction(element, "AXPress" as CFString)
    }
}
