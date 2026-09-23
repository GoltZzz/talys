import Cocoa
import SwiftUI
import Observation

// MARK: - Items

public struct LauncherItem: Identifiable {
    public enum Kind {
        case app(URL)
        case command(@MainActor () -> Void)
    }

    public let id: String
    public let title: String
    public let subtitle: String
    public let symbol: String?
    public let kind: Kind

    public static func command(_ id: String, _ title: String, subtitle: String, symbol: String, action: @escaping @MainActor () -> Void) -> LauncherItem {
        LauncherItem(id: "cmd.\(id)", title: title, subtitle: subtitle, symbol: symbol, kind: .command(action))
    }
}

enum FuzzyMatcher {
    /// Subsequence match with bonuses for prefix, word-start and consecutive hits; nil when `query` doesn't match.
    static func score(_ query: String, in target: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        let t = Array(target.lowercased())
        guard !q.isEmpty else { return 0 }

        // Contiguous matches always outrank scattered ones: prefix > word start > anywhere.
        let qs = String(q), ts = String(t)
        if ts.hasPrefix(qs) { return 1000 - t.count }
        if let range = ts.range(of: qs) {
            let before = ts[..<range.lowerBound].last
            let atWordStart = before.map { !$0.isLetter && !$0.isNumber } ?? true
            return (atWordStart ? 800 : 500) - t.count
        }
        // Scattered subsequences are noisy for very short queries ("ter" → "ThEme: Rose").
        if q.count < 3 { return nil }

        var score = 0
        var ti = 0
        var prev = -2
        for qc in q {
            var found = false
            while ti < t.count {
                if t[ti] == qc {
                    var s = 1
                    if ti == prev + 1 { s += 5 }
                    if ti == 0 {
                        s += 8
                    } else if !t[ti - 1].isLetter && !t[ti - 1].isNumber {
                        s += 6
                    }
                    score += s
                    prev = ti
                    ti += 1
                    found = true
                    break
                }
                ti += 1
            }
            if !found { return nil }
        }
        // Require the subsequence to be reasonably tight, otherwise it's noise.
        return score >= q.count * 4 ? score - t.count / 4 : nil
    }
}

// MARK: - Model

@Observable
@MainActor
final class LauncherModel {
    var query = "" {
        didSet { recompute() }
    }
    private(set) var results: [LauncherItem] = []
    var selection = 0

    @ObservationIgnored var items: [LauncherItem] = []
    @ObservationIgnored var onActivate: ((LauncherItem) -> Void)?

    private let maxResults = 60

    func reset(items: [LauncherItem]) {
        self.items = items
        query = ""
        recompute()
    }

    func recompute() {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            results = Array(items.prefix(maxResults))
        } else {
            var scored: [(item: LauncherItem, score: Int)] = []
            for item in items {
                if let score = FuzzyMatcher.score(query, in: item.title) {
                    scored.append((item, score))
                }
            }
            scored.sort { a, b in
                a.score != b.score ? a.score > b.score : a.item.title < b.item.title
            }
            results = scored.prefix(maxResults).map { $0.item }
        }
        selection = 0
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func activateSelection() {
        guard results.indices.contains(selection) else { return }
        onActivate?(results[selection])
    }
}

// MARK: - Controller

private final class LauncherPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
public final class LauncherController: NSObject, NSWindowDelegate {
    public static let shared = LauncherController()

    /// Supplies Talys actions (theme switching, reload, …) each time the launcher opens.
    public var commandProvider: (() -> [LauncherItem])?

    private let model = LauncherModel()
    private var panel: LauncherPanel?
    private var keyMonitor: Any?
    private var previousApp: NSRunningApplication?
    private var iconCache: [String: NSImage] = [:]
    private(set) var isVisible = false

    private static let size = NSSize(width: 620, height: 440)

    private override init() {
        super.init()
        model.onActivate = { [weak self] item in
            self?.activate(item)
        }
    }

    public func toggle() {
        isVisible ? hide(restoreFocus: true) : show()
    }

    public func show() {
        guard !isVisible, let screen = NSScreen.main else { return }
        isVisible = true

        let front = NSWorkspace.shared.frontmostApplication
        previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front

        let commands = (commandProvider?() ?? []).sorted { $0.title < $1.title }
        model.reset(items: Self.scanApplications() + commands)

        let panel = self.panel ?? makePanel()
        let frame = NSRect(
            x: screen.frame.midX - Self.size.width / 2,
            y: screen.frame.maxY - screen.frame.height * 0.2 - Self.size.height,
            width: Self.size.width,
            height: Self.size.height
        )
        panel.setFrame(frame, display: false)
        // Fresh hosting view each time so the search field regains focus.
        panel.contentView = NSHostingView(rootView: LauncherView(model: model))

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        installKeyMonitor()
    }

