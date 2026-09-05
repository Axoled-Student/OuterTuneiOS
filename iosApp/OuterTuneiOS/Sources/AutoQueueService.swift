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
private struct LocalListeningRecord: Codable {
    var track: AppTrack
    var starts: Int
    var completions: Int
    var skips: Int
    var listenedSeconds: Double
    var lastPlayedAt: Date

    var preferenceScore: Double {
        Double(completions) * 2.0
            + min(listenedSeconds / 180.0, 4.0) * 0.45
            + Double(starts) * 0.05
            - Double(skips) * 1.4
    }
}

@MainActor
final class AutoQueueService {
    static let shared = AutoQueueService()

    private let youtubeService = YouTubeMusicService.shared
    private let spotify = SpotifyService.shared
    private let ranker = AIRankingService.shared

    /// Normalized titles handed out recently, so alternate uploads with a new
    /// videoId cannot make the same song reappear in successive extensions.
    private var recentlySuggested: [String] = []
    private let recentMemoryLimit = 300
    private var listeningRecords: [String: LocalListeningRecord] = [:]
    private let listeningRecordsKey = "ios.recommendations.listening.v1"
    private let recentSuggestionsKey = "ios.recommendations.suggested.v1"
    private let policyVersionKey = "ios.recommendations.policyVersion.v1"
    private let policyVersion = 2
    private let listeningRecordLimit = 500
    /// A short cooldown prevents annoying loops without forcing the listener
    /// into an endless stream of unknown songs. The longer persisted list is
    /// retained for diagnostics and future scoring, but is not a hard ban.
    private let suggestedCooldownCount = 36
    private let playedCooldownCount = 30
    private var spotifyCandidateFingerprint = ""
    private var cachedSpotifyCandidates: [AppTrack] = []
    private var spotifyArtistAliasFingerprint = ""
    private var cachedSpotifyArtistAliasWeights: [String: Double] = [:]

