import Cocoa

/// Minimum sizes learned per app (by bundle ID), kept across restarts so a window that can't shrink is
/// placed right the moment it opens instead of after it first refuses a tile. Each app keeps the largest
/// minimum seen on either axis.
@MainActor
final class MinSizeStore {
    static let shared = MinSizeStore()

    private var sizes: [String: CGSize] = [:]

    private var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/talys/min_sizes.json")
    }

    private init() {
        guard let data = try? Data(contentsOf: url),
              let raw = try? JSONDecoder().decode([String: [Double]].self, from: data) else { return }
        for (app, wh) in raw where wh.count == 2 {
            sizes[app] = CGSize(width: wh[0], height: wh[1])
        }
    }

    func size(forApp bundleId: String) -> CGSize? {
        sizes[bundleId]
    }

    func record(_ size: CGSize, forApp bundleId: String) {
        let old = sizes[bundleId] ?? .zero
        let new = CGSize(width: max(old.width, size.width), height: max(old.height, size.height))
        guard new != old else { return }
        sizes[bundleId] = new
        save()
    }

    private func save() {
        let raw = sizes.mapValues { [Double($0.width), Double($0.height)] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(raw) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
