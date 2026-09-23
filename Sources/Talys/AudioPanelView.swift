import SwiftUI
import CoreAudio

/// The sound panel that drops down from the bar's volume item.
struct AudioPanelView: View {
    @State private var state = TalysDesktopState.shared
    @State private var meter = InputLevelMeter.shared
    @State private var sources = AudioSourceMonitor.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            PanelDivider()

            outputSection
                .padding(16)

            PanelDivider()

            inputSection
                .padding(16)

            PanelDivider()

            sourcesSection
                .padding(16)
        }
        .popoverCard(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.accent.opacity(state.isMuted ? 0.08 : 0.18))
                Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill",
                      variableValue: Double(state.volumePercent) / 100)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(state.isMuted ? Palette.overlay0 : Palette.accent)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Sound")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(state.outputDeviceName.isEmpty ? "No output" : state.outputDeviceName)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.subtext0)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PillSwitch(isOn: !state.isMuted) { AudioController.shared.setMuted(!$0) }
                .help(state.isMuted ? "Unmute" : "Mute")
        }
    }

    // MARK: - Output

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel(title: "Output", percent: state.volumePercent, dimmed: state.isMuted)

            LevelSlider(
                value: Double(state.volumePercent) / 100,
                dimmed: state.isMuted,
                enabled: state.outputVolumeSettable
            ) { AudioController.shared.setVolume(Float($0)) }

            DeviceList(devices: state.outputDevices, selected: state.outputDeviceID, direction: .output) {
                AudioController.shared.selectOutput($0)
            }
        }
    }

    // MARK: - Input

    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SectionLabel(title: "Input", percent: state.inputVolumePercent, dimmed: state.isInputMuted)
                IconToggle(
                    symbol: state.isInputMuted ? "mic.slash.fill" : "mic.fill",
                    active: state.isInputMuted,
                    help: state.isInputMuted ? "Unmute microphone" : "Mute microphone"
                ) { AudioController.shared.toggleInputMute() }
            }

            LevelSlider(
                value: Double(state.inputVolumePercent) / 100,
                dimmed: state.isInputMuted,
                enabled: state.inputVolumeSettable
            ) { AudioController.shared.setInputVolume(Float($0)) }

            meterRow

            DeviceList(devices: state.inputDevices, selected: state.inputDeviceID, direction: .input) {
                AudioController.shared.selectInput($0)
            }
        }
    }

    @ViewBuilder
    private var meterRow: some View {
        if meter.access == .denied {
            Button {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill").font(.system(size: 9))
                    Text("Allow microphone access to see levels")
                        .font(.system(size: 10, weight: .medium))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(Palette.subtext0)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Palette.surface0.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(.plain)
        } else {
            SegmentMeter(level: meter.level, peak: meter.peak, dimmed: state.isInputMuted)
        }
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("PLAYING")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(Palette.overlay0)
                if !sources.sources.isEmpty {
                    Text("\(sources.sources.count)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(Palette.crust)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Palette.accent, in: Capsule())
                }
                Spacer()
                Button {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.overlay0)
                }
                .buttonStyle(.plain)
                .help("Sound Settings")
            }

            if sources.sources.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "music.note")
                        .font(.system(size: 11))
                    Text("Nothing is playing")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Palette.overlay0)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                VStack(spacing: 4) {
                    ForEach(sources.sources) { SourceRow(source: $0) }
                }
            }
        }
    }
}

// MARK: - Building blocks

private struct SectionLabel: View {
    let title: String
    let percent: Int
    let dimmed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Palette.overlay0)
            Spacer()
            Text("\(percent)")
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(dimmed ? Palette.overlay0 : Palette.text)
                .contentTransition(.numericText(value: Double(percent)))
                .animation(.snappy(duration: 0.15), value: percent)
            Text("%")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.overlay0)
                .padding(.leading, 1)
        }
    }
}

