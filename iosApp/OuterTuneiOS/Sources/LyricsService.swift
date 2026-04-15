import Foundation

final class LyricsService {
    static let shared = LyricsService()

    private init() {}

    func fetchSyncedLyrics(title: String, artist: String, duration: Int?) async -> String? {
        let escapedTitle = title.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let escapedArtist = artist.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""

        guard
            let url = URL(string: "https://lrclib.net/api/search?track_name=\(escapedTitle)&artist_name=\(escapedArtist)")
        else {
            return nil
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
                return nil
            }
            let tracks = try JSONDecoder().decode([LrcLibTrack].self, from: data)

            let synced = tracks.filter { $0.syncedLyrics != nil }
            guard !synced.isEmpty else { return nil }

            if let duration {
                return synced
                    .min(by: { abs($0.duration - duration) < abs($1.duration - duration) })?
                    .syncedLyrics
            }

            return synced.first?.syncedLyrics
        } catch {
            return nil
        }
    }
}

private struct LrcLibTrack: Decodable {
    let duration: Int
    let syncedLyrics: String?
}
