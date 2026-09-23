import SwiftUI
import Cocoa

// MARK: - Theme Color Tokens
// Reads through ThemeManager so SwiftUI's observation tracking re-renders the bar on theme change.
@MainActor
enum Palette {
    private static var t: Theme { ThemeManager.shared.current }
    static var base: Color { t.base.color }
    static var mantle: Color { t.mantle.color }
    static var surface0: Color { t.surface0.color }
    static var surface1: Color { t.surface1.color }
    static var text: Color { t.text.color }
    static var subtext0: Color { t.subtext0.color }
    static var overlay0: Color { t.overlay0.color }
    static var accent: Color { t.accent.color }
    static var secondary: Color { t.secondary.color }
    static var green: Color { t.green.color }
    static var red: Color { t.red.color }
    static var yellow: Color { t.yellow.color }
    static var crust: Color { t.crust.color }
}

public struct TalysBarView: View {
    @State private var desktopState = TalysDesktopState.shared

    public var onSwitchWorkspace: ((UInt8) -> Void)?
    public var onCycleLayout: (() -> Void)?
    public var onShowBrandMenu: (() -> Void)?
    public var onShowVolumeMenu: (() -> Void)?
    public var onShowWiFiMenu: (() -> Void)?

    public init(
        onSwitchWorkspace: ((UInt8) -> Void)? = nil,
        onCycleLayout: (() -> Void)? = nil,
        onShowBrandMenu: (() -> Void)? = nil,
        onShowVolumeMenu: (() -> Void)? = nil,
        onShowWiFiMenu: (() -> Void)? = nil
    ) {
        self.onSwitchWorkspace = onSwitchWorkspace
        self.onCycleLayout = onCycleLayout
        self.onShowBrandMenu = onShowBrandMenu
        self.onShowVolumeMenu = onShowVolumeMenu
        self.onShowWiFiMenu = onShowWiFiMenu
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left Island: Brand, Workspaces, Focused Window Title
            LeftIslandView(
                desktopState: desktopState,
                onSwitchWorkspace: onSwitchWorkspace,
                onShowBrandMenu: onShowBrandMenu
            )

            Spacer(minLength: 40) // Clearance for camera notch

            // Right Island: Layout, System Status, Clock
            RightIslandView(
                desktopState: desktopState,
                onCycleLayout: onCycleLayout,
                onShowVolumeMenu: onShowVolumeMenu,
                onShowWiFiMenu: onShowWiFiMenu
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
    }
}

// MARK: - Left Island (Workspaces & Window)
private struct LeftIslandView: View {
    let desktopState: TalysDesktopState
    var onSwitchWorkspace: ((UInt8) -> Void)?
    var onShowBrandMenu: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            // Talys Brand Menu Trigger
            Button(action: {
                onShowBrandMenu?()
            }) {
                HStack(spacing: 4) {
                    TalysEggMark()
                        .stroke(desktopState.isTilingEnabled ? Palette.accent : Palette.overlay0,
                                style: StrokeStyle(lineWidth: 0.8, lineCap: .round, lineJoin: .round))
                        .frame(width: 14, height: 16)
                    Text("TALYS")
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .foregroundColor(Palette.text)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Palette.surface0.opacity(0.6))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Workspaces 1..9
            HStack(spacing: 3) {
                ForEach(1...9, id: \.self) { ws in
                    let wsNum = UInt8(ws)
                    let isActive = (wsNum == desktopState.activeWorkspace)
                    let isOccupied = desktopState.occupiedWorkspaces.contains(wsNum)
                    let isFlashed = !isActive && desktopState.flashedWorkspace == wsNum

                    Button(action: {
                        onSwitchWorkspace?(wsNum)
                    }) {
                        Text("\(ws)")
                            .font(.system(size: 11, weight: isActive ? .heavy : .medium, design: .monospaced))
                            .frame(width: isActive ? 22 : 18, height: 20)
                            .foregroundColor(isActive ? Palette.crust : (isOccupied ? Palette.text : Palette.overlay0.opacity(0.7)))
                            .background(
                                isActive
                                    ? Palette.accent
                                    : (isFlashed ? Palette.accent.opacity(0.45)
                                        : (isOccupied ? Palette.surface1.opacity(0.8) : Color.clear))
                            )
                            .clipShape(Capsule())
                            .animation(.easeOut(duration: 0.25), value: isFlashed)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(Palette.base.opacity(0.5))
            .clipShape(Capsule())

            // Paused while on another macOS desktop or a fullscreen app
            if desktopState.isAwayFromHome {
                HStack(spacing: 3) {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 9, weight: .bold))
                    Text("PAUSED")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Palette.crust)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.yellow)
                .clipShape(Capsule())
                .help("Talys is paused on this desktop. Go back to the home desktop to resume tiling.")
            }

            // Scratchpad indicator
            if desktopState.scratchpadCount > 0 {
                HStack(spacing: 3) {
                    Image(systemName: "tray.full.fill")
                        .font(.system(size: 10, weight: .semibold))
                    Text("\(desktopState.scratchpadCount)")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(desktopState.scratchpadVisible ? Palette.crust : Palette.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(desktopState.scratchpadVisible ? Palette.secondary : Palette.surface0.opacity(0.7))
                .clipShape(Capsule())
            }

            // Focused Window Title & App Icon
            if !desktopState.activeWindowTitle.isEmpty {
                Divider()
                    .frame(height: 14)
                    .background(Color.white.opacity(0.15))

                HStack(spacing: 6) {
                    if let icon = desktopState.activeAppIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 14, height: 14)
                    }

                    Text(desktopState.activeWindowTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Palette.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 240, alignment: .leading)
                }
                .padding(.horizontal, 6)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            ZStack {
                Palette.base.opacity(0.82)
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            }
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 2)
    }
}

// MARK: - Right Island (System Metrics & Temporal)
private struct RightIslandView: View {
    let desktopState: TalysDesktopState
    var onCycleLayout: (() -> Void)?
    var onShowVolumeMenu: (() -> Void)?
    var onShowWiFiMenu: (() -> Void)?
    @State private var volumeHovered = false
    @State private var wifiHovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Layout Mode Capsule
            Button(action: {
                onCycleLayout?()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "square.split.bottomrightquarter")
                        .font(.system(size: 10, weight: .semibold))
                    Text(desktopState.layoutMode)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .foregroundColor(Palette.secondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Palette.surface0.opacity(0.7))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            // Audio Volume: click for the sound panel, right-click to mute, scroll to adjust
            HStack(spacing: 3) {
                Image(systemName: volumeIcon)
                    .font(.system(size: 10))
                    .foregroundColor(desktopState.isMuted ? Palette.red : Palette.text)
                    .frame(width: 14)
                Text("\(desktopState.volumePercent)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(desktopState.isMuted ? Palette.overlay0 : Palette.text)
                    .contentTransition(.numericText(value: Double(desktopState.volumePercent)))
                    .animation(.snappy(duration: 0.15), value: desktopState.volumePercent)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(volumeHovered ? Palette.surface0.opacity(0.7) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                PointerInputCatcher(
                    onClick: { onShowVolumeMenu?() },
                    onRightClick: { AudioController.shared.toggleMute() },
                    onScroll: { AudioController.shared.adjustVolume(by: $0) },
                    onHover: { volumeHovered = $0 }
                )
            )
            .help(volumeHelp)
            .padding(.horizontal, -6)

            // Wi-Fi: click for the Wi-Fi panel
            HStack(spacing: 4) {
                Image(systemName: desktopState.wifiConnected ? "wifi" : "wifi.slash")
                    .font(.system(size: 10))
                    .foregroundColor(desktopState.wifiConnected ? Palette.green : Palette.red)
                if !desktopState.wifiSSID.isEmpty && desktopState.wifiSSID != "Wi-Fi" {
                    Text(desktopState.wifiSSID)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Palette.subtext0)
                        .lineLimit(1)
                        .frame(maxWidth: 80)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(wifiHovered ? Palette.surface0.opacity(0.7) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                PointerInputCatcher(
                    onClick: { onShowWiFiMenu?() },
                    onRightClick: {},
                    onScroll: { _ in },
                    onHover: { wifiHovered = $0 }
                )
            )
            .padding(.horizontal, -6)

            // Battery
            HStack(spacing: 3) {
                Image(systemName: batteryIcon)
                    .font(.system(size: 11))
                    .foregroundColor(batteryColor)
                Text("\(desktopState.batteryPercent)%")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(batteryColor)
            }

            Divider()
                .frame(height: 14)
                .background(Color.white.opacity(0.15))

            // Clock & Date
            Button(action: {
                desktopState.showAltClock.toggle()
                SystemMetricsService.shared.refreshAll()
            }) {
                HStack(spacing: 5) {
                    Image(systemName: "clock")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.accent)
                    if !desktopState.dateString.isEmpty && !desktopState.showAltClock {
                        Text(desktopState.dateString)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(Palette.subtext0)
                    }
                    Text(desktopState.timeString)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(Palette.text)
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            ZStack {
                Palette.base.opacity(0.82)
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            }
        )
        .clipShape(Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 6, x: 0, y: 2)
    }

    private var volumeIcon: String {
        if desktopState.isMuted || desktopState.volumePercent == 0 {
            return "speaker.slash.fill"
        } else if desktopState.volumePercent < 33 {
            return "speaker.wave.1.fill"
        } else if desktopState.volumePercent < 66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }

    private var volumeHelp: String {
        let device = desktopState.outputDeviceName.isEmpty ? "Volume" : desktopState.outputDeviceName
        return "\(device) — scroll to adjust, right-click to mute"
    }

    private var batteryIcon: String {
        if desktopState.isCharging {
            return "battery.100.bolt"
        }
        let pct = desktopState.batteryPercent
        if pct > 85 { return "battery.100" }
        if pct > 60 { return "battery.75" }
        if pct > 35 { return "battery.50" }
        if pct > 10 { return "battery.25" }
        return "battery.0"
    }

    private var batteryColor: Color {
        if desktopState.isCharging { return Palette.green }
        if desktopState.batteryPercent < 15 { return Palette.red }
        if desktopState.batteryPercent < 30 { return Palette.yellow }
        return Palette.text
    }
}

// MARK: - Pointer Input Catcher
/// Transparent AppKit layer for input SwiftUI can't express on macOS 14: scroll wheel and right-click.
struct PointerInputCatcher: NSViewRepresentable {
    var onClick: () -> Void
    var onRightClick: () -> Void
    /// Receives a volume delta in 0...1 units; positive means the user pushed up.
    var onScroll: (Float) -> Void
    var onHover: (Bool) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.handlers = self
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.handlers = self
    }

    final class CatcherView: NSView {
        var handlers: PointerInputCatcher?
        private var trackingArea: NSTrackingArea?
        private var preciseAccumulator: CGFloat = 0

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
            addTrackingArea(area)
            trackingArea = area
        }

        override func mouseEntered(with event: NSEvent) { handlers?.onHover(true) }
        override func mouseExited(with event: NSEvent) { handlers?.onHover(false) }
        override func mouseDown(with event: NSEvent) { handlers?.onClick() }
        override func rightMouseDown(with event: NSEvent) { handlers?.onRightClick() }

        override func scrollWheel(with event: NSEvent) {
            // Normalize so "fingers/wheel up" always means louder, regardless of natural scrolling.
            let dy = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
            if event.hasPreciseScrollingDeltas {
                // Trackpad: step in whole percents so a long swipe feels smooth, not jumpy.
                preciseAccumulator += dy * 0.25
                let steps = preciseAccumulator.rounded(.towardZero)
                guard steps != 0 else { return }
                preciseAccumulator -= steps
                handlers?.onScroll(Float(steps) / 100)
            } else if dy != 0 {
                handlers?.onScroll(dy > 0 ? 0.05 : -0.05)
            }
        }
    }
}

// MARK: - AppKit VisualEffectBlur Helper
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// The cracked-egg brand mark at bar size: just the shells, since the eyes and doodles blur at 16pt.
struct TalysEggMark: Shape {
    func path(in rect: CGRect) -> Path {
        // Inset by half a stroke so the outline isn't clipped at the frame edge.
        let t = TalysLogo.transform(fitting: rect.insetBy(dx: 0.4, dy: 0.4))
        let mark = CGMutablePath()
        mark.addPath(TalysLogo.shells, transform: t)
        return Path(mark)
    }
}
