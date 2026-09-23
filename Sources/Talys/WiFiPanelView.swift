import SwiftUI

/// The Wi-Fi panel that drops down from the bar's Wi-Fi item.
struct WiFiPanelView: View {
    @State private var wifi = WiFiController.shared
    @State private var listHeight: CGFloat = 0
    /// Screen space below the card's top edge; the network list shrinks so the card never runs off screen.
    var availableHeight: CGFloat = .infinity

    /// Everything in the card besides the network list (header, details, section titles, footer, padding).
    private var chromeHeight: CGFloat { wifi.details == nil ? 170 : 390 }
    private var maxListHeight: CGFloat { max(120, min(300, availableHeight - chromeHeight)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 14)

            if wifi.isPowered {
                if let details = wifi.details {
                    PanelDivider()
                    connectionSection(details)
                        .padding(16)
                }

                PanelDivider()
                networksSection
                    .padding(16)
            } else {
                PanelDivider()
                offState
                    .padding(16)
            }

            PanelDivider()
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .popoverCard(width: 320)
        .animation(.snappy(duration: 0.2), value: wifi.isPowered)
        .animation(.snappy(duration: 0.2), value: wifi.currentSSID)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.accent.opacity(wifi.isPowered ? 0.18 : 0.08))
                Image(systemName: wifi.isPowered ? "wifi" : "wifi.slash",
                      variableValue: wifi.details.map { Double(signalBars($0.rssi)) / 3 } ?? 1)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(wifi.isPowered ? Palette.accent : Palette.overlay0)
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 2) {
                Text("Wi-Fi")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Palette.text)
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Palette.subtext0)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            PillSwitch(isOn: wifi.isPowered) { wifi.setPower($0) }
                .help(wifi.isPowered ? "Turn Wi-Fi off" : "Turn Wi-Fi on")
        }
    }

    private var subtitle: String {
        if !wifi.isPowered { return "Off" }
        if let joining = wifi.joiningSSID { return "Joining \(joining)…" }
        if wifi.details != nil { return wifi.currentSSID ?? "Connected" }
        return "Not connected"
    }

    // MARK: - Connection

    private func connectionSection(_ details: WiFiDetails) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                PanelSectionTitle(title: "Connected")
                Spacer()
                SmallIconButton(symbol: "xmark.circle", help: "Disconnect") { wifi.disconnect() }
            }

            NetworkRowLabel(
                name: wifi.currentSSID ?? "Hidden network",
                bars: signalBars(details.rssi),
                isSecure: details.security != "Open",
                trailing: details.standard,
                isSelected: true
            )

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                GridRow {
                    DetailCell(label: "IP address", value: details.ipAddress ?? "—")
                    DetailCell(label: "Router", value: details.router ?? "—")
                }
                GridRow {
                    DetailCell(label: "Signal · \(quality(details.rssi))", value: "\(details.rssi) dBm")
                    DetailCell(label: "Noise", value: "\(details.noise) dBm")
                }
                GridRow {
                    DetailCell(label: "Channel", value: details.channel ?? "—")
                    DetailCell(label: "Speed", value: "\(Int(details.txRate)) Mbps")
                }
                GridRow {
                    DetailCell(label: "Security", value: details.security)
                    DetailCell(label: "Standard", value: details.standard ?? "—")
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    // MARK: - Networks

    private var networksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                PanelSectionTitle(title: "Networks")
                Spacer()
                if wifi.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Palette.overlay0)
                } else {
                    SmallIconButton(symbol: "arrow.clockwise", help: "Scan again") { wifi.scan() }
                }
            }

            if wifi.locationDenied {
                NoticeButton(
                    symbol: "location.slash.fill",
                    text: "Allow Location access to see network names",
                    action: wifi.openLocationSettings
                )
            }

            if wifi.knownNetworks.isEmpty && wifi.otherNetworks.isEmpty {
                emptyNetworks
            } else {
                // Size the scroll area to its content, capped so a busy area doesn't run off screen.
                ScrollView(.vertical) {
                    networkLists
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                .scrollIndicators(.never)
                .frame(height: min(listHeight, maxListHeight))
            }
        }
    }

    private var networkLists: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !wifi.knownNetworks.isEmpty {
                networkGroup(title: "Known", networks: wifi.knownNetworks)
            }
            if !wifi.otherNetworks.isEmpty {
                networkGroup(title: "Other", networks: wifi.otherNetworks)
            }
        }
    }

    private func networkGroup(title: String, networks: [WiFiNetwork]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Palette.subtext0)
                .padding(.leading, 6)
            VStack(spacing: 3) {
                ForEach(networks) { network in
                    NetworkRow(network: network, wifi: wifi)
                }
            }
        }
    }

    private var emptyNetworks: some View {
        HStack(spacing: 8) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.system(size: 11))
            Text(wifi.hasScanned ? "No other networks found" : "Looking for networks…")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Palette.overlay0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var offState: some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11))
            Text("Wi-Fi is off")
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(Palette.overlay0)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
        .background(Palette.surface0.opacity(0.35), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: - Footer

    private var footer: some View {
        FooterLink(title: "Wi-Fi Settings…", action: wifi.openSettings)
    }

    // MARK: - Helpers

    private func signalBars(_ rssi: Int) -> Int {
        WiFiNetwork.bars(forRSSI: rssi)
    }

    private func quality(_ rssi: Int) -> String {
        ["Weak", "Fair", "Good", "Excellent"][signalBars(rssi)]
    }
}