    public func hide(restoreFocus: Bool) {
        guard isVisible else { return }
        isVisible = false
        removeKeyMonitor()
        panel?.orderOut(nil)
        if restoreFocus {
            previousApp?.activate()
        }
        previousApp = nil
    }

    public func windowDidResignKey(_ notification: Notification) {
        hide(restoreFocus: false)
    }

    func icon(for url: URL) -> NSImage {
        if let cached = iconCache[url.path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        iconCache[url.path] = image
        return image
    }

    private func activate(_ item: LauncherItem) {
        switch item.kind {
        case .app(let url):
            hide(restoreFocus: false)
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            print("[Launcher] Opened \(item.title)")
        case .command(let action):
            hide(restoreFocus: true)
            print("[Launcher] Ran \(item.title)")
            action()
        }
    }

    private func makePanel() -> LauncherPanel {
        let p = LauncherPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.delegate = self
        self.panel = p
        return p
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let keyCode = event.keyCode
            let ctrl = event.modifierFlags.contains(.control)
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isVisible else { return false }
                switch (keyCode, ctrl) {
                case (53, _): self.hide(restoreFocus: true)               // esc
                case (125, _), (45, true), (38, true): self.model.move(1)  // down, ctrl+n, ctrl+j
                case (126, _), (35, true), (40, true): self.model.move(-1) // up, ctrl+p, ctrl+k
                case (36, _), (76, _): self.model.activateSelection()      // return, keypad enter
                default: return false
                }
                return true
            }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
        }
        keyMonitor = nil
    }

    private static func scanApplications() -> [LauncherItem] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        let roots = [
            "/Applications", "/Applications/Utilities",
            "/System/Applications", "/System/Applications/Utilities",
            "\(home)/Applications",
            // Safari and other Cryptex apps; /Applications only has hidden symlinks to them.
            "/System/Cryptexes/App/System/Applications",
        ]

        var urls: [URL] = [URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")]
        for root in roots {
            let rootURL = URL(fileURLWithPath: root)
            // Not .skipsHiddenFiles: macOS flags the /Applications/Safari.app symlink as hidden.
            let entries = (try? fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
            for entry in entries where !entry.lastPathComponent.hasPrefix(".") {
                if entry.pathExtension == "app" {
                    urls.append(entry)
                } else if (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true, !roots.contains(entry.path) {
                    // One level of nesting, e.g. /Applications/Setapp/*.app
                    let nested = (try? fm.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
                    urls.append(contentsOf: nested.filter { $0.pathExtension == "app" })
                }
            }
        }

        var seen = Set<String>()
        var items: [LauncherItem] = []
        for url in urls {
            let name = fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            guard seen.insert(name.lowercased()).inserted else { continue }
            items.append(LauncherItem(id: url.path, title: name, subtitle: url.deletingLastPathComponent().path, symbol: nil, kind: .app(url)))
        }
        return items.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }
}

// MARK: - View

private struct LauncherView: View {
    @Bindable var model: LauncherModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Palette.accent)
                TextField("Search apps and commands", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(Palette.text)
                    .focused($focused)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            Rectangle()
                .fill(Palette.surface0)
                .frame(height: 1)

            if model.results.isEmpty {
                Spacer()
                Text("No matches")
                    .font(.system(size: 13))
                    .foregroundColor(Palette.overlay0)
                Spacer()
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(model.results.enumerated()), id: \.element.id) { index, item in
                                LauncherRow(item: item, selected: index == model.selection)
                                    .id(item.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        model.selection = index
                                        model.activateSelection()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.selection) { _, newValue in
                        guard model.results.indices.contains(newValue) else { return }
                        proxy.scrollTo(model.results[newValue].id)
                    }
                }
            }
        }
        .frame(width: 620, height: 440)
        .background(
            ZStack {
                VisualEffectBlur(material: .hudWindow, blendingMode: .behindWindow)
                Palette.base.opacity(0.9)
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Palette.accent.opacity(0.7), lineWidth: 1.5)
        )
        .onAppear {
            DispatchQueue.main.async { focused = true }
        }
    }
}

private struct LauncherRow: View {
    let item: LauncherItem
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                switch item.kind {
                case .app(let url):
                    Image(nsImage: LauncherController.shared.icon(for: url))
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                case .command:
                    Image(systemName: item.symbol ?? "command")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Palette.accent)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Palette.text)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(Palette.subtext0)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if case .command = item.kind {
                Text("TALYS")
                    .font(.system(size: 9, weight: .black, design: .monospaced))
                    .foregroundColor(Palette.overlay0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Palette.accent.opacity(0.22) : Color.clear)
        )
    }
}