/// Thick themed slider: gradient fill with a soft glow, and a knob that swells while dragging.
private struct LevelSlider: View {
    let value: Double
    let dimmed: Bool
    let enabled: Bool
    let onChange: (Double) -> Void

    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let trackHeight: CGFloat = hovering || dragging ? 8 : 6
            let knob: CGFloat = dragging ? 16 : (hovering ? 14 : 12)
            let fillWidth = max(trackHeight, width * value)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Palette.surface0.opacity(0.9))
                    .frame(height: trackHeight)

                // Quarter ticks, so levels are easy to eyeball.
                ForEach([0.25, 0.5, 0.75], id: \.self) { tick in
                    Circle()
                        .fill(Palette.overlay0.opacity(0.5))
                        .frame(width: 2, height: 2)
                        .offset(x: width * tick - 1)
                }

                Capsule()
                    .fill(LinearGradient(
                        colors: dimmed ? [Palette.overlay0, Palette.overlay0] : [Palette.accent, Palette.secondary],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: fillWidth, height: trackHeight)
                    .shadow(color: dimmed ? .clear : Palette.accent.opacity(dragging ? 0.55 : 0.3),
                            radius: dragging ? 8 : 4)

                if enabled {
                    Circle()
                        .fill(Palette.text)
                        .overlay(Circle().stroke(Palette.base.opacity(0.6), lineWidth: 2))
                        .frame(width: knob, height: knob)
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .offset(x: min(max(0, width * value - knob / 2), width - knob))
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        dragging = true
                        onChange(min(max(0, g.location.x / width), 1))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(height: 18)
        .opacity(enabled ? 1 : 0.5)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: hovering)
        .animation(.snappy(duration: 0.18), value: dragging)
        .help(enabled ? "" : "This device has a fixed volume")
    }
}

/// LED-style input meter: green → yellow → red, with a held peak segment.
private struct SegmentMeter: View {
    let level: Float
    let peak: Float
    let dimmed: Bool
    private let count = 32

    var body: some View {
        let lit = Int((level * Float(count)).rounded())
        let peakIndex = Int((peak * Float(count)).rounded()) - 1

        HStack(spacing: 2) {
            ForEach(0..<count, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(i < lit || i == peakIndex ? color(for: i) : Palette.surface0.opacity(0.7))
                    .opacity(dimmed ? 0.35 : 1)
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.05), value: lit)
        .help("Microphone level")
    }

    private func color(for index: Int) -> Color {
        let position = Double(index) / Double(count)
        if position < 0.65 { return Palette.green }
        if position < 0.85 { return Palette.yellow }
        return Palette.red
    }
}

private struct DeviceList: View {
    let devices: [AudioDevice]
    let selected: AudioDeviceID
    let direction: AudioDirection
    let onSelect: (AudioDeviceID) -> Void

    var body: some View {
        VStack(spacing: 3) {
            ForEach(devices) { device in
                DeviceRow(device: device, direction: direction, isSelected: device.id == selected) {
                    onSelect(device.id)
                }
            }
        }
    }
}

private struct DeviceRow: View {
    let device: AudioDevice
    let direction: AudioDirection
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isSelected ? Palette.accent : Palette.surface0.opacity(0.8))
                    Image(systemName: device.symbol(for: direction))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(isSelected ? Palette.crust : Palette.subtext0)
                }
                .frame(width: 26, height: 26)

                Text(device.name)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Palette.text : Palette.subtext0)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.accent)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Palette.accent.opacity(0.12)
                          : (hovering ? Palette.surface0.opacity(0.55) : .clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Palette.accent.opacity(0.3) : .clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: isSelected)
    }
}

private struct SourceRow: View {
    let source: AudioSource

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = source.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Palette.surface0)
                        Image(systemName: "terminal")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Palette.subtext0)
                    }
                }
            }
            .frame(width: 22, height: 22)

            Text(source.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Palette.text)
                .lineLimit(1)

            Spacer(minLength: 4)

            EqualizerBars()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// Small animated bars signalling that a source is live.
private struct EqualizerBars: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<3, id: \.self) { i in
                    let phase = t * (5.0 + Double(i) * 1.7) + Double(i) * 1.3
                    Capsule()
                        .fill(Palette.accent)
                        .frame(width: 2.5, height: 3 + 8 * (0.5 + 0.5 * sin(phase)))
                }
            }
            .frame(height: 11, alignment: .bottom)
        }
    }
}

private struct IconToggle: View {
    let symbol: String
    let active: Bool
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? Palette.red : (hovering ? Palette.text : Palette.overlay0))
                .frame(width: 22, height: 22)
                .background(
                    Circle().fill(active ? Palette.red.opacity(0.15) : (hovering ? Palette.surface0 : .clear))
                )
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
