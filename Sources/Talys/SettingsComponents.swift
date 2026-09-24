import Cocoa
import SwiftUI

// Themed building blocks for the settings window. Everything reads the live Talys palette, so the window
// recolors itself when the theme changes.

// MARK: - Page and cards

/// A settings page: big title, a line of explanation, then its cards.
struct SettingsPage<Content: View>: View {
    let title: String
    let subtitle: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                HStack(alignment: .center, spacing: 14) {
                    Image(systemName: symbol)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Palette.crust)
                        .frame(width: 42, height: 42)
                        .background(
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(LinearGradient(colors: [Palette.accent, Palette.secondary],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                        )
                        .shadow(color: Palette.accent.opacity(0.35), radius: 10, y: 4)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(Palette.text)
                        Text(subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(Palette.subtext0)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 44)
            .padding(.bottom, 32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.automatic)
    }
}

/// A titled group of rows on a raised surface.
struct SettingsCard<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if title != nil || trailing != nil {
                HStack {
                    if let title { PanelSectionTitle(title: title) }
                    Spacer()
                    trailing
                }
                .padding(.horizontal, 4)
            }
            VStack(spacing: 0) { content }
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Palette.surface0.opacity(0.45))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                )
            if let footer {
                Text(footer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Palette.overlay0)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
            }
        }
    }
}

struct RowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.05))
            .frame(height: 1)
            .padding(.leading, 16)
    }
}

/// Title (and optional explanation) on the left, a control on the right.
struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var disabled = false
    /// For paths and other text that reads fine cut in the middle.
    var subtitleOneLine = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Palette.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.subtext0)
                        .lineLimit(subtitleOneLine ? 1 : nil)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: !subtitleOneLine)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .frame(minHeight: 48)
        .opacity(disabled ? 0.4 : 1)
        .allowsHitTesting(!disabled)
    }
}

// MARK: - Controls

/// `PillSwitch` bound to a value.
struct ThemedToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        PillSwitch(isOn: isOn) { isOn = $0 }
    }
}

/// Capsule track filled with the accent gradient; snaps to `step`.
struct ThemedSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit = "pt"

    @State private var dragging = false

    var body: some View {
        HStack(spacing: 12) {
            GeometryReader { geo in
                let knob: CGFloat = 16
                let width = geo.size.width - knob
                let fraction = CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(0, 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.surface1.opacity(0.8)).frame(height: 5)
                    Capsule()
                        .fill(LinearGradient(colors: [Palette.accent, Palette.secondary], startPoint: .leading, endPoint: .trailing))
                        .frame(width: fraction * width + knob / 2, height: 5)
                    Circle()
                        .fill(Palette.text)
                        .frame(width: knob, height: knob)
                        .overlay(Circle().strokeBorder(Palette.accent, lineWidth: dragging ? 3 : 0))
                        .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
                        .scaleEffect(dragging ? 1.12 : 1)
                        .offset(x: fraction * width)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            dragging = true
                            let f = Double(((g.location.x - knob / 2) / width).clamped(0, 1))
                            let raw = range.lowerBound + f * (range.upperBound - range.lowerBound)
                            let snapped = ((raw / step).rounded() * step).clamped(range.lowerBound, range.upperBound)
                            if snapped != value { value = snapped }
                        }
                        .onEnded { _ in dragging = false }
                )
                .animation(.spring(response: 0.2, dampingFraction: 0.8), value: dragging)
            }
            .frame(width: 180, height: 22)

            Text(formatted)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.subtext0)
                .frame(width: 58, alignment: .trailing)
        }
    }

    private var formatted: String {
        let number = step < 1 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "\(number) \(unit)"
    }
}

/// Pill segmented control with a sliding accent highlight.
struct SegmentedChoice<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(value: Value, label: String)]
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let selected = option.value == selection
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selection = option.value }
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .fixedSize()
                        .foregroundStyle(selected ? Palette.crust : Palette.subtext0)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background {
                            if selected {
                                Capsule().fill(Palette.accent).matchedGeometryEffect(id: "pill", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .fixedSize()
        .background(Capsule().fill(Palette.crust.opacity(0.6)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.06), lineWidth: 1))
    }
}

/// Drop-down over string values that still shows a hand-written value it doesn't recognise.
struct ThemedMenu: View {
    @Binding var selection: String
    let options: [(value: String, label: String)]

