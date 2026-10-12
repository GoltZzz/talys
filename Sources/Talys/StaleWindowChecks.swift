import ApplicationServices

/// An unavailable app must never be interpreted as a closed window.
struct StaleWindowChecks {
    private var misses: [UInt32: Int] = [:]

    static func canCheckRemoval(suspended: Bool, awayFromHome: Bool,
                                uptime: TimeInterval, allowedAfter: TimeInterval) -> Bool {
        !suspended && !awayFromHome && uptime >= allowedAfter
    }

    mutating func shouldRemove(_ id: UInt32, status: AXError, confirmedAbsent: Bool) -> Bool {
        guard status == .invalidUIElement, confirmedAbsent else {
            misses.removeValue(forKey: id)
            return false
        }
        misses[id, default: 0] += 1
        return misses[id, default: 0] >= 3
    }

    mutating func forget(_ id: UInt32) {
        misses.removeValue(forKey: id)
    }
}
