import Foundation

/// Similar-artist lookups from open music databases.
///
/// Spotify withdrew `/v1/artists/{id}/related-artists` (and `/recommendations`
/// and `/audio-features`) for apps registered after 2024-11-27, all of which
/// return 403/404 - verified against a live account. Deezer's public API and
/// ListenBrainz both expose real collaborative-filtering similarity with no
/// credentials, so they stand in for that missing signal.
enum MusicSimilarityService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        return URLSession(configuration: configuration)
    }()

    private static func json(_ urlString: String) async -> Any? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("OuterTuneiOS/1.0", forHTTPHeaderField: "User-Agent")
        guard
            let (data, response) = try? await session.data(for: request),
            let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode)
        else {
            return nil
        }
        return try? JSONSerialization.jsonObject(with: data)
    }

    /// Artists Deezer considers similar to `name`, best match first.
    static func deezerSimilarArtists(to name: String, limit: Int = 10) async -> [String] {
        guard
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let search = await json("https://api.deezer.com/search/artist?q=\(encoded)")
                as? [String: Any],
            let matches = search["data"] as? [[String: Any]],
            let artistId = matches.first?["id"]
        else {
            return []
        }

        guard
            let related = await json("https://api.deezer.com/artist/\(artistId)/related")
                as? [String: Any],
            let items = related["data"] as? [[String: Any]]
        else {
            return []
        }

        return items.compactMap { $0["name"] as? String }.prefix(limit).map { $0 }
    }

    /// Deezer's own radio for an artist, returned as "artist - title" queries.
    static func deezerArtistRadio(for name: String, limit: Int = 10) async -> [String] {
        guard
            let encoded = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
            let search = await json("https://api.deezer.com/search/artist?q=\(encoded)")
                as? [String: Any],
            let matches = search["data"] as? [[String: Any]],
            let artistId = matches.first?["id"],
            let radio = await json("https://api.deezer.com/artist/\(artistId)/radio")
                as? [String: Any],
            let items = radio["data"] as? [[String: Any]]
        else {
            return []
        }

        return items.prefix(limit).compactMap { track in
            guard let title = track["title"] as? String else { return nil }
            let artist = (track["artist"] as? [String: Any])?["name"] as? String
            return artist.map { "\($0) \(title)" } ?? title
        }
    }
}

/// Builds the "play something next" queue.
///
/// Two stages, deliberately separated:
///
/// 1. **Candidate generation** - only sources that hand back a real YouTube
///    Music videoId. YouTube's own `RDAMVM` radio is the backbone (it is a
///    strong recommender and never needs resolving), enriched with tracks
///    derived from the Spotify taste profile and Deezer similarity.
/// 2. **Ranking** - the LLM re-ranks that pool if one is configured, otherwise
///    a deterministic weighted blend does. Ranking can only reorder stage one,
///    so a failure here degrades quality but never correctness, and playback
///    continues either way.
@MainActor
final class AutoQueueService {
    static let shared = AutoQueueService()

    private let youtubeService = YouTubeMusicService.shared
    private let spotify = SpotifyService.shared
    private let ranker = AIRankingService.shared

    /// Tracks handed out recently, so successive extensions do not loop.
    private var recentlySuggested: [String] = []
    private let recentMemoryLimit = 300

    private init() {}

    func recommendations(
        seed: AppTrack,
        excluding: Set<String>,
        limit: Int
    ) async -> [AppTrack] {
        var blocked = excluding
        blocked.insert(seed.stableId)
        for id in recentlySuggested {
            blocked.insert(id)
        }

        var pool = await generateCandidates(seed: seed)
        pool = pool.filter { !blocked.contains($0.stableId) }
        pool = dedupe(pool)

        guard !pool.isEmpty else { return [] }

        // Refresh the taste profile opportunistically; a stale one still works.
        if spotify.isAuthenticated {
            await spotify.refreshTasteProfile()
        }

        let ordered: [AppTrack]
        if let ranked = await ranker.rank(candidates: pool,
                                          nowPlaying: seed,
                                          taste: spotify.profile,
                                          limit: limit) {
            ordered = ranked
        } else {
            ordered = scoredBlend(pool: pool, taste: spotify.profile, limit: limit)
        }

        remember(ordered)
        return ordered
    }

