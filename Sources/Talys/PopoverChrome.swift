import SwiftUI

// Shared look for the bar's drop-down panels (sound, Wi-Fi), all driven by the current theme.

extension View {
    /// Wraps panel content in the themed card: blurred backdrop, accent wash, hairline border, shadow and a drop-in.
    func popoverCard(width: CGFloat) -> some View {
        modifier(PopoverCard(width: width))
    }
}

private struct PopoverCard: ViewModifier {
    let width: CGFloat
    @State private var appeared = false

    func body(content: Content) -> some View {
        content
            .frame(width: width)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(0.18), Color.white.opacity(0.04)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 1
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
            .padding(20) // Room for the shadow inside the transparent window.
            .scaleEffect(appeared ? 1 : 0.96, anchor: .top)
            .opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : -6)
            .onAppear {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { appeared = true }
            }
    }

    private var background: some View {
        ZStack {
            VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
            Palette.base.opacity(0.88)
            // A faint wash of the accent from the top gives the panel some depth.
            RadialGradient(colors: [Palette.accent.opacity(0.14), .clear],
                           center: .topLeading, startRadius: 0, endRadius: 260)
        }
    }
}

struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.06))
            .frame(height: 1)
            .padding(.horizontal, 16)
    }
}

/// Small caps label that heads a panel section.
struct PanelSectionTitle: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.4)
            .foregroundStyle(Palette.overlay0)
    }
}

/// Capsule switch in the theme's accent.
struct PillSwitch: View {
    let isOn: Bool
    let onToggle: (Bool) -> Void

    var body: some View {
        Button { onToggle(!isOn) } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Palette.accent : Palette.surface1)
                    .frame(width: 36, height: 20)
                Circle()
                    .fill(isOn ? Palette.crust : Palette.subtext0)
                    .frame(width: 14, height: 14)
                    .padding(3)
            }
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.25, dampingFraction: 0.75), value: isOn)
    }
}
