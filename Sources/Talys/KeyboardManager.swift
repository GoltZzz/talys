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
    case exec(String)
    case toggleLauncher
    case toggleScratchpad
    case moveToScratchpad
    case cycleTheme
    case toggleAnimations
    case cycleColumnWidth
    case consumeOrExpel(UInt8)

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
        case .exec(let cmd): return "exec(\(cmd))"
        case .toggleLauncher: return "toggleLauncher"
        case .toggleScratchpad: return "toggleScratchpad"
        case .moveToScratchpad: return "moveToScratchpad"
        case .cycleTheme: return "cycleTheme"
        case .toggleAnimations: return "toggleAnimations"
        case .cycleColumnWidth: return "cycleColumnWidth"
        case .consumeOrExpel(let d): return "consumeOrExpel(\(d))"
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
        bindings = ConfigManager.buildBindings(for: TalysConfig())
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
