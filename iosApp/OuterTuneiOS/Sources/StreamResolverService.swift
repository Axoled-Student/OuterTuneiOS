import Foundation

/// Metadata for a track the resolver can serve.
struct ResolvedStream: Equatable {
    var videoId: String
    var title: String?
    var artist: String?
    var duration: Double?
    var itag: String?
    var ext: String?
    var mime: String?
    var bitrate: Int?
    var filesize: Int64?
    var progressive: Bool
    var streamURL: URL
}

enum StreamResolverError: LocalizedError {
    case notConfigured
    case badResponse(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未設定串流伺服器"
        case .badResponse(let status):
            if status == 401 {
                return "串流伺服器 Token 不正確（HTTP 401）"
            }
            return "串流伺服器回應 HTTP \(status)"
        case .malformed:
            return "串流伺服器回應格式錯誤"
        }
    }
}

/// Client for the companion resolver (tools/resolver/server.py).
///
/// Direct googlevideo playback is not viable from the app. Measured against the
/// live service: an open-ended `Range: bytes=0-` is refused outright, and even
/// bounded ranges stop at exactly 1 MiB unless YouTube's `n` parameter has been
/// descrambled - which requires executing YouTube's player JS. YouTube Music
/// catalogue tracks are not offered an HLS manifest either, so there is no
/// streaming fallback. Offloading to a VPS does not help: stream URLs are bound
/// to the IP that resolved them, and datacenter ranges are bot-gated.
///
/// The resolver therefore runs on the user's own connection, uses yt-dlp (with
/// a JS runtime) to resolve, verifies and losslessly remuxes the full source on
/// the PC, then serves an AVPlayer-compatible fast-start M4A with byte ranges.
/// One wave of an AI station.
///
/// The server answers the opening request with the first few playable songs
/// and keeps filling the rest behind it, so `pending` says whether asking
/// again - with `after: total` - is still worth doing.
struct AIRadioBatch {
    let station: String
    let theme: String?
    let tracks: [AppTrack]
    let total: Int
    let pending: Bool
}

/// One spoken handover from the station's DJ.
struct AIDJLine {
    let text: String
    /// Absent when the server could write the line but not speak it. The app
    /// can still show it on screen, which is better than nothing.
    let audio: URL?
}

@MainActor
final class StreamResolverService: ObservableObject {
    static let shared = StreamResolverService()

    @Published private(set) var baseURL: String = ""
    @Published private(set) var hasToken: Bool = false
    @Published private(set) var isReachable: Bool?
    @Published private(set) var isChecking: Bool = false
    @Published var lastErrorMessage: String?
    /// Station description the server generated for a promptless request.
    @Published private(set) var lastAIRadioTheme: String?

    private let baseURLKey = "ios.resolver.baseURL.v1"
    private let keychainService = "com.dd3boh.outertune.ios.resolver"
    private let tokenAccount = "token"

    private var token: String? {
        KeychainStore.get(service: keychainService, account: tokenAccount)
    }

