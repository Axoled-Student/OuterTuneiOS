import Foundation

/// On-disk cache for decoded audio, keyed by the stream it came from.
///
/// Remuxed files previously went to the temporary directory under a random
/// UUID, so replaying a track downloaded and remuxed it again from scratch -
/// several megabytes for something already on the device. Keying by
/// videoId + itag makes a repeat play free, which matters most for the tracks
/// a listener actually returns to.
actor AudioCache {
    static let shared = AudioCache()

    /// 10GB. At premium bitrates that is on the order of a thousand tracks,
    /// so in practice the listener's whole rotation stays local.
    private static let budget: UInt64 = 10 << 30

    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory,
                                              in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = caches.appendingPathComponent("audio", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }

    /// Stable key for a track's cached audio, independent of the signed URL
    /// (googlevideo issues a fresh one every request, so a URL key never hits).
    nonisolated static func key(for track: AppTrack) -> String {
        "resolver#" + track.stableId
    }

    private func fileURL(for key: String) -> URL {
        var hash: UInt64 = 5381
        for byte in key.utf8 {
            hash = (hash &* 33) &+ UInt64(byte)
        }
        return directory.appendingPathComponent(String(hash, radix: 36) + ".m4a")
    }

    /// A previously cached file, if it is still present and non-empty.
    func existing(for key: String) -> URL? {
        let url = fileURL(for: key)
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              (values.fileSize ?? 0) > 0 else {
            return nil
        }
        // Touch it so the pruner treats it as recently used.
        try? FileManager.default.setAttributes([.modificationDate: Date()],
                                               ofItemAtPath: url.path)
        return url
    }

    @discardableResult
    func store(_ data: Data, for key: String) -> URL? {
        let url = fileURL(for: key)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            return nil
        }
        prune()
        return url
    }

    /// Least-recently-used eviction once the directory exceeds its budget.
    private func prune() {
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
            total += size
            files.append((entry, values?.contentModificationDate ?? .distantPast, size))
        }
        guard total > Self.budget else { return }

        for file in files.sorted(by: { $0.date < $1.date }) {
            try? manager.removeItem(at: file.url)
            total -= min(total, file.size)
            if total <= Self.budget / 2 { break }
        }
    }

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

    func clear() {
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory,
                                                 withIntermediateDirectories: true)
    }
}