    // MARK: Stage 1 - candidates

    private func generateCandidates(seed: AppTrack) async -> [AppTrack] {
        var pool: [AppTrack] = []

        // YouTube Music radio for the seed. This is the reliable backbone.
        if case .youtube(let videoId) = seed.source {
            if let radio = try? await youtubeService.fetchRadioQueue(videoId: videoId,
                                                                     limit: 40) {
                pool.append(contentsOf: radio.map { $0.asTrack() })
            }
        }

        // If the seed is not a YouTube track (a local file, say), fall back to
        // searching for it so radio still has something to work from.
        if pool.isEmpty {
            let query = "\(seed.artist) \(seed.title)"
            if let found = try? await youtubeService.searchSongs(query: query),
               let first = found.first,
               let radio = try? await youtubeService.fetchRadioQueue(videoId: first.videoId,
                                                                     limit: 40) {
                pool.append(contentsOf: radio.map { $0.asTrack() })
            }
        }

        pool.append(contentsOf: await spotifyDerivedCandidates())
        pool.append(contentsOf: await similarityDerivedCandidates(seed: seed))

        return pool
    }

    /// Turns the Spotify taste profile into YouTube Music tracks.
    private func spotifyDerivedCandidates() async -> [AppTrack] {
        guard spotify.isAuthenticated else { return [] }

        let seeds = spotify.profile.weightedTracks.prefix(6).map(\.track)
        guard !seeds.isEmpty else { return [] }

        return await withTaskGroup(of: AppTrack?.self) { group in
            for seed in seeds {
                group.addTask { [youtubeService] in
                    guard
                        let results = try? await youtubeService.searchSongs(
                            query: seed.searchQuery),
                        let first = results.first
                    else {
                        return nil
                    }
                    return first.asTrack()
                }
            }

            var found: [AppTrack] = []
            for await track in group {
                if let track { found.append(track) }
            }
            return found
        }
    }

    /// Deezer similarity, anchored on the strongest taste artist available.
    private func similarityDerivedCandidates(seed: AppTrack) async -> [AppTrack] {
        let anchor = spotify.profile.weightedArtists.first?.artist.name ?? seed.artist
        guard !anchor.isEmpty, anchor != "Unknown" else { return [] }

        var queries = await MusicSimilarityService.deezerArtistRadio(for: anchor, limit: 6)
        if queries.isEmpty {
            queries = await MusicSimilarityService.deezerSimilarArtists(to: anchor, limit: 4)
        }
        guard !queries.isEmpty else { return [] }

        return await withTaskGroup(of: AppTrack?.self) { group in
            for query in queries.prefix(5) {
                group.addTask { [youtubeService] in
                    guard
                        let results = try? await youtubeService.searchSongs(query: query),
                        let first = results.first
                    else {
                        return nil
                    }
                    return first.asTrack()
                }
            }

            var found: [AppTrack] = []
            for await track in group {
                if let track { found.append(track) }
            }
            return found
        }
    }

    // MARK: Stage 2 - deterministic fallback ranking

    /// Used whenever the LLM is unavailable. Keeps YouTube's radio ordering as
    /// the base signal and nudges tracks whose artist appears in the Spotify
    /// taste profile upward.
    private func scoredBlend(
        pool: [AppTrack],
        taste: SpotifyTasteProfile,
        limit: Int
    ) -> [AppTrack] {
        var artistWeights: [String: Double] = [:]
        for (artist, weight) in taste.weightedArtists {
            artistWeights[artist.name.lowercased()] = weight
        }
        for (track, weight) in taste.weightedTracks {
            let key = track.artistName.lowercased()
            artistWeights[key] = max(artistWeights[key] ?? 0, weight * 0.8)
        }

        let scored = pool.enumerated().map { index, track -> (AppTrack, Double) in
            // Radio order is meaningful, so position is the base score.
            var score = 1.0 / (1.0 + Double(index) * 0.05)
            let artistKey = track.artist.lowercased()
            if let weight = artistWeights[artistKey] {
                score += weight
            } else if artistWeights.keys.contains(where: { artistKey.contains($0) }) {
                score += 0.3
            }
            return (track, score)
        }

        var seenArtists: [String: Int] = [:]
        var result: [AppTrack] = []

        for (track, _) in scored.sorted(by: { $0.1 > $1.1 }) {
            // Avoid stacking one artist back to back.
            let key = track.artist.lowercased()
            let count = seenArtists[key] ?? 0
            if count >= 2 { continue }
            seenArtists[key] = count + 1
            result.append(track)
            if result.count >= limit { break }
        }

        return result
    }

