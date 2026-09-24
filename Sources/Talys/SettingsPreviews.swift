import Cocoa
import SwiftUI

// Illustrations for the settings window: the live desktop preview, layout cards, theme swatches and the
// keybinding cheat sheet.

// MARK: - Layout geometry

enum LayoutGeometry {
    static let all: [(value: String, label: String, blurb: String)] = [
        ("dwindle", "Dwindle", "Each new window splits the last one in half"),
        ("master_stack", "Master-Stack", "One big window, the rest stacked beside it"),
        ("scrolling", "Scrolling", "Columns scroll sideways instead of shrinking"),
        ("monocle", "Monocle", "One window at a time, full size"),
    ]

    /// Where three windows land in `area` for `layout`. The first rect is the focused window.
    static func rects(_ layout: String, in area: CGRect, gap: CGFloat) -> [CGRect] {
        let a = area
        switch layout {
        case "master_stack":
            let masterW = (a.width - gap) * 0.58
            let stackX = a.minX + masterW + gap
            let stackW = a.width - masterW - gap
            let stackH = (a.height - gap) / 2
            return [
                CGRect(x: a.minX, y: a.minY, width: masterW, height: a.height),
                CGRect(x: stackX, y: a.minY, width: stackW, height: stackH),
                CGRect(x: stackX, y: a.minY + stackH + gap, width: stackW, height: stackH),
            ]
        case "scrolling":
            // Columns keep their width; the third one runs off the right edge.
            let colW = (a.width - gap) * 0.46
            return [
                CGRect(x: a.minX + colW + gap, y: a.minY, width: colW, height: a.height),
                CGRect(x: a.minX, y: a.minY, width: colW, height: a.height),
                CGRect(x: a.minX + 2 * (colW + gap), y: a.minY, width: colW, height: a.height),
            ]
        case "monocle":
            return [a]
        default:
            let halfW = (a.width - gap) / 2
            let rightX = a.minX + halfW + gap
            let halfH = (a.height - gap) / 2
            return [
                CGRect(x: a.minX, y: a.minY, width: halfW, height: a.height),
                CGRect(x: rightX, y: a.minY, width: halfW, height: halfH),
                CGRect(x: rightX, y: a.minY + halfH + gap, width: halfW, height: halfH),
            ]
        }
    }

    static func normalize(_ layout: String) -> String {
        switch layout.lowercased() {
        case "master-stack": return "master_stack"
        case "scroll": return "scrolling"
        default: return layout.lowercased()
        }
    }
}

// MARK: - Desktop preview

/// A scaled-down screen showing the current gaps, borders, bar and layout, updating as sliders move.
struct DesktopPreview: View {
    let config: TalysConfig
    var highlightBar = false

    /// A laptop-sized screen: scaling a large external display down would shrink gaps to a hairline.
    private let screen = CGSize(width: 1280, height: 800)

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width / screen.width
            let barShown = config.bar.enabled && config.bar.menu_bar.lowercased() != "macos"
            let outer = config.gaps.outer * s
            let top = barShown ? (config.bar.margin_top + config.bar.height + config.bar.gap) * s : outer
            let area = CGRect(x: outer, y: top, width: geo.size.width - 2 * outer,
                              height: geo.size.height - top - outer)
            let windows = LayoutGeometry.rects(LayoutGeometry.normalize(config.general.layout), in: area,
                                               gap: config.gaps.inner * s)
            let radius = max(2, config.borders.radius * s * 1.6)

