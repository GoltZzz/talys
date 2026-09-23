import Cocoa
import CoreAudio
import Observation
import CTalysEngine

@Observable
@MainActor
public final class TalysDesktopState {
    public static let shared = TalysDesktopState()

    // MARK: - Window Manager State
    public var activeWorkspace: UInt8 = 1
    public var occupiedWorkspaces: Set<UInt8> = [1]
    public var layoutMode: String = "Dwindle" // Dwindle, Master-Stack, Scrolling, Monocle
    public var activeWindowTitle: String = "Desktop"
    public var activeAppIcon: NSImage? = nil
    public var isTilingEnabled: Bool = true
    public var isAwayFromHome: Bool = false
    public var scratchpadCount: Int = 0
    public var scratchpadVisible: Bool = false
    /// Workspace briefly highlighted in the bar because a window was sent there without the view following.
    public var flashedWorkspace: UInt8? = nil
    private var flashGeneration = 0

    // MARK: - System Metrics
    public var batteryPercent: Int = 100
    public var isCharging: Bool = false
    public var wifiConnected: Bool = true
    public var wifiSSID: String = "Wi-Fi"
    public var volumePercent: Int = 50
    public var isMuted: Bool = false
    public var outputVolumeSettable: Bool = true
    public var outputDeviceID: AudioDeviceID = 0
    public var outputDeviceName: String = ""
    public var outputDevices: [AudioDevice] = []
    public var inputVolumePercent: Int = 0
    public var isInputMuted: Bool = false
    public var inputVolumeSettable: Bool = true
    public var inputDeviceID: AudioDeviceID = 0
    public var inputDeviceName: String = ""
    public var inputDevices: [AudioDevice] = []
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

    public func flashWorkspace(_ ws: UInt8) {
        flashedWorkspace = ws
        flashGeneration += 1
        let generation = flashGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                let state = TalysDesktopState.shared
                if state.flashGeneration == generation { state.flashedWorkspace = nil }
            }
        }
    }

    public func updateLayoutModeFromEngine() {
        let mode = talys_engine_get_layout_mode()
        self.layoutMode = switch mode {
        case UInt8(TALYS_LAYOUT_MASTER_STACK): "Master-Stack"
        case UInt8(TALYS_LAYOUT_MONOCLE): "Monocle"
        case UInt8(TALYS_LAYOUT_SCROLLING): "Scrolling"
        default: "Dwindle"
        }
    }
}
