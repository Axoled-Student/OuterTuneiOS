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

    /// Disk budget. Thumbnails are a few KB each, so this holds many thousands.
    private static let diskBudget: UInt64 = 96 << 20

#if os(iOS)
    private let memory: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 400
        cache.totalCostLimit = 48 << 20
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
                         cost: data.count)
        return image
    }

    func load(_ urlString: String) {
        guard cached(urlString) == nil, inFlight[urlString] == nil,
              let url = URL(string: urlString) else {
            return
        }

        inFlight[urlString] = Task { [weak self] in
            defer { self?.inFlight[urlString] = nil }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else {
                return
            }
            guard let self else { return }
            self.memory.setObject(image, forKey: urlString as NSString,
                                  cost: data.count)
            try? data.write(to: self.path(for: urlString), options: .atomic)
            // Nudge observers so views holding a placeholder redraw.
            self.version &+= 1
        }
    }
#endif

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