            ZStack(alignment: .topLeading) {
                wallpaper

                if barShown {
                    bar
                        .frame(width: max(0, geo.size.width - 2 * config.bar.margin_horizontal * s),
                               height: max(6, config.bar.height * s))
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Palette.base.opacity(0.95)))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(highlightBar ? Palette.accent : Color.white.opacity(0.08), lineWidth: highlightBar ? 1.2 : 0.8)
                        )
                        .offset(x: config.bar.margin_horizontal * s, y: config.bar.margin_top * s)
                }

                ForEach(Array(windows.enumerated().reversed()), id: \.offset) { index, rect in
                    PreviewWindow(focused: index == 0, radius: radius, borders: config.borders, scale: s)
                        .frame(width: max(0, rect.width), height: max(0, rect.height))
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: windows)
        }
        .aspectRatio(screen.width / screen.height, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.3), radius: 14, y: 8)
    }

    private var wallpaper: some View {
        ZStack {
            LinearGradient(colors: [Palette.mantle, Palette.crust], startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Palette.accent.opacity(0.28), .clear], center: .bottomLeading, startRadius: 0, endRadius: 320)
            RadialGradient(colors: [Palette.secondary.opacity(0.22), .clear], center: .topTrailing, startRadius: 0, endRadius: 280)
        }
    }

    private var bar: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { i in
                Capsule().fill(i == 0 ? Palette.accent : Palette.overlay0.opacity(0.6))
                    .frame(width: i == 0 ? 12 : 5, height: 5)
            }
            Spacer()
            Capsule().fill(Palette.subtext0.opacity(0.6)).frame(width: 22, height: 4)
        }
        .padding(.horizontal, 7)
    }
}

private struct PreviewWindow: View {
    let focused: Bool
    let radius: CGFloat
    let borders: BordersConfig
    let scale: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2.5) {
                ForEach([Palette.red, Palette.yellow, Palette.green].indices, id: \.self) { i in
                    Circle().fill([Palette.red, Palette.yellow, Palette.green][i].opacity(0.85)).frame(width: 4, height: 4)
                }
            }
            .padding(5)
            VStack(alignment: .leading, spacing: 3) {
                Capsule().fill(Palette.overlay0.opacity(0.5)).frame(width: 30, height: 3)
                Capsule().fill(Palette.overlay0.opacity(0.35)).frame(width: 22, height: 3)
                Capsule().fill(Palette.overlay0.opacity(0.35)).frame(width: 26, height: 3)
            }
            .padding(.horizontal, 6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(shape.fill(Palette.base))
        .clipShape(shape)
        .overlay {
            if focused && borders.enabled {
                shape.strokeBorder(borderStyle, lineWidth: max(1, borders.width * scale * 1.4))
            } else {
                shape.strokeBorder(Color.white.opacity(0.07), lineWidth: 1)
            }
        }
    }

    private var borderStyle: AnyShapeStyle {
        borders.gradient
            ? AnyShapeStyle(LinearGradient(colors: [Palette.accent, Palette.secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            : AnyShapeStyle(Palette.accent)
    }
}

// MARK: - Layout cards

struct LayoutCard: View {
    let label: String
    let blurb: String
    let layout: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { geo in
                    let rects = LayoutGeometry.rects(layout, in: CGRect(origin: .zero, size: geo.size).insetBy(dx: 6, dy: 6), gap: 4)
                    ZStack(alignment: .topLeading) {
                        ForEach(Array(rects.enumerated()), id: \.offset) { i, r in
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(i == 0 ? (selected ? Palette.accent : Palette.accent.opacity(0.55)) : Palette.surface1.opacity(0.9))
                                .frame(width: r.width, height: r.height)
                                .offset(x: r.minX, y: r.minY)
                        }
                    }
                }
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Palette.crust.opacity(0.7)))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Palette.text)
                    Text(blurb)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.subtext0)
                        .lineLimit(3, reservesSpace: true)
                        .multilineTextAlignment(.leading)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Palette.accent.opacity(0.12) : Palette.surface0.opacity(hovering ? 0.7 : 0.45))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? Palette.accent : Color.white.opacity(0.06), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: selected)
    }
}

// MARK: - Theme swatches

