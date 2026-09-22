import Cocoa
import CoreGraphics

public enum KeyAction: Sendable, CustomStringConvertible {
    case focusDirection(UInt8)
    case swapDirection(UInt8)
    case toggleFloat
    case closeWindow
    case retile
    case resize(Double)
    case toggleFullscreen
    case cycleLayout
    case switchWorkspace(UInt8)
    case moveToWorkspace(UInt8)

    public var description: String {
        switch self {
        case .focusDirection(let d): return "focusDirection(\(d))"
        case .swapDirection(let d): return "swapDirection(\(d))"
        case .toggleFloat: return "toggleFloat"
        case .closeWindow: return "closeWindow"
        case .retile: return "retile"
        case .resize(let delta): return "resize(\(delta))"
        case .toggleFullscreen: return "toggleFullscreen"
        case .cycleLayout: return "cycleLayout"
        case .switchWorkspace(let ws): return "switchWorkspace(\(ws))"
        case .moveToWorkspace(let ws): return "moveToWorkspace(\(ws))"
        }
    }
}

public struct KeyBinding: Hashable, Sendable {
    public let keyCode: UInt16
    public let ctrl: Bool
    public let shift: Bool
    public let cmd: Bool
    public let alt: Bool

    public init(keyCode: UInt16, ctrl: Bool = false, shift: Bool = false, cmd: Bool = false, alt: Bool = false) {
        self.keyCode = keyCode
        self.ctrl = ctrl
        self.shift = shift
        self.cmd = cmd
        self.alt = alt
    }
}

public final class KeyboardManager: @unchecked Sendable {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    public var onAction: (@Sendable (KeyAction) -> Void)?
    public var bindings: [KeyBinding: KeyAction] = [:]

    public init() {
        setupDefaultBindings()
    }

    public func setupDefaultBindings() {
        bindings.removeAll()

        bindings[KeyBinding(keyCode: 4, alt: true)] = .focusDirection(0)
        bindings[KeyBinding(keyCode: 38, alt: true)] = .focusDirection(1)
        bindings[KeyBinding(keyCode: 40, alt: true)] = .focusDirection(2)
        bindings[KeyBinding(keyCode: 37, alt: true)] = .focusDirection(3)

        bindings[KeyBinding(keyCode: 4, shift: true, alt: true)] = .swapDirection(0)
        bindings[KeyBinding(keyCode: 38, shift: true, alt: true)] = .swapDirection(1)
        bindings[KeyBinding(keyCode: 40, shift: true, alt: true)] = .swapDirection(2)
        bindings[KeyBinding(keyCode: 37, shift: true, alt: true)] = .swapDirection(3)

        bindings[KeyBinding(keyCode: 49, alt: true)] = .toggleFloat

        bindings[KeyBinding(keyCode: 12, alt: true)] = .closeWindow

        bindings[KeyBinding(keyCode: 15, alt: true)] = .retile

        bindings[KeyBinding(keyCode: 33, alt: true)] = .resize(-0.05)
        bindings[KeyBinding(keyCode: 30, alt: true)] = .resize(0.05)

        bindings[KeyBinding(keyCode: 3, alt: true)] = .toggleFullscreen

        bindings[KeyBinding(keyCode: 48, alt: true)] = .cycleLayout

        let digitKeyCodes: [(UInt8, UInt16)] = [
            (1, 18), (2, 19), (3, 20), (4, 21), (5, 23),
            (6, 22), (7, 26), (8, 28), (9, 25)
        ]

        for (ws, code) in digitKeyCodes {
            bindings[KeyBinding(keyCode: code, alt: true)] = .switchWorkspace(ws)
            bindings[KeyBinding(keyCode: code, shift: true, alt: true)] = .moveToWorkspace(ws)
        }
    }

    public func start() -> Bool {
        let eventMask = (1 << CGEventType.keyDown.rawValue)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: eventTapCallback,
            userInfo: selfPtr
        ) else {
            print("[KeyboardManager] Failed to create CGEvent tap. Verify Accessibility permissions.")
            return false
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[KeyboardManager] Global event tap successfully active with \(bindings.count) bindings.")
        return true
    }

    public func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
    }

    fileprivate func handleKeyDown(event: CGEvent) -> Bool {
        let flags = event.flags
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        let isCmd = flags.contains(.maskCommand)
        let isAlt = flags.contains(.maskAlternate)
        let isCtrl = flags.contains(.maskControl)
        let isShift = flags.contains(.maskShift)

        let binding = KeyBinding(
            keyCode: keyCode,
            ctrl: isCtrl,
            shift: isShift,
            cmd: isCmd,
            alt: isAlt
        )

        if let action = bindings[binding] {
            print("[KeyboardManager] Matched hotkey -> \(action) (keyCode: \(keyCode))")
            DispatchQueue.main.async { [weak self] in
                self?.onAction?(action)
            }
            return true
        }

        return false
    }

    fileprivate func reenableTap() {
        if let tap = eventTap {
            print("[KeyboardManager] Re-enabling event tap after timeout/disable...")
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }
}

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<KeyboardManager>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        manager.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    let swallowed = manager.handleKeyDown(event: event)
    if swallowed {
        return nil
    } else {
        return Unmanaged.passUnretained(event)
    }
}
