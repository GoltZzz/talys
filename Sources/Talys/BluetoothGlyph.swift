import SwiftUI

@MainActor func bluetoothBatteryColor(_ percent: Int) -> Color {
    if percent < 15 { return Palette.red }
    if percent < 30 { return Palette.yellow }
    return Palette.text
}

/// The Bluetooth rune as a vector shape. macOS has no `bluetooth` SF Symbol, so the bar and
/// the panel share this small path instead of carrying an image asset.
struct BluetoothRune: Shape {
    func path(in rect: CGRect) -> Path {
        // 24 × 24 design box; the visible rune spans x 6.2…17.8, y 1…23.
        let x0: CGFloat = 6.2, x1: CGFloat = 17.8
        let y0: CGFloat = 1, y1: CGFloat = 23
        let k = min(rect.width / (x1 - x0), rect.height / (y1 - y0))
        let dx = rect.midX - 12 * k
        let dy = rect.midY - 12 * k
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: dx + x * k, y: dy + y * k)
        }
        var path = Path()
        path.move(to: p(x0, 6.5))
        path.addLine(to: p(x1, 17.5))
        path.addLine(to: p(12, 23))
        path.addLine(to: p(12, 1))
        path.addLine(to: p(x1, 6.5))
        path.addLine(to: p(x0, 17.5))
        return path
    }
}

/// Rune with an optional slash, used for the off state in the bar and panel.
struct BluetoothIcon: View {
    var size: CGSize = CGSize(width: 9, height: 13)
    var color: Color = .primary
    var slashed: Bool = false

    var body: some View {
        ZStack {
            BluetoothRune()
                .stroke(color, style: StrokeStyle(lineWidth: size.height <= 14 ? 1.35 : 1.5,
                                                  lineCap: .round, lineJoin: .round))
                .frame(width: size.width, height: size.height)

            if slashed {
                Rectangle()
                    .fill(Palette.base.opacity(0.95))
                    .frame(width: 2.6, height: size.height + 3)
                    .rotationEffect(.degrees(45))
                Rectangle()
                    .fill(color)
                    .frame(width: 1.2, height: size.height + 2)
                    .rotationEffect(.degrees(45))
            }
        }
        .frame(width: size.width, height: size.height)
    }
}

/// Charge ring used by the bar item and device tiles. The ring is the battery.
struct BluetoothBatteryRing: View {
    var percent: Int
    var size: CGFloat
    var lineWidth: CGFloat
    var showText: Bool = false
    var trackColor: Color = Color.white.opacity(0.10)

    var body: some View {
        ZStack {
            Circle()
                .stroke(trackColor, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(percent) / 100)
                .stroke(bluetoothBatteryColor(percent),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showText {
                Text("\(percent)")
                    .font(.system(size: size * 0.34, weight: .bold, design: .monospaced))
                    .foregroundColor(bluetoothBatteryColor(percent))
            }
        }
        .frame(width: size, height: size)
    }
}