    // MARK: Helpers

    private func dedupe(_ tracks: [AppTrack]) -> [AppTrack] {
        var seen = Set<String>()
        var result: [AppTrack] = []
        for track in tracks where seen.insert(track.stableId).inserted {
            result.append(track)
        }
        return result
    }

    private func remember(_ tracks: [AppTrack]) {
        recentlySuggested.append(contentsOf: tracks.map(\.stableId))
        if recentlySuggested.count > recentMemoryLimit {
            recentlySuggested.removeFirst(recentlySuggested.count - recentMemoryLimit)
        }
    }
}

// MARK: - Personalised home shelves

extension AutoQueueService {
    /// Home shelves built from the Spotify taste profile.
    ///
    /// These sit above YouTube Music's own home feed, which is personalised to
    /// the *YouTube* account. When the listener's real taste lives in Spotify,
    /// that feed is the wrong signal, so these shelves reintroduce it.
    func personalizedHomeSections() async -> [HomeSection] {
        guard spotify.isAuthenticated else { return [] }
        await spotify.refreshTasteProfile()

        let taste = spotify.profile
        guard !taste.isEmpty else { return [] }

        var sections: [HomeSection] = []

        // 1. Straight from the Spotify affinity ranking.
        let favouriteSeeds = taste.weightedTracks.prefix(10).map(\.track)
        let favourites = await resolve(queries: favouriteSeeds.map(\.searchQuery))
        if !favourites.isEmpty {
            sections.append(
                HomeSection(title: "為你推薦",
                            strapline: "來自你的 Spotify 聆聽紀錄",
                            items: favourites))
        }

        // 2. Radio seeded from the single strongest track.
        if let anchor = taste.weightedTracks.first?.track,
           let resolved = try? await youtubeService.searchSongs(query: anchor.searchQuery),
           let first = resolved.first,
           let radio = try? await youtubeService.fetchRadioQueue(videoId: first.videoId,
                                                                 limit: 12) {
            let items = radio.map { song in
                HomeItem(kind: .song, primaryId: song.videoId, title: song.title,
                         subtitle: song.artist, thumbnailURL: song.thumbnailURL)
            }
            if !items.isEmpty {
                sections.append(
                    HomeSection(title: "因為你常聽 \(anchor.artistName)",
                                strapline: nil, items: items))
            }
        }

        // 3. Deezer similarity around the strongest artist.
        if let topArtist = taste.weightedArtists.first?.artist.name {
            var queries = await MusicSimilarityService.deezerArtistRadio(for: topArtist,
                                                                        limit: 10)
            if queries.isEmpty {
                queries = await MusicSimilarityService.deezerSimilarArtists(to: topArtist,
                                                                           limit: 8)
            }
            let items = await resolve(queries: queries)
            if !items.isEmpty {
                sections.append(
                    HomeSection(title: "相似藝人", strapline: "與 \(topArtist) 相近",
                                items: items))
            }
        }

        return sections
    }

    /// Resolve free-text queries to YouTube Music songs, concurrently,
    /// preserving the input ordering.
    private func resolve(queries: [String]) async -> [HomeItem] {
        guard !queries.isEmpty else { return [] }

        let found = await withTaskGroup(of: (Int, YouTubeSearchSong?).self) { group in
            for (index, query) in queries.enumerated() {
                group.addTask { [youtubeService] in
                    let results = try? await youtubeService.searchSongs(query: query)
                    return (index, results?.first)
                }
            }
            var buffer: [(Int, YouTubeSearchSong?)] = []
            for await entry in group { buffer.append(entry) }
            return buffer
        }

        var seen = Set<String>()
        return found
            .sorted { $0.0 < $1.0 }
            .compactMap(\.1)
            .filter { seen.insert($0.videoId).inserted }
            .map { song in
                HomeItem(kind: .song, primaryId: song.videoId, title: song.title,
                         subtitle: song.artist, thumbnailURL: song.thumbnailURL)
            }
    }
}
