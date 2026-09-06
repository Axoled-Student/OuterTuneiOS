import Foundation

/// Where the words come from.
///
/// The resolver is asked first: it matches against lrclib with a few more
/// attempts than a single search, and it is the only side that holds the model
/// key, so it is also the only side that can translate. lrclib is still called
/// directly when the resolver is unset or unreachable - losing the translation
/// is much better than losing the lyrics.
@MainActor
final class LyricsService {
    static let shared = LyricsService()

    private init() {}

    /// The language to translate into, from the device's own settings.
    static var deviceLanguage: String {
        Locale.preferredLanguages.first ?? "en"
    }

    func fetch(title: String,
               artist: String,
               duration: Int?,
               translateInto target: String?) async -> LyricsSnapshot? {
        if let served = await StreamResolverService.shared.fetchLyrics(
            title: title, artist: artist, duration: duration, target: target) {
            return served
        }
        return await fetchFromLrclib(title: title, artist: artist,
                                     duration: duration)
    }

    // MARK: - Direct fallback

    private func fetchFromLrclib(title: String,
                                 artist: String,
                                 duration: Int?) async -> LyricsSnapshot? {
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: title),
            URLQueryItem(name: "artist_name", value: artist),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.setValue("OuterTuneiOS/1.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let tracks = try JSONDecoder().decode([LrcLibTrack].self, from: data)
            let synced = tracks.filter { $0.syncedLyrics?.isEmpty == false }
            let candidates = synced.isEmpty ? tracks : synced
            guard let best = pick(from: candidates, duration: duration) else {
                return nil
            }

            var snapshot = LyricsSnapshot()
            snapshot.source = "lrclib"
            snapshot.lines = SyncedLyrics.parse(best.syncedLyrics ?? "")
            snapshot.plain = (best.plainLyrics ?? "").trimmingCharacters(
                in: .whitespacesAndNewlines)
            return snapshot.isEmpty ? nil : snapshot
        } catch {
            return nil
        }
    }

    private func pick(from tracks: [LrcLibTrack], duration: Int?) -> LrcLibTrack? {
        guard let duration, duration > 0 else { return tracks.first }
        return tracks.min { abs($0.duration - Double(duration))
            < abs($1.duration - Double(duration)) }
    }
}

private struct LrcLibTrack: Decodable {
    let duration: Double
    let syncedLyrics: String?
    let plainLyrics: String?
}