/// A theme drawn in its own colors, so every card previews itself regardless of the active theme.
struct ThemeSwatch: View {
    let theme: Theme
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack(alignment: .topLeading) {
                    theme.base.color
                    // A tiny tiled desktop in the theme's colors.
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(theme.mantle.color)
                            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(LinearGradient(colors: [theme.borderActive.color, theme.borderActive2.color],
                                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.5))
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.surface0.color)
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(theme.surface0.color)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 70)

                HStack(spacing: 6) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(theme.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.text.color)
                            .lineLimit(1)
                        HStack(spacing: 3) {
                            ForEach([theme.accent, theme.secondary, theme.green, theme.yellow, theme.red].indices, id: \.self) { i in
                                Circle()
                                    .fill([theme.accent, theme.secondary, theme.green, theme.yellow, theme.red][i].color)
                                    .frame(width: 9, height: 9)
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if selected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(theme.accent.color)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(theme.crust.color)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(selected ? theme.accent.color : Color.white.opacity(hovering ? 0.2 : 0.08),
                                  lineWidth: selected ? 2 : 1)
            )
            .scaleEffect(hovering && !selected ? 1.02 : 1)
            .shadow(color: .black.opacity(hovering ? 0.3 : 0.15), radius: hovering ? 10 : 5, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
    }
}

// MARK: - Cheat sheet

/// Every binding at a glance. `ink` switches to black on white for printing.
struct CheatSheetContent: View {
    let model: SettingsModel
    var ink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Talys Shortcuts")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(ink ? .black : Palette.text)
                Spacer()
                Text("mod = \(modLabel)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ink ? .gray : Palette.subtext0)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 250), spacing: 14, alignment: .top)], alignment: .leading, spacing: 14) {
                ForEach(groups, id: \.title) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.title.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(ink ? .gray : Palette.accent)
                        ForEach(group.rows, id: \.title) { row in
                            HStack {
                                Text(row.title)
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(ink ? .black : Palette.text)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if ink {
                                    Text(row.caps.joined(separator: " "))
                                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(.black)
                                } else {
                                    KeycapRow(caps: row.caps, size: 9.5)
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(ink ? Color.black.opacity(0.04) : Palette.surface0.opacity(0.45))
                    )
                }
            }
        }
    }

    private var modLabel: String {
        let m = ConfigManager.parseModifiers(model.config.general.mod)
        return Shortcut.symbols(ctrl: m.ctrl, alt: m.alt, shift: m.shift, cmd: m.cmd)
    }

    private struct Group {
        let title: String
        let rows: [(title: String, caps: [String])]
    }

    private var groups: [Group] {
        var groups = SettingsModel.actionGroups.compactMap { group -> Group? in
            let rows = group.actions.compactMap { action -> (title: String, caps: [String])? in
                let caps = model.caps(for: .action(action.name)).caps
                return caps.isEmpty ? nil : (action.title, caps)
            }
            return rows.isEmpty ? nil : Group(title: group.title, rows: rows)
        }
        let commands = model.config.bind.indices.compactMap { i -> (title: String, caps: [String])? in
            let caps = model.caps(for: .exec(i)).caps
            let cmd = model.config.bind[i].exec
            return caps.isEmpty || cmd.isEmpty ? nil : (cmd, caps)
        }
        if !commands.isEmpty { groups.append(Group(title: "Commands", rows: commands)) }
        return groups
    }
}

struct CheatSheetOverlay: View {
    let model: SettingsModel
    let close: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
                .ignoresSafeArea()
                .onTapGesture(perform: close)
            VStack(spacing: 0) {
                ScrollView {
                    CheatSheetContent(model: model).padding(24)
                }
                HStack {
                    Text("Click any shortcut in Keybindings to change it.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Palette.overlay0)
                    Spacer()
                    Button("Print…", action: print).buttonStyle(.themed())
                    Button("Done", action: close)
                        .buttonStyle(.themed(.primary))
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Palette.crust.opacity(0.6))
            }
            .frame(maxWidth: 860, maxHeight: 620)
            .background(
                ZStack {
                    VisualEffectBlur(material: .hudWindow, blendingMode: .withinWindow)
                    Palette.base.opacity(0.94)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Palette.accent.opacity(0.4), lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 30, y: 14)
            .padding(28)
        }
    }

    private func print() {
        let view = NSHostingView(rootView: CheatSheetContent(model: model, ink: true).padding(24).frame(width: 720).background(Color.white))
        view.frame = NSRect(origin: .zero, size: view.fittingSize)
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        NSPrintOperation(view: view, printInfo: info).runModal(for: NSApp.keyWindow ?? NSWindow(), delegate: nil, didRun: nil, contextInfo: nil)
    }
}