    var isConfigured: Bool { !baseURL.isEmpty }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        return URLSession(configuration: configuration)
    }()

    private init() {
        baseURL = UserDefaults.standard.string(forKey: baseURLKey) ?? ""
        hasToken = token != nil
    }

    // MARK: Configuration

    func configure(baseURL rawBase: String, token newToken: String?) {
        var trimmed = rawBase.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        baseURL = trimmed
        UserDefaults.standard.set(trimmed, forKey: baseURLKey)

        if let newToken {
            let value = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainStore.set(value.isEmpty ? nil : value,
                              service: keychainService, account: tokenAccount)
            hasToken = !value.isEmpty
        }
        isReachable = nil
    }

    func clear() {
        baseURL = ""
        UserDefaults.standard.removeObject(forKey: baseURLKey)
        KeychainStore.set(nil, service: keychainService, account: tokenAccount)
        hasToken = false
        isReachable = nil
    }

    // MARK: Requests

    private func url(path: String, query: [URLQueryItem] = []) -> URL? {
        guard var components = URLComponents(string: baseURL + path) else { return nil }
        var items = query
        if let token {
            items.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = items.isEmpty ? nil : items
        return components.url
    }

    func checkHealth() async {
        guard isConfigured, let healthURL = url(path: "/health") else {
            isReachable = false
            return
        }
        isChecking = true
        defer { isChecking = false }

        do {
            let (data, response) = try await session.data(from: healthURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            isReachable = (200 ..< 300).contains(status)
            if isReachable == true {
                lastErrorMessage = nil

                // URL-only mode is now the default. Once the server confirms
                // that authentication is disabled, remove an old Keychain
                // token so it is no longer exposed in stream query strings.
                if let decoded = try? JSONSerialization.jsonObject(with: data),
                   let object = decoded as? [String: Any],
                   object["authRequired"] as? Bool == false,
                   token != nil {
                    KeychainStore.set(nil, service: keychainService, account: tokenAccount)
                    hasToken = false
                }
            } else if status == 401 {
                lastErrorMessage = "Token 不正確（HTTP 401）"
            } else {
                lastErrorMessage = "HTTP \(status)"
            }
        } catch {
            isReachable = false
            lastErrorMessage = error.localizedDescription
        }
    }

    /// The URL AVPlayer should play. Kept separate from `resolve` so playback
    /// can start without waiting for a metadata round-trip.
    func streamURL(videoId: String) -> URL? {
        url(path: "/stream", query: [URLQueryItem(name: "v", value: videoId)])
    }

    /// Ask the resolver for the next batch of tracks.
    ///
    /// Recommendation runs on the server so the algorithm can be changed
    /// without shipping a new build, and because that machine already holds
    /// the Spotify tokens and the signed-in YouTube session. Returns nil when
    /// the resolver is unset or unreachable, and the caller falls back to
    /// on-device generation.
    func fetchQueue(videoId: String,
                    limit: Int,
                    session: String,
                    seedTitle: String? = nil,
                    seedArtist: String? = nil) async -> [AppTrack]? {
        guard isConfigured else { return nil }

        var query = [
            URLQueryItem(name: "v", value: videoId),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "session", value: session),
        ]
        if let seedTitle, !seedTitle.isEmpty {
            query.append(URLQueryItem(name: "title", value: seedTitle))
        }
        if let seedArtist, !seedArtist.isEmpty {
            query.append(URLQueryItem(name: "artist", value: seedArtist))
        }
        guard let endpoint = url(path: "/queue", query: query) else { return nil }

        do {
            let (data, response) = try await self.session.data(from: endpoint)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200 ..< 300).contains(status) else {
                lastErrorMessage = "queue HTTP \(status)"
                return nil
            }
            guard
                let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let rows = object["tracks"] as? [[String: Any]]
            else {
                return nil
            }

            let tracks: [AppTrack] = rows.compactMap { row in
                guard let videoId = row["videoId"] as? String, !videoId.isEmpty else {
                    return nil
                }
                return AppTrack(
                    id: UUID().uuidString,
                    canonicalId: "yt:\(videoId)",
                    title: (row["title"] as? String) ?? "Unknown",
                    artist: (row["artist"] as? String) ?? "Unknown",
                    thumbnailURL: row["thumbnail"] as? String,
                    durationText: nil,
                    source: .youtube(videoId: videoId)
                )
            }
            return tracks.isEmpty ? nil : tracks
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Browse shelves built server side, already split by language.
    func fetchHomeSections(per: Int = 20, refresh: Bool = false) async -> [HomeSection]? {
        var query = [URLQueryItem(name: "per", value: String(per))]
        if refresh {
            // Pull-to-refresh should genuinely re-roll the shelves, not replay
            // the cached page.
            query.append(URLQueryItem(name: "refresh", value: "1"))
        }
        guard isConfigured, let endpoint = url(path: "/home", query: query)
        else { return nil }

        do {
            let (data, response) = try await self.session.data(from: endpoint)
            guard (200 ..< 300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawSections = object["sections"] as? [[String: Any]]
            else { return nil }

            let sections: [HomeSection] = rawSections.compactMap { raw in
                guard let title = raw["title"] as? String,
                      let rows = raw["items"] as? [[String: Any]] else { return nil }
                let items: [HomeItem] = rows.compactMap { row in
                    guard let videoId = row["videoId"] as? String, !videoId.isEmpty
                    else { return nil }
                    return HomeItem(kind: .song,
                                    primaryId: videoId,
                                    title: (row["title"] as? String) ?? "Unknown",
                                    subtitle: row["artist"] as? String,
                                    thumbnailURL: row["thumbnail"] as? String)
                }
                guard !items.isEmpty else { return nil }
                return HomeSection(title: title,
                                   strapline: raw["subtitle"] as? String,
                                   items: items)
            }
            return sections.isEmpty ? nil : sections
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// Open a station described in words, or an automatic one when the
    /// prompt is empty.
    ///
    /// This comes back as soon as the first handful of songs are playable
    /// rather than when the whole list is ready, so playback can start in a
    /// few seconds. `continueAIRadio` collects the rest.
    func openAIRadio(prompt: String, limit: Int = 20) async -> AIRadioBatch? {
        await radioBatch([
            URLQueryItem(name: "prompt", value: prompt),
            URLQueryItem(name: "limit", value: String(limit)),
        ])
    }

    /// Whatever a station has found beyond the first `after` tracks.
    func continueAIRadio(station: String, after: Int) async -> AIRadioBatch? {
        await radioBatch([
            URLQueryItem(name: "station", value: station),
            URLQueryItem(name: "after", value: String(after)),
        ])
    }

    /// The server resolves every suggestion against YouTube Music, so nothing
    /// unplayable comes back.
    private func radioBatch(_ query: [URLQueryItem]) async -> AIRadioBatch? {
        guard isConfigured, let endpoint = url(path: "/airadio", query: query)
        else { return nil }

        do {
            let (data, response) = try await self.session.data(from: endpoint)
            guard (200 ..< 300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            // A station can carry an error and still be playable - the quick
            // pass failing while the long wave lands, say - so the message is
            // recorded but the batch is still handed back.
            if let message = object["error"] as? String, !message.isEmpty {
                lastErrorMessage = message
            }
            // An automatic station is only named once the long wave has run,
            // so this fills in on a later poll rather than the first one.
            if let theme = object["prompt"] as? String, !theme.isEmpty {
                lastAIRadioTheme = theme
            }

            let rows = (object["tracks"] as? [[String: Any]]) ?? []
            let tracks: [AppTrack] = rows.compactMap { row in
                guard let videoId = row["videoId"] as? String, !videoId.isEmpty
                else { return nil }
                return AppTrack(
                    id: UUID().uuidString,
                    canonicalId: "yt:\(videoId)",
                    title: (row["title"] as? String) ?? "Unknown",
                    artist: (row["artist"] as? String) ?? "Unknown",
                    thumbnailURL: row["thumbnail"] as? String,
                    durationText: nil,
                    source: .youtube(videoId: videoId))
            }
            return AIRadioBatch(
                station: (object["station"] as? String) ?? "",
                theme: object["prompt"] as? String,
                tracks: tracks,
                total: (object["total"] as? Int) ?? tracks.count,
                pending: (object["pending"] as? Bool) ?? false)
        } catch {
            lastErrorMessage = error.localizedDescription
            return nil
        }
    }

    /// The DJ's line introducing the track that is coming up next.
    ///
    /// Ask for this while the current track is still playing. Writing and
    /// speaking a sentence takes the server the better part of ten seconds,
    /// and the whole point is that none of them are waited on.
    func fetchDJLine(theme: String?,
                     previous: AppTrack?,
                     upcoming: AppTrack,
                     language: String,
                     isFirst: Bool) async -> AIDJLine? {
        var query = [
            URLQueryItem(name: "artist", value: upcoming.artist),
            URLQueryItem(name: "title", value: upcoming.title),
            URLQueryItem(name: "lang", value: language),
            URLQueryItem(name: "first", value: isFirst ? "1" : "0"),
        ]
        if let theme, !theme.isEmpty {
            query.append(URLQueryItem(name: "theme", value: theme))
        }
        if let previous, !isFirst {
            query.append(URLQueryItem(name: "prevArtist", value: previous.artist))
            query.append(URLQueryItem(name: "prevTitle", value: previous.title))
        }

        guard isConfigured, let endpoint = url(path: "/djline", query: query)
        else { return nil }

        do {
            let (data, response) = try await self.session.data(from: endpoint)
            guard (200 ..< 300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let text = object["text"] as? String, !text.isEmpty
            else { return nil }

            // Built from the id rather than the server's `audioPath`, because
            // that already carries a query string and `url(path:query:)` would
            // overwrite it with the token.
            var audio: URL?
            if let identifier = object["audio"] as? String, !identifier.isEmpty {
                audio = url(path: "/djvoice",
                            query: [URLQueryItem(name: "id", value: identifier)])
            }
            return AIDJLine(text: text, audio: audio)
        } catch {
            return nil
        }
    }

    /// Timed lyrics, and their translation when the server has one ready.
    ///
    /// Returns nil rather than an empty snapshot when the resolver cannot
    /// answer, so the caller knows to fall back to lrclib directly.
    func fetchLyrics(title: String,
                     artist: String,
                     duration: Int?,
                     target: String?) async -> LyricsSnapshot? {
        guard isConfigured, !title.isEmpty else { return nil }
        var query = [
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "artist", value: artist),
        ]
        if let duration, duration > 0 {
            query.append(URLQueryItem(name: "duration", value: String(duration)))
        }
        if let target, !target.isEmpty {
            query.append(URLQueryItem(name: "target", value: target))
        } else {
            query.append(URLQueryItem(name: "translate", value: "0"))
        }
        guard let endpoint = url(path: "/lyrics", query: query) else { return nil }

        do {
            let (data, response) = try await session.data(from: endpoint)
            guard (200 ..< 300).contains((response as? HTTPURLResponse)?.statusCode ?? 0),
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }

            var snapshot = LyricsSnapshot()
            snapshot.source = object["source"] as? String
            snapshot.language = object["language"] as? String
            snapshot.translated = (object["translated"] as? Bool) ?? false
            snapshot.translating = (object["translating"] as? Bool) ?? false
            snapshot.plain = (object["plain"] as? String) ?? ""
            snapshot.plainTranslated = object["plainTranslated"] as? String

            let rows = (object["lines"] as? [[String: Any]]) ?? []
            snapshot.lines = rows.enumerated().compactMap { index, row in
                guard let text = row["text"] as? String else { return nil }
                let time = (row["t"] as? Double) ?? 0
                return LyricLine(id: index, time: time, text: text,
                                 translation: row["tr"] as? String)
            }
            // An empty answer is still an answer: the server searched lrclib
            // more thoroughly than the phone would, so do not search again.
            return snapshot
        } catch {
            return nil
        }
    }

    /// Report how a track was actually received. Skips are the signal the
    /// ranker learns from, so this is fire-and-forget on every track change.
    func reportPlayback(track: AppTrack,
                        playedSeconds: Double,
                        duration: Double,
                        explicit: String? = nil) async {
        guard isConfigured else { return }
        var query = [
            URLQueryItem(name: "artist", value: track.artist),
            URLQueryItem(name: "title", value: track.title),
            URLQueryItem(name: "played", value: String(Int(playedSeconds))),
            URLQueryItem(name: "duration", value: String(Int(duration))),
        ]
        if case .youtube(let videoId) = track.source {
            query.append(URLQueryItem(name: "v", value: videoId))
        }
        if let explicit {
            query.append(URLQueryItem(name: "explicit", value: explicit))
        }
        guard let endpoint = url(path: "/feedback", query: query) else { return }
        _ = try? await self.session.data(from: endpoint)
    }

    func resolve(videoId: String) async throws -> ResolvedStream {
        guard isConfigured,
              let resolveURL = url(path: "/resolve",
                                   query: [URLQueryItem(name: "v", value: videoId)]),
              let playbackURL = streamURL(videoId: videoId) else {
            throw StreamResolverError.notConfigured
        }

        let (data, response) = try await session.data(from: resolveURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw StreamResolverError.badResponse(status)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StreamResolverError.malformed
        }

        isReachable = true

        return ResolvedStream(
            videoId: videoId,
            title: object["title"] as? String,
            artist: object["artist"] as? String,
            duration: (object["duration"] as? NSNumber)?.doubleValue,
            itag: object["itag"] as? String,
            ext: object["ext"] as? String,
            mime: object["mime"] as? String,
            bitrate: (object["bitrate"] as? NSNumber)?.intValue,
            filesize: (object["filesize"] as? NSNumber)?.int64Value,
            progressive: object["progressive"] as? Bool == true,
            streamURL: playbackURL
        )
    }

    /// Ask the PC to resolve, download, and fast-start-remux the next track.
    /// Playback itself never depends on this call: /stream performs the same
    /// preparation on demand if the cache is cold.
    func prepare(videoId: String) async throws {
        guard isConfigured,
              let prepareURL = url(path: "/prepare",
                                   query: [URLQueryItem(name: "v", value: videoId)]) else {
            throw StreamResolverError.notConfigured
        }

        let (_, response) = try await session.data(from: prepareURL)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            throw StreamResolverError.badResponse(status)
        }
        isReachable = true
    }

    /// Ask the PC to prepare several upcoming tracks at once.
    ///
    /// Returns as soon as the work is queued. Resolving a track costs the
    /// server about a second of YouTube lookup; doing that ahead of time means
    /// the phone spends one small request here instead of waiting for it at
    /// the moment the listener presses play.
    func warm(videoIds: [String]) async {
        let ids = videoIds.filter { !$0.isEmpty }
        guard isConfigured, !ids.isEmpty,
              let endpoint = url(
                path: "/warm",
                query: [URLQueryItem(name: "v", value: ids.joined(separator: ","))]
              ) else {
            return
        }
        _ = try? await session.data(from: endpoint)
    }

    /// Pull a prepared track onto the device in one pass, straight to disk.
    ///
    /// The caller owns the returned file and must move or delete it.
    func downloadPrepared(videoId: String) async throws -> URL {
        guard isConfigured, let endpoint = streamURL(videoId: videoId) else {
            throw StreamResolverError.notConfigured
        }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 180

        let (location, response) = try await session.download(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            try? FileManager.default.removeItem(at: location)
            throw StreamResolverError.badResponse(status)
        }
        isReachable = true
        return location
    }

    /// A playback candidate for the resolver. Errors remain visible to the
    /// caller so it cannot silently fall back to a known-truncated direct URL.
    func playbackOption(for videoId: String) async throws -> AudioStreamOption {
        guard isConfigured else { throw StreamResolverError.notConfigured }
        do {
            let resolved = try await resolve(videoId: videoId)
            return AudioStreamOption(
                id: "resolver:\(videoId)",
                url: resolved.streamURL,
                sourceClientName: "RESOLVER",
                sourceClientVersion: "1.1",
                sourceUserAgent: nil,
                mimeType: resolved.mime,
                codec: resolved.ext,
                container: (resolved.ext ?? "audio").uppercased(),
                bitrate: resolved.bitrate,
                averageBitrate: resolved.bitrate,
                audioQuality: resolved.itag.map { "itag \($0)" },
                contentLength: resolved.filesize,
                itag: Int(resolved.itag ?? ""),
                isHLSManifest: false,
                requiresRemux: !resolved.progressive,
                duration: resolved.duration
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            isReachable = false
            throw error
        }
    }
}