// MARK: - Building blocks

/// A nearby network. Click to join; secure networks without a saved password expand into a password field.
private struct NetworkRow: View {
    let network: WiFiNetwork
    let wifi: WiFiController
    @State private var hovering = false
    @State private var password = ""
    @FocusState private var fieldFocused: Bool

    private var isPrompting: Bool { wifi.passwordPromptSSID == network.ssid }
    private var isJoining: Bool { wifi.joiningSSID == network.ssid }

    var body: some View {
        VStack(spacing: 0) {
            Button { wifi.select(network) } label: {
                NetworkRowLabel(
                    name: network.ssid,
                    bars: network.bars,
                    isSecure: network.isSecure,
                    trailing: network.band,
                    isSelected: false,
                    isBusy: isJoining
                )
            }
            .buttonStyle(.plain)
            .disabled(wifi.joiningSSID != nil)

            if isPrompting {
                passwordField
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                    .padding(.top, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isPrompting ? Palette.surface0.opacity(0.55)
                      : (hovering ? Palette.surface0.opacity(0.55) : .clear))
        )
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
        .animation(.snappy(duration: 0.2), value: isPrompting)
        .onChange(of: isPrompting) { _, prompting in
            if prompting {
                fieldFocused = true
            } else {
                password = ""
            }
        }
    }

    private var passwordField: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SecureField("Password", text: $password)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Palette.text)
                    .focused($fieldFocused)
                    .onSubmit(join)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Palette.base.opacity(0.7), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(fieldFocused ? Palette.accent.opacity(0.6) : Palette.surface1, lineWidth: 1)
                    )

                Button(action: join) {
                    Text("Join")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.crust)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Palette.accent.opacity(password.isEmpty ? 0.4 : 1),
                                    in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(password.isEmpty || isJoining)
            }

            if let error = wifi.joinError {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Palette.red)
            }
        }
    }

    private func join() {
        guard !password.isEmpty else { return }
        wifi.join(network, password: password)
    }
}

private struct NetworkRowLabel: View {
    let name: String
    let bars: Int
    let isSecure: Bool
    let trailing: String?
    let isSelected: Bool
    var isBusy = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isSelected ? Palette.accent : Palette.surface0.opacity(0.8))
                Image(systemName: "wifi", variableValue: Double(bars) / 3)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(isSelected ? Palette.crust : Palette.subtext0)
            }
            .frame(width: 26, height: 26)

            Text(name)
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? Palette.text : Palette.subtext0)
                .lineLimit(1)

            if isSecure {
                Image(systemName: "lock.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Palette.overlay0)
            }

            Spacer(minLength: 4)

            if isBusy {
                ProgressView().controlSize(.mini)
            } else {
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Palette.overlay0)
                }
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.accent)
                }
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Palette.accent.opacity(0.12) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Palette.accent.opacity(0.3) : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

private struct DetailCell: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Palette.overlay0)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Palette.text)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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

private struct NoticeButton: View {
    let symbol: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).font(.system(size: 9))
                Text(text).font(.system(size: 10, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(Palette.subtext0)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Palette.surface0.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct FooterLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(hovering ? Palette.text : Palette.subtext0)
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Palette.surface0.opacity(0.55) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
