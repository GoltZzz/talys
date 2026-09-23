import Cocoa
import Observation
import CTalysEngine

@Observable
@MainActor
public final class TalysDesktopState {
    public static let shared = TalysDesktopState()

    // MARK: - Window Manager State
    public var activeWorkspace: UInt8 = 1
    public var occupiedWorkspaces: Set<UInt8> = [1]
    public var layoutMode: String = "DWN" // DWN, MST, MON
    public var activeWindowTitle: String = "Desktop"
    public var activeAppIcon: NSImage? = nil
    public var isTilingEnabled: Bool = true
    public var scratchpadCount: Int = 0
    public var scratchpadVisible: Bool = false

    // MARK: - System Metrics
    public var batteryPercent: Int = 100
    public var isCharging: Bool = false
    public var wifiConnected: Bool = true
    public var wifiSSID: String = "Wi-Fi"
    public var volumePercent: Int = 50
    public var isMuted: Bool = false
    public var timeString: String = ""
    public var dateString: String = ""
    public var showAltClock: Bool = false

    private init() {
        updateOccupiedWorkspaces()
    }

    public func updateOccupiedWorkspaces() {
        var occupied = Set<UInt8>()
        for ws in 1...9 {
            if talys_engine_get_workspace_window_count(UInt8(ws)) > 0 {
                occupied.insert(UInt8(ws))
            }
        }
        if occupied.isEmpty {
            occupied.insert(activeWorkspace)
        }
        self.occupiedWorkspaces = occupied
    }

    public func updateLayoutModeFromEngine() {
        let mode = talys_engine_get_layout_mode()
        self.layoutMode = switch mode {
        case UInt8(TALYS_LAYOUT_MASTER_STACK): "MST"
        case UInt8(TALYS_LAYOUT_MONOCLE): "MON"
        default: "DWN"
        }
    }
}