    private enum QueueLanguage: Equatable {
        case chinese
        case japanese
        case korean
        case other
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: listeningRecordsKey),
           let decoded = try? JSONDecoder().decode(
               [String: LocalListeningRecord].self,
               from: data
           ) {
            listeningRecords = decoded
        }
        if UserDefaults.standard.integer(forKey: policyVersionKey) == policyVersion {
            if let data = UserDefaults.standard.data(forKey: recentSuggestionsKey),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                recentlySuggested = Array(decoded.suffix(recentMemoryLimit))
            }
        } else {
            // Old builds stored video IDs and low-quality queue choices here.
            // Keep the learned listen/skip history, but do not let stale queue
            // memory block every familiar track after this policy upgrade.
            UserDefaults.standard.removeObject(forKey: recentSuggestionsKey)
            UserDefaults.standard.set(policyVersion, forKey: policyVersionKey)
        }
    }

    var diagnostics: String {
        let skips = listeningRecords.values.reduce(0) { $0 + $1.skips }
        let completions = listeningRecords.values.reduce(0) { $0 + $1.completions }
        return "learned=\(listeningRecords.count), completed=\(completions), "
            + "skipped=\(skips), repeatBlock=\(recentlySuggested.count)"
    }

    /// Seed the feedback model with the app's existing listening history. This
    /// is intentionally a weak positive because old rows have no timing data.
    func bootstrapHistory(_ tracks: [AppTrack]) {
        var changed = false
        for (index, track) in tracks.prefix(100).enumerated()
            where listeningRecords[track.stableId] == nil {
            listeningRecords[track.stableId] = LocalListeningRecord(
                track: track,
                starts: 1,
                completions: 0,
                skips: 0,
                listenedSeconds: 45,
                lastPlayedAt: Date().addingTimeInterval(Double(-index * 60))
            )
            changed = true
        }
        if changed { persistListeningRecords() }
    }

    func recordStarted(_ track: AppTrack) {
        var record = listeningRecords[track.stableId] ?? LocalListeningRecord(
            track: track,
            starts: 0,
            completions: 0,
            skips: 0,
            listenedSeconds: 0,
            lastPlayedAt: Date()
        )
        record.track = track
        record.starts += 1
        record.lastPlayedAt = Date()
        listeningRecords[track.stableId] = record
        persistListeningRecords()
    }

    func recordFinished(
        _ track: AppTrack,
        listenedSeconds: Double,
        duration: Double,
        completed: Bool
    ) {
        var record = listeningRecords[track.stableId] ?? LocalListeningRecord(
            track: track,
            starts: 1,
            completions: 0,
            skips: 0,
            listenedSeconds: 0,
            lastPlayedAt: Date()
        )
        let seconds = max(listenedSeconds, 0)
        let ratio = duration > 0 ? seconds / duration : 0
        record.track = track
        record.listenedSeconds += seconds
        record.lastPlayedAt = Date()
        if completed || ratio >= 0.85 {
            record.completions += 1
        } else if seconds < 45 || ratio < 0.45 {
            record.skips += 1
        }
        listeningRecords[track.stableId] = record
        persistListeningRecords()
    }

    func recommendations(
        seed: AppTrack,
        excluding: [AppTrack],
        limit: Int
    ) async -> [AppTrack] {
        // Refresh first so candidate generation and scoring use the same live
        // Spotify top/recent/saved snapshot instead of a stale profile.
        if spotify.isAuthenticated {
            await spotify.refreshTasteProfile()
        }
        guard !Task.isCancelled else { return [] }

        var blocked = Set(excluding.map(\.stableId))
        var blockedIdentities = Set(excluding.map(\.recommendationIdentity))
        blocked.insert(seed.stableId)
        blockedIdentities.insert(seed.recommendationIdentity)
        for identity in recentlySuggested.suffix(suggestedCooldownCount) {
            blockedIdentities.insert(identity)
        }
        for track in recentlyPlayedTracks(limit: playedCooldownCount) {
            blocked.insert(track.stableId)
            blockedIdentities.insert(track.recommendationIdentity)
        }
        for recent in spotify.profile.recentlyPlayed.prefix(40) {
            let identity = AppTrack.normalizedRecommendationTitle(recent.name)
            if !identity.isEmpty {
                blockedIdentities.insert(identity)
            }
        }
        // Repeated early skips are a strong dislike signal, not mere novelty.
        for (id, record) in listeningRecords
            where record.skips >= 2 && record.skips > record.completions {
            blocked.insert(id)
            blockedIdentities.insert(record.track.recommendationIdentity)
        }

        let generated = await generateCandidates(seed: seed, limit: limit)
        var pool = generated.tracks
        guard !Task.isCancelled else { return [] }
        let queueLanguage = preferredQueueLanguage(seed: seed, candidates: pool)
        if queueLanguage == .chinese {
            pool = pool.filter { trackLanguage($0) == .chinese }
        } else if queueLanguage == .japanese {
            // Romanised/English titles from Japanese artists are common, so
            // retain `.other`; explicitly Chinese and Korean rows are not a
            // sensible continuation for a Japanese seed.
            pool = pool.filter {
                let language = trackLanguage($0)
                return language == .japanese || language == .other
            }
        } else if queueLanguage == .korean {
            pool = pool.filter {
                let language = trackLanguage($0)
                return language == .korean || language == .other
            }
        }
        pool = pool.filter {
            !blocked.contains($0.stableId)
                && !blockedIdentities.contains($0.recommendationIdentity)
        }
        pool = dedupe(pool)

        guard !pool.isEmpty else { return [] }

        // Spotify commonly names CJK artists in Latin script while YouTube
        // Music uses the native name (Jay Chou vs 周杰倫, JJ Lin vs 林俊傑).
        // Resolve and cache those aliases before familiarity scoring.
        await refreshSpotifyArtistAliases()
        guard !Task.isCancelled else { return [] }

        // Ground the shortlist in actual local listens/skips before asking an
        // optional LLM to sequence it.
        let candidateLimit = generated.isCoherentSeedRadio
            ? limit
            : min(pool.count, 40)
        let locallyOrdered = scoredBlend(
            pool: pool,
            taste: spotify.profile,
            limit: candidateLimit,
            preserveSourceOrder: generated.isCoherentSeedRadio,
            seed: seed
        )

        let ordered: [AppTrack]
        if generated.isCoherentSeedRadio {
            // YouTube Music has already produced a radio tied to the selected
            // song. Keep that relevance signal dominant; completed/skipped
            // history still makes small local adjustments in scoredBlend.
            ordered = Array(locallyOrdered.prefix(limit))
        } else if let ranked = await ranker.rank(candidates: locallyOrdered,
                                                 nowPlaying: seed,
                                                 taste: spotify.profile,
                                                 localFeedback: feedbackSummary(),
                                                 limit: limit) {
            // Treat model output as one signal, then re-apply the hard repeat,
            // familiarity, variant and artist-diversity policy.
            ordered = scoredBlend(
                pool: ranked,
                taste: spotify.profile,
                limit: limit,
                preserveSourceOrder: true,
                seed: seed
            )
        } else {
            ordered = Array(locallyOrdered.prefix(limit))
        }

        guard !Task.isCancelled else { return [] }
        remember(ordered)
        return ordered
    }

    // MARK: Stage 1 - candidates

    private func generateCandidates(
        seed: AppTrack,
        limit: Int
    ) async -> (tracks: [AppTrack], isCoherentSeedRadio: Bool) {
        var pool: [AppTrack] = []

        // YouTube Music radio for the seed. This is the reliable backbone.
        if case .youtube(let videoId) = seed.source {
            if let radio = try? await youtubeService.fetchRadioQueue(videoId: videoId,
                                                                     limit: 80) {
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
                                                                     limit: 80) {
                pool.append(contentsOf: radio.map { $0.asTrack() })
            }
        }

        pool = dedupe(pool)
        let hasCoherentRadio = pool.count >= max(limit, 12)

        // Exact Spotify/local-history tracks are candidate material on every
        // generation, not merely when radio fails. This makes the queue reflect
        // what the listener demonstrably chose instead of treating history as
        // a weak score on an otherwise raw radio feed.
        pool.append(contentsOf: localFavoriteCandidates(limit: 30))
        pool.append(contentsOf: await spotifyDerivedCandidates(limit: 30))

        // Broader radios and cross-service similarity are emergency fallbacks
        // for a sparse seed only. A healthy seed radio plus real history is much
        // safer than injecting unrelated artists from a global similarity API.
        if !hasCoherentRadio {
            pool.append(contentsOf: await listeningHistoryDerivedCandidates())
            pool.append(contentsOf: await similarityDerivedCandidates(seed: seed))
        }

        return (dedupe(pool), hasCoherentRadio)
    }

    private func localFavoriteCandidates(limit: Int) -> [AppTrack] {
        listeningRecords.values
            .filter { $0.preferenceScore > 0.25 }
            .sorted {
                if $0.preferenceScore == $1.preferenceScore {
                    return $0.lastPlayedAt > $1.lastPlayedAt
                }
                return $0.preferenceScore > $1.preferenceScore
            }
            .prefix(limit)
            .map(\.track)
    }

    /// Generate candidates from tracks the listener actually completed or
    /// spent time with, not just the current song and Spotify's broad profile.
    private func listeningHistoryDerivedCandidates() async -> [AppTrack] {
        let seeds = listeningRecords.values
            .filter { $0.preferenceScore > 0.10 }
            .sorted {
                if $0.preferenceScore == $1.preferenceScore {
                    return $0.lastPlayedAt > $1.lastPlayedAt
                }
                return $0.preferenceScore > $1.preferenceScore
            }
            .prefix(3)
            .compactMap { record -> String? in
                if case .youtube(let videoId) = record.track.source { return videoId }
                return nil
            }

        return await withTaskGroup(of: [AppTrack].self) { group in
            for videoId in seeds {
                group.addTask { [youtubeService] in
                    let radio = try? await youtubeService.fetchRadioQueue(
                        videoId: videoId,
                        limit: 15
                    )
                    return (radio ?? []).map { $0.asTrack() }
                }
            }

            var result: [AppTrack] = []
            for await tracks in group { result.append(contentsOf: tracks) }
            return result
        }
    }

    /// Turns the Spotify taste profile into YouTube Music tracks.
    private func spotifyDerivedCandidates(limit: Int) async -> [AppTrack] {
        // A cached profile is useful even when the account is temporarily
        // offline or its refresh token is unavailable.
        guard !spotify.profile.weightedTracks.isEmpty else { return [] }

        let recentIds = Set(spotify.profile.recentlyPlayed.map(\.id))
        let seeds = spotify.profile.weightedTracks
            .map(\.track)
            .filter { !recentIds.contains($0.id) }
            .prefix(limit)
        guard !seeds.isEmpty else { return [] }

        let fingerprint = seeds.map(\.id).joined(separator: "|")
        if fingerprint == spotifyCandidateFingerprint,
           !cachedSpotifyCandidates.isEmpty {
            return cachedSpotifyCandidates
        }

        let found = await withTaskGroup(of: (Int, AppTrack?).self) { group in
            for (index, seed) in seeds.enumerated() {
                group.addTask { [youtubeService] in
                    guard
                        let results = try? await youtubeService.searchSongs(
                            query: seed.searchQuery),
                        let first = results.first
                    else {
                        return (index, nil)
                    }
                    return (index, first.asTrack())
                }
            }

            var indexed: [(Int, AppTrack)] = []
            for await (index, track) in group {
                if let track { indexed.append((index, track)) }
            }
            return indexed.sorted { $0.0 < $1.0 }.map(\.1)
        }

        spotifyCandidateFingerprint = fingerprint
        cachedSpotifyCandidates = found
        return found
    }

    private func refreshSpotifyArtistAliases(limit: Int = 16) async {
        guard !spotify.profile.weightedArtists.isEmpty else {
            cachedSpotifyArtistAliasWeights = [:]
            spotifyArtistAliasFingerprint = ""
            return
        }

        let artists = Array(spotify.profile.weightedArtists.prefix(limit))
        let fingerprint = artists.map(\.artist.id).joined(separator: "|")
        guard !fingerprint.isEmpty,
              fingerprint != spotifyArtistAliasFingerprint else {
            return
        }

        let resolved = await withTaskGroup(of: (String, Double)?.self) { group in
            for (artist, weight) in artists {
                group.addTask { [youtubeService] in
                    guard let results = try? await youtubeService.searchSongs(
                        query: artist.name
                    ), let result = results.first else {
                        return nil
                    }
                    return (result.artist, weight)
                }
            }

            var values: [(String, Double)] = []
            for await value in group {
                if let value { values.append(value) }
            }
            return values
        }

        var aliases: [String: Double] = [:]
        for (artist, weight) in resolved {
            let key = normalizedArtistName(artist)
            guard !key.isEmpty, key != normalizedArtistName("Unknown") else { continue }
            aliases[key] = max(aliases[key] ?? 0, weight)
        }
        cachedSpotifyArtistAliasWeights = aliases
        spotifyArtistAliasFingerprint = fingerprint
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
        limit: Int,
        preserveSourceOrder: Bool,
        seed: AppTrack
    ) -> [AppTrack] {
        var artistWeights: [String: Double] = [:]
        for (artist, weight) in taste.weightedArtists {
            let key = normalizedArtistName(artist.name)
            guard !key.isEmpty else { continue }
            artistWeights[key] = max(artistWeights[key] ?? 0, weight)
        }
        for (track, weight) in taste.weightedTracks {
            let key = normalizedArtistName(track.artistName)
            guard !key.isEmpty else { continue }
            artistWeights[key] = max(artistWeights[key] ?? 0, weight * 0.8)
        }
        for (alias, weight) in cachedSpotifyArtistAliasWeights {
            artistWeights[alias] = max(artistWeights[alias] ?? 0, weight)
        }

        var knownTrackKeys = Set(taste.weightedTracks.map {
            normalizedTrackKey(title: $0.track.name, artist: $0.track.artistName)
        })
        var knownExactTrackKeys = Set(taste.weightedTracks.map {
            normalizedExactTrackKey(title: $0.track.name, artist: $0.track.artistName)
        })
        knownTrackKeys.formUnion(
            listeningRecords.values
                .filter {
                    $0.completions > 0
                        || ($0.listenedSeconds >= 120 && $0.skips == 0)
                }
                .map {
                    normalizedTrackKey(
                        title: $0.track.title,
                        artist: $0.track.artist
                    )
                }
        )
        knownExactTrackKeys.formUnion(
            listeningRecords.values
                .filter {
                    $0.completions > 0
                        || ($0.listenedSeconds >= 120 && $0.skips == 0)
                }
                .map {
                    normalizedExactTrackKey(
                        title: $0.track.title,
                        artist: $0.track.artist
                    )
                }
        )
        let seedArtist = normalizedArtistName(seed.artist)
        let locallyKnownArtists = Set(
            listeningRecords.values
                .filter {
                    $0.completions > 0
                        || ($0.listenedSeconds >= 120 && $0.skips == 0)
                }
                .map { normalizedArtistName($0.track.artist) }
                .filter { !$0.isEmpty }
        )
        var knownArtistIdentities = Set(
            artistWeights.keys.flatMap { artistIdentityTokens($0) }
        )
        for artist in locallyKnownArtists {
            knownArtistIdentities.formUnion(artistIdentityTokens(artist))
        }
        let hasTasteSignals = !taste.isEmpty
            || locallyKnownArtists.count >= 3

        let scored: [(track: AppTrack, score: Double, familiar: Bool)] = pool.enumerated()
            .compactMap { index, track in
            let artistKey = normalizedArtistName(track.artist)
            let tasteWeight = tasteArtistWeight(for: artistKey, weights: artistWeights)
            let localAffinity = localArtistAffinity(for: artistKey)
            let isSeedArtist = !seedArtist.isEmpty && artistKey == seedArtist
            let isKnownTrack = knownTrackKeys.contains(
                normalizedTrackKey(title: track.title, artist: track.artist)
            )
            let isExactKnownRecording = knownExactTrackKeys.contains(
                normalizedExactTrackKey(title: track.title, artist: track.artist)
            )
            let isKnownArtist = !artistIdentityTokens(track.artist)
                .isDisjoint(with: knownArtistIdentities)
            let isFamiliar = !hasTasteSignals || isSeedArtist || isKnownTrack
                || isKnownArtist

            // Do not let low-quality alternate uploads crowd out an available
            // official/familiar recording. A variant the listener actually has
            // as that exact recording in history remains eligible.
            if isUndesiredVariant(track), !isExactKnownRecording {
                return nil
            }

            // The listener explicitly rejected raw discovery/unknown artists.
            // Once we have a meaningful Spotify or local-history profile, an
            // unfamiliar artist is ineligible rather than merely penalised.
            if hasTasteSignals, !isFamiliar {
                return nil
            }

            // Source radio position remains a relevance signal, but unlike the
            // old linear score it cannot bury every Spotify-known artist merely
            // because those reference tracks were appended after the radio.
            var score = preserveSourceOrder
                ? 4.0 / (1.0 + Double(index) * 0.08)
                : 1.0 / (1.0 + Double(index) * 0.05)
            score += min(tasteWeight, 3.0) * 2.4
            score += localAffinity * 1.4
            if isSeedArtist { score += 2.5 }
            if isKnownTrack { score += 3.0 }
            if let local = listeningRecords[track.stableId] {
                score += max(-3.0, min(local.preferenceScore, 3.0))
            }
            return (track: track, score: score, familiar: isFamiliar)
        }

        let ranked = scored.sorted { $0.score > $1.score }
        var familiar = ranked.filter { $0.familiar }
        var result: [AppTrack] = []
        var artistCounts: [String: Int] = [:]

        func appendBest(from candidates: inout [(track: AppTrack, score: Double, familiar: Bool)],
                        upTo maximum: Int) {
            while !candidates.isEmpty, result.count < maximum {
                let previousArtist = result.last.map { normalizedArtistName($0.artist) }
                let preferred = candidates.firstIndex { candidate in
                    let artist = normalizedArtistName(candidate.track.artist)
                    let artistLimit = artist == seedArtist ? 8 : 2
                    return (artistCounts[artist] ?? 0) < artistLimit
                        && (previousArtist == nil || artist != previousArtist)
                }
                let fallback = candidates.firstIndex { candidate in
                    let artist = normalizedArtistName(candidate.track.artist)
                    let artistLimit = artist == seedArtist ? 8 : 2
                    return (artistCounts[artist] ?? 0) < artistLimit
                }
                guard let nextIndex = preferred ?? fallback else { break }
                let candidate = candidates.remove(at: nextIndex)
                let artist = normalizedArtistName(candidate.track.artist)
                artistCounts[artist, default: 0] += 1
                result.append(candidate.track)
            }
        }

        // Keep batches compact enough to rotate when the same seed is chosen
        // again. Every row is now from a known artist/track when taste signals
        // exist; there is deliberately no unknown-artist discovery quota.
        let targetCount = min(limit, 12)
        appendBest(from: &familiar, upTo: targetCount)

        return result
    }

    // MARK: Helpers

    private func dedupe(_ tracks: [AppTrack]) -> [AppTrack] {
        var seenIds = Set<String>()
        var seenIdentities = Set<String>()
        var result: [AppTrack] = []
        for track in tracks {
            guard !seenIds.contains(track.stableId),
                  !seenIdentities.contains(track.recommendationIdentity) else {
                continue
            }
            seenIds.insert(track.stableId)
            seenIdentities.insert(track.recommendationIdentity)
            result.append(track)
        }
        return result
    }

    private func remember(_ tracks: [AppTrack]) {
        for identity in tracks.map(\.recommendationIdentity) {
            recentlySuggested.removeAll { $0 == identity }
            recentlySuggested.append(identity)
        }
        if recentlySuggested.count > recentMemoryLimit {
            recentlySuggested.removeFirst(recentlySuggested.count - recentMemoryLimit)
        }
        if let data = try? JSONEncoder().encode(recentlySuggested) {
            UserDefaults.standard.set(data, forKey: recentSuggestionsKey)
        }
    }

    private func recentlyPlayedTracks(limit: Int) -> [AppTrack] {
        listeningRecords
            .sorted { $0.value.lastPlayedAt > $1.value.lastPlayedAt }
            .prefix(limit)
            .map(\.value.track)
    }

    private func normalizedArtistName(_ value: String) -> String {
        // Older queue rows stored the entire YouTube byline as the artist
        // ("YOASOBI • album • views • year"). Recover the actual leading artist
        // so that completed history still matches newly parsed clean metadata.
        let segments = value
            .replacingOccurrences(of: "·", with: "•")
            .components(separatedBy: "•")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let metadataLabels: Set<String> = [
            "song", "songs", "music", "歌曲", "音樂", "音乐"
        ]
        let core = segments.first { segment in
            let lowered = segment.lowercased()
            return !metadataLabels.contains(lowered)
                && !lowered.contains("觀看次數")
                && !lowered.contains("观看次数")
                && !lowered.hasSuffix("年")
        } ?? value

        let folded = core.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    private func preferredQueueLanguage(
        seed: AppTrack,
        candidates: [AppTrack]
    ) -> QueueLanguage {
        let seedLanguage = trackLanguage(seed)
        if seedLanguage == .chinese {
            return .chinese
        }

        let sample = candidates.prefix(30).map { recommendationLanguage(for: $0.title) }
        let chineseCount = sample.filter { $0 == .chinese }.count
        let explicitCount = sample.filter { $0 != .other }.count
        if chineseCount >= 5, chineseCount * 2 >= max(explicitCount, 1) {
            return .chinese
        }
        return seedLanguage
    }

    private func trackLanguage(_ track: AppTrack) -> QueueLanguage {
        recommendationLanguage(for: "\(track.title) \(track.artist)")
    }

    private func recommendationLanguage(for text: String) -> QueueLanguage {
        var hasHan = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x3040 ... 0x30FF:
                return .japanese
            case 0xAC00 ... 0xD7AF:
                return .korean
            case 0x3400 ... 0x4DBF, 0x4E00 ... 0x9FFF:
                hasHan = true
            default:
                continue
            }
        }
        return hasHan ? .chinese : .other
    }

    private func normalizedTrackKey(title: String, artist: String) -> String {
        normalizedArtistName(artist) + "|" + AppTrack.normalizedRecommendationTitle(title)
    }

    private func normalizedExactTrackKey(title: String, artist: String) -> String {
        normalizedArtistName(artist) + "|" + normalizedFullText(title)
    }

    private func normalizedFullText(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Match native and romanised forms without accepting arbitrary substring
    /// collisions. For example `JJ林俊傑` and `林俊傑 JJ Lin` share the stable Han
    /// identity `林俊傑`, while unrelated Latin artist names remain exact-only.
    private func artistIdentityTokens(_ value: String) -> Set<String> {
        var tokens = Set<String>()
        let normalized = normalizedArtistName(value)
        if normalized.count >= 2 { tokens.insert(normalized) }

        let components = value.components(
            separatedBy: CharacterSet(charactersIn: "&,、")
        )
        for component in components {
            let token = normalizedArtistName(component)
            if token.count >= 2 { tokens.insert(token) }
        }

        var han = ""
        for scalar in value.unicodeScalars {
            if (0x3400 ... 0x4DBF).contains(scalar.value)
                || (0x4E00 ... 0x9FFF).contains(scalar.value) {
                han.unicodeScalars.append(scalar)
            }
        }
        if han.count >= 2 {
            tokens.insert(han)
        }
        return tokens
    }

    private func tasteArtistWeight(
        for artist: String,
        weights: [String: Double]
    ) -> Double {
        guard !artist.isEmpty else { return 0 }
        if let exact = weights[artist] { return exact }
        return weights.compactMap { candidate, weight in
            guard candidate.count >= 2,
                  artist.contains(candidate) || candidate.contains(artist) else {
                return nil
            }
            return weight * 0.8
        }.max() ?? 0
    }

    private func isUndesiredVariant(_ track: AppTrack) -> Bool {
        let normalized = normalizedArtistName(track.title)
        let markers = [
            "cover", "coveredby", "karaoke", "instrumental", "acoustic",
            "spedup", "slowed", "nightcore", "remix", "tvsize", "tvサイズ",
            "テレビサイズ", "shortver", "shortversion", "ノンクレジット",
            "翻唱", "伴奏", "純音樂", "纯音乐", "カバー", "歌ってみた"
        ]
        return markers.contains { normalized.contains($0) }
    }

    private func localArtistAffinity(for normalizedArtist: String) -> Double {
        guard !normalizedArtist.isEmpty else { return 0 }
        var score = 0.0
        for record in listeningRecords.values {
            let candidate = normalizedArtistName(record.track.artist)
            guard !candidate.isEmpty else { continue }
            guard candidate == normalizedArtist
                    || candidate.contains(normalizedArtist)
                    || normalizedArtist.contains(candidate) else { continue }
            score += Double(record.completions) * 0.8
            score += min(record.listenedSeconds / 300.0, 1.5) * 0.35
            score -= Double(record.skips) * 0.55
        }
        return max(-2.0, min(score, 3.0))
    }

    private func feedbackSummary() -> String? {
        guard !listeningRecords.isEmpty else { return nil }
        let ordered = listeningRecords.values.sorted {
            $0.preferenceScore > $1.preferenceScore
        }
        let liked = ordered.filter { $0.preferenceScore > 0.25 }.prefix(10).map {
            "\($0.track.artist) - \($0.track.title)"
        }
        let skipped = ordered.reversed().filter { $0.skips > 0 }.prefix(8).map {
            "\($0.track.artist) - \($0.track.title)"
        }
        var lines: [String] = []
        if !liked.isEmpty {
            lines.append("Locally listened/liked: " + liked.joined(separator: "; "))
        }
        if !skipped.isEmpty {
            lines.append("Frequently skipped: " + skipped.joined(separator: "; "))
        }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    private func persistListeningRecords() {
        if listeningRecords.count > listeningRecordLimit {
            let keep = listeningRecords
                .sorted { $0.value.lastPlayedAt > $1.value.lastPlayedAt }
                .prefix(listeningRecordLimit)
            listeningRecords = Dictionary(
                uniqueKeysWithValues: keep.map { ($0.key, $0.value) }
            )
        }
        if let data = try? JSONEncoder().encode(listeningRecords) {
            UserDefaults.standard.set(data, forKey: listeningRecordsKey)
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
        if spotify.isAuthenticated {
            await spotify.refreshTasteProfile()
        }

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
