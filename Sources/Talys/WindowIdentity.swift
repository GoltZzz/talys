import ApplicationServices

/// AX handles can change while a window keeps its WindowServer identity.
struct WindowIdentity: Equatable {
    let pid: pid_t
    let windowID: CGWindowID

    init?(pid: pid_t, windowID: CGWindowID?) {
        guard pid > 0, let windowID, windowID != 0 else { return nil }
        self.pid = pid
        self.windowID = windowID
    }

    @MainActor
    init?(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return nil }
        self.init(pid: pid, windowID: WindowRecovery.windowID(of: element))
    }
}