    var body: some View {
        Menu {
            ForEach(allOptions, id: \.value) { option in
                Button {
                    selection = option.value
                } label: {
                    if option.value == selection {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(allOptions.first { $0.value == selection }?.label ?? selection)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Palette.text)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Palette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.crust.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private var allOptions: [(value: String, label: String)] {
        options.contains { $0.value == selection } ? options : options + [(selection, selection)]
    }
}

/// Plain text field on a sunken surface with an accent focus ring.
struct ThemedTextField: View {
    let placeholder: String
    @Binding var text: String
    var monospaced = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(Palette.overlay0))
            .textFieldStyle(.plain)
            .font(.system(size: 12.5, design: monospaced ? .monospaced : .default))
            .foregroundStyle(Palette.text)
            .focused($focused)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.crust.opacity(0.6)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(focused ? Palette.accent.opacity(0.8) : Color.white.opacity(0.08), lineWidth: focused ? 1.5 : 1)
            )
            .animation(.easeOut(duration: 0.15), value: focused)
    }
}

enum ThemedButtonKind { case primary, secondary, destructive, ghost }

struct ThemedButtonStyle: ButtonStyle {
    var kind: ThemedButtonKind = .secondary
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .foregroundStyle(foreground)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background.opacity(hovering ? 1 : 0.85)))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.white.opacity(kind == .ghost ? 0 : 0.08), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Palette.crust
        case .secondary: return Palette.text
        case .destructive: return Palette.red
        case .ghost: return Palette.accent
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return Palette.accent
        case .secondary: return Palette.surface1.opacity(0.7)
        case .destructive: return Palette.red.opacity(0.14)
        case .ghost: return hovering ? Palette.accent.opacity(0.12) : .clear
        }
    }
}

extension ButtonStyle where Self == ThemedButtonStyle {
    static func themed(_ kind: ThemedButtonKind = .secondary) -> ThemedButtonStyle { ThemedButtonStyle(kind: kind) }
}

/// Small round icon button (reset, remove, …).
struct IconButton: View {
    let symbol: String
    var tint: Color? = nil
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint ?? Palette.subtext0)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? (tint ?? Palette.text).opacity(0.14) : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Keycaps

/// One key drawn as a raised cap.
struct Keycap: View {
    let label: String
    var active = false
    var invalid = false
    var size: CGFloat = 11.5

    var body: some View {
        Text(label)
            .font(.system(size: size, weight: .semibold, design: .rounded))
            .foregroundStyle(invalid ? Palette.red : active ? Palette.crust : Palette.text)
            .lineLimit(1)
            .padding(.horizontal, label.count > 1 ? 7 : 0)
            .frame(minWidth: size * 2 + 1, minHeight: size * 2 + 1)
            .background(
                ZStack {
                    // Darker lip under the cap face gives it depth.
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? Palette.accent.opacity(0.6) : Palette.crust)
                        .offset(y: 2)
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(active ? AnyShapeStyle(Palette.accent)
                              : AnyShapeStyle(LinearGradient(colors: [Palette.surface1, Palette.surface0],
                                                             startPoint: .top, endPoint: .bottom)))
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.white.opacity(active ? 0.25 : 0.09), lineWidth: 1)
            )
            .padding(.bottom, 2)
    }
}

struct KeycapRow: View {
    let caps: [String]
    var active = false
    var invalid = false
    var size: CGFloat = 11.5

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Keycap(label: cap, active: active, invalid: invalid, size: size)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }
}

/// Click to record; the next key combo pressed anywhere becomes the shortcut.
struct ShortcutRecorder: View {
    let model: SettingsModel
    let target: SettingsModel.Target
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        let isRecording = model.recording == target
        let shown = model.caps(for: target)
        VStack(alignment: .trailing, spacing: 4) {
            Button {
                isRecording ? model.stopRecording() : model.startRecording(target)
            } label: {
                HStack(spacing: 4) {
                    if isRecording {
                        let m = model.liveModifiers
                        let held = Shortcut.modifierCaps(ctrl: m.contains(.control), alt: m.contains(.option),
                                                         shift: m.contains(.shift), cmd: m.contains(.command))
                        KeycapRow(caps: held, active: true)
                        Text(held.isEmpty ? "Press keys…" : "…")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.accent)
                            .opacity(pulse ? 1 : 0.45)
                    } else if shown.caps.isEmpty {
                        Text("Record")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(hovering ? Palette.accent : Palette.overlay0)
                    } else {
                        KeycapRow(caps: shown.caps, invalid: !shown.valid)
                    }
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.7), value: model.liveModifiers.rawValue)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(minWidth: 92, minHeight: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isRecording ? Palette.accent.opacity(0.12) : hovering ? Palette.surface1.opacity(0.4) : .clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(isRecording ? Palette.accent.opacity(pulse ? 0.95 : 0.4)
                                      : hovering ? Color.white.opacity(0.12) : .clear,
                                      style: StrokeStyle(lineWidth: 1.5, dash: shown.caps.isEmpty && !isRecording ? [4, 3] : []))
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .help(isRecording ? "Press the new shortcut. Esc cancels, ⌫ clears."
                  : shown.valid ? "Click to record a new shortcut" : "Talys can't read this shortcut. Record a new one.")
            .onChange(of: isRecording, initial: true) { _, recording in
                if recording {
                    withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { pulse = true }
                } else {
                    withAnimation(.easeOut(duration: 0.15)) { pulse = false }
                }
            }

            if isRecording, let hint = model.recordingHint {
                Text(hint)
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.yellow)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Window chrome

/// Clicking empty space here drags the window, standing in for the hidden title bar.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }

    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension Comparable {
    func clamped(_ lower: Self, _ upper: Self) -> Self { min(max(self, lower), upper) }
}
