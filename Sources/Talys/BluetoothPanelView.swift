import SwiftUI

/// The Bluetooth panel that drops down from the bar's halo item.
struct BluetoothPanelView: View {
    @State private var bluetooth = BluetoothController.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            PanelDivider()

            if bluetooth.isPowered {
                content
                    .padding(16)
            } else {
                offState
                    .padding(16)
            }

            if let error = bluetooth.errorMessage {
                PanelDivider()
                HStack(alignment: .top, spacing: 7) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .padding(.top, 2)
                    Text(error)
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(Palette.red)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            PanelDivider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .popoverCard(width: 320)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.accent.opacity(bluetooth.isPowered ? 0.18 : 0.08))
                BluetoothIcon(
                    size: CGSize(width: 14, height: 20),
                    color: bluetooth.isPowered ? Palette.accent : Palette.overlay0,
                    slashed: !bluetooth.isPowered
                )
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Bluetooth")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.subtext0)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PillSwitch(isOn: bluetooth.isPowered) { bluetooth.setPowered($0) }
                .opacity(bluetooth.isBusy ? 0.45 : 1)
                .disabled(bluetooth.isBusy)
                .help(bluetooth.isPowered ? "Turn Bluetooth off" : "Turn Bluetooth on")
        }
    }

    private var subtitle: String {
        if let activity = bluetooth.activity { return activity }
        guard bluetooth.isPowered else { return "Off" }
        let count = bluetooth.devices.count
        if count == 0 { return "On · No devices" }
        return "On · \(count) device\(count == 1 ? "" : "s")"
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let primary = bluetooth.primaryDevice {
                connectedSection(primary)
            }

            HStack(spacing: 6) {
                PanelSectionTitle(title: "Paired")
                Spacer()
                SmallIconButton(symbol: "arrow.clockwise", help: "Refresh devices") {
                    bluetooth.refreshNow()
                }
            }

            if bluetooth.devices.isEmpty {
                emptyState
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                          spacing: 8) {
                    ForEach(Array(bluetooth.devices.prefix(8))) { device in
                        DeviceTile(device: device, isBusy: bluetooth.isBusy) {
                            bluetooth.toggleConnection(device)
                        }
                    }
                }

                if bluetooth.devices.count > 8 {
                    Text("\(bluetooth.devices.count - 8) more in Bluetooth Settings…")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.overlay0)
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: bluetooth.devices)
        .animation(.snappy(duration: 0.2), value: bluetooth.primaryDevice?.id)
    }

    private func connectedSection(_ device: BluetoothDevice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                PanelSectionTitle(title: "Connected")
                Spacer()
                if bluetooth.connectedDevices.count > 1 {
                    Text("\(bluetooth.connectedDevices.count) connected")
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.overlay0)
                }
                SmallIconButton(symbol: "xmark.circle", help: "Disconnect \(device.name)") {
                    bluetooth.toggleConnection(device)
                }
            }

            Button {
                bluetooth.toggleConnection(device)
            } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Palette.accent.opacity(0.18))
                        Image(systemName: device.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundStyle(Palette.accent)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Palette.text)
                            .lineLimit(1)
                        Text("\(device.category) · Connected")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(Palette.subtext0)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    if let battery = device.battery {
                        BluetoothBatteryRing(percent: battery, size: 30, lineWidth: 2, showText: true)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Palette.accent)
                    }
                }
                .padding(10)
                .background(Palette.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Palette.accent.opacity(0.24), lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(bluetooth.isBusy || device.address.isEmpty)
            .help([device.batteryHelp, "Click to disconnect"].compactMap { $0 }.joined(separator: " · "))
        }
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 11))
            Text("No paired devices. Add one in Bluetooth Settings.")
                .font(.system(size: 10.5, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(Palette.overlay0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Off

    private var offState: some View {
        HStack(spacing: 10) {
            BluetoothIcon(size: CGSize(width: 12, height: 17), color: Palette.overlay0, slashed: true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bluetooth is off")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Palette.subtext0)
                Text("Turn it on to connect your devices.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Palette.overlay0)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(11)
        .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        Button {
            bluetooth.openSettings()
        } label: {
            HStack {
                Text("Bluetooth Settings…")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Palette.subtext0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Device tile

private struct DeviceTile: View {
    let device: BluetoothDevice
    let isBusy: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .top) {
                    ZStack {
                        Circle()
                            .fill(device.isConnected ? Palette.accent.opacity(0.16) : Palette.surface0.opacity(0.85))
                        Image(systemName: device.symbol)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(device.isConnected ? Palette.accent : Palette.subtext0)
                    }
                    .frame(width: 24, height: 24)

                    Spacer(minLength: 4)

                    if let battery = device.battery {
                        BluetoothBatteryRing(percent: battery, size: 22, lineWidth: 1.6, showText: true)
                    } else if device.isConnected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Palette.accent)
                            .frame(width: 22, height: 22)
                    } else {
                        Image(systemName: "minus")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Palette.overlay0.opacity(0.6))
                            .frame(width: 22, height: 22)
                    }
                }

                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.system(size: 10.5, weight: device.isConnected ? .semibold : .medium))
                        .foregroundStyle(device.isConnected ? Palette.text : Palette.subtext0)
                        .lineLimit(1)
                    Text(device.isConnected ? "Connected" : device.category)
                        .font(.system(size: 8.5, weight: .medium, design: .monospaced))
                        .foregroundStyle(device.isConnected ? Palette.accent : Palette.overlay0)
                        .lineLimit(1)
                }
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(device.isConnected ? Palette.accent.opacity(hovering ? 0.15 : 0.10)
                          : Palette.surface0.opacity(hovering ? 0.5 : 0.32))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .strokeBorder(device.isConnected ? Palette.accent.opacity(0.28) : Color.white.opacity(0.05),
                                  lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy || device.address.isEmpty)
        .help(help)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }

    private var help: String {
        var pieces: [String] = []
        pieces.append(device.isConnected ? "Disconnect \(device.name)" : "Connect \(device.name)")
        if let battery = device.batteryHelp { pieces.append(battery) }
        else if device.battery == nil && device.isConnected { pieces.append("No battery level reported") }
        return pieces.joined(separator: " · ")
    }
}

// MARK: - Small controls

private struct SmallIconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(hovering ? Palette.text : Palette.overlay0)
                .frame(width: 20, height: 20)
                .background(Circle().fill(hovering ? Palette.surface0 : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}
