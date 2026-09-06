import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Two-level artwork cache: memory for the current session, disk across
/// launches.
///
/// `AsyncImage` keeps nothing of its own, so every scroll of a shelf and every
/// relaunch refetched the same thumbnails. Home alone shows roughly a hundred
/// covers, so that was the bulk of the app's network use.
@MainActor
final class ImageCache: ObservableObject {
    static let shared = ImageCache()

    /// Disk budget. Covers are now requested at the size they are drawn -
    /// tens of KB rather than a few - so the old 96MB would have held far less
    /// of the listener's library than it used to.
    private static let diskBudget: UInt64 = 256 << 20

#if os(iOS)
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        // Costs are decoded bytes, not file bytes: a 1080px cover is 142KB on
        // disk but 4.6MB in memory, and budgeting by the former would let a
        // few full-screen images quietly blow past the limit.
        cache.totalCostLimit = 96 << 20
        return cache
    }()
#endif

    private let directory: URL
    private var inFlight: [String: Task<Void, Never>] = [:]
    @Published private(set) var version: Int = 0

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appendingPathComponent("artwork", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        Task { await pruneIfNeeded() }
    }

    private func path(for key: String) -> URL {
        // A stable, filesystem-safe name derived from the URL.
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return directory.appendingPathComponent(String(hash, radix: 36))
    }

#if os(iOS)
    /// Cached image, if we already hold one. Never touches the network.
    func cached(_ urlString: String) -> UIImage? {
        if let image = memory.object(forKey: urlString as NSString) {
            return image
        }
        let file = path(for: urlString)
        guard let data = try? Data(contentsOf: file),
              let image = UIImage(data: data) else {
            return nil
        }
        memory.setObject(image, forKey: urlString as NSString,
                         cost: Self.decodedBytes(image))
        return image
    }

    func load(_ urlString: String) {
        guard cached(urlString) == nil, inFlight[urlString] == nil,
              let url = URL(string: urlString) else {
            return
        }

        inFlight[urlString] = Task { [weak self] in
            defer { self?.inFlight[urlString] = nil }
            var payload = try? await URLSession.shared.data(from: url)
            if Self.isMissing(payload?.1),
               let alternative = ArtworkURL.fallback(for: urlString),
               let retryURL = URL(string: alternative) {
                // i.ytimg does not publish every named size for every video,
                // so a 404 here means "ask for the one that always exists".
                payload = try? await URLSession.shared.data(from: retryURL)
            }
            guard let data = payload?.0, let image = UIImage(data: data) else {
                return
            }
            guard let self else { return }
            self.memory.setObject(image, forKey: urlString as NSString,
                                  cost: Self.decodedBytes(image))
            try? data.write(to: self.path(for: urlString), options: .atomic)
            // Nudge observers so views holding a placeholder redraw.
            self.version &+= 1
        }
    }

    /// What an image costs in memory once decoded: 4 bytes a pixel.
    private static func decodedBytes(_ image: UIImage) -> Int {
        let size = image.size
        let scale = image.scale
        return max(1, Int(size.width * scale * size.height * scale * 4))
    }
#endif

    private static func isMissing(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 404
    }

    /// Drop the oldest files once the directory outgrows its budget.
    private func pruneIfNeeded() async {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
        ) else { return }

        var total: UInt64 = 0
        var files: [(url: URL, date: Date, size: UInt64)] = []
        for entry in entries {
            let values = try? entry.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = UInt64(values?.fileSize ?? 0)
            files.append((entry, values?.contentModificationDate ?? .distantPast, size))
            total += size
        }
        guard total > Self.diskBudget else { return }

        for file in files.sorted(by: { $0.date < $1.date }) {
            try? manager.removeItem(at: file.url)
            total -= min(total, file.size)
            if total <= Self.diskBudget / 2 { break }
        }
    }

    func clear() {
#if os(iOS)
        memory.removeAllObjects()
#endif
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
        version &+= 1
    }

    /// Bytes currently held on disk, for the settings screen.
    var diskUsage: UInt64 {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        return entries.reduce(0) { total, entry in
            total + UInt64((try? entry.resourceValues(forKeys: [.fileSizeKey]))?
                .fileSize ?? 0)
        }
    }
}
