import Foundation

struct AudioStreamOption: Identifiable, Equatable {
    let id: String
    let url: URL
    let sourceClientName: String
    let sourceClientVersion: String
    let mimeType: String?
    let codec: String?
    let container: String
    let bitrate: Int?
    let averageBitrate: Int?
    let audioQuality: String?
    let contentLength: Int64?
    let itag: Int?
    let isHLSManifest: Bool

    var effectiveBitrate: Int? {
        averageBitrate ?? bitrate
    }

    var bitrateText: String {
        guard let effectiveBitrate, effectiveBitrate > 0 else {
            return "未知"
        }
        return "\(max(effectiveBitrate / 1000, 1)) kbps"
    }

    var displayTitle: String {
        if isHLSManifest {
            return "HLS 自適應"
        }
        return "\(container) • \(bitrateText)"
    }

    var shortDescription: String {
        var parts: [String] = [container, bitrateText]
        if let codec, !codec.isEmpty {
            parts.append(codec)
        }
        return parts.joined(separator: " • ")
    }
}

enum YouTubeMusicServiceError: LocalizedError {
    case invalidResponse
    case parsingFailed
    case noPlayableStream
    case notLoggedIn

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "YouTube 回應無效"
        case .parsingFailed:
            return "YouTube 資料解析失敗"
        case .noPlayableStream:
            return "找不到可播放音訊串流"
        case .notLoggedIn:
            return "尚未登入 YouTube Music"
        }
    }
}

/// 登入後注入到每次 API 請求的認證內容。
struct YouTubeAuthContext {
    let cookie: String
    let visitorData: String
    let dataSyncId: String
    let sapisid: String?
}

final class YouTubeMusicService {
    static let shared = YouTubeMusicService()

    private let session: URLSession

    /// 提供帳號登入後的 cookie / visitorData / dataSyncId；可為 nil（未登入）。
    /// 這個 closure 會在每次建立 request 前讀取，因此 AccountStore 更新後會自動生效。
    var authProvider: (() -> YouTubeAuthContext?)?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        // 停用 URLSession 的自動 cookie 儲存，避免 WebView 的 cookie 意外附到 API 請求
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        self.session = URLSession(configuration: configuration)
    }

    func searchSongs(query: String) async throws -> [YouTubeSearchSong] {
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": "WEB_REMIX",
                    "clientVersion": "1.20250310.01.00",
                    "hl": "en",
                    "gl": "US"
                ]
            ],
            "query": query
        ]

        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/search",
            payload: payload,
            clientName: "67",
            clientVersion: "1.20250310.01.00",
            userAgent: "Mozilla/5.0"
        )

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw YouTubeMusicServiceError.parsingFailed
        }

        let renderers = collectDictionaries(forKey: "musicResponsiveListItemRenderer", in: object)
        var unique = Set<String>()
        var songs: [YouTubeSearchSong] = []

        for renderer in renderers {
            guard let videoId = extractVideoId(from: renderer), !unique.contains(videoId) else {
                continue
            }

            let title = extractTitle(from: renderer)
            if title.isEmpty {
                continue
            }

            let subtitleParts = extractSubtitleParts(from: renderer)
            let artist = extractArtistName(from: renderer, subtitleParts: subtitleParts)
            let duration = subtitleParts.reversed().first(where: { isDurationToken($0) })
            let thumbnail = extractThumbnailURL(from: renderer)

            songs.append(
                YouTubeSearchSong(
                    videoId: videoId,
                    title: title,
                    artist: artist,
                    thumbnailURL: thumbnail,
                    durationText: duration
                )
            )
            unique.insert(videoId)
        }

        return songs
    }

    func autocompleteSuggestions(query: String) async throws -> [String] {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedQuery.isEmpty else {
            return []
        }

        var components = URLComponents(string: "https://suggestqueries.google.com/complete/search")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "firefox"),
            URLQueryItem(name: "ds", value: "yt"),
            URLQueryItem(name: "hl", value: "zh-TW"),
            URLQueryItem(name: "q", value: normalizedQuery)
        ]

        guard let url = components?.url else {
            throw YouTubeMusicServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw YouTubeMusicServiceError.invalidResponse
        }

        guard
            let payload = try JSONSerialization.jsonObject(with: data) as? [Any],
            payload.count > 1,
            let rawSuggestions = payload[1] as? [Any]
        else {
            return []
        }

        var suggestions: [String] = []
        for entry in rawSuggestions {
            if let suggestion = entry as? String {
                let normalized = suggestion.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty,
                   normalized.caseInsensitiveCompare(normalizedQuery) != .orderedSame,
                   !suggestions.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                    suggestions.append(normalized)
                }
                continue
            }

            if let nested = entry as? [Any],
               let first = nested.first as? String {
                let normalized = first.trimmingCharacters(in: .whitespacesAndNewlines)
                if !normalized.isEmpty,
                   normalized.caseInsensitiveCompare(normalizedQuery) != .orderedSame,
                   !suggestions.contains(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                    suggestions.append(normalized)
                }
            }
        }

        return Array(suggestions.prefix(10))
    }

    func resolveAudioStreamURL(videoId: String) async throws -> URL {
        guard let firstURL = try await resolveAudioStreams(videoId: videoId).first?.url else {
            throw YouTubeMusicServiceError.noPlayableStream
        }
        return firstURL
    }

    func resolveAudioStreamURLs(videoId: String, limit: Int = 12) async throws -> [URL] {
        let streams = try await resolveAudioStreams(videoId: videoId, limit: limit)
        return streams.map(\.url)
    }

    func resolveAudioStreams(videoId: String, limit: Int = 12) async throws -> [AudioStreamOption] {
        var orderedStreams: [AudioStreamOption] = []

        for profile in playerClientProfiles {
            let streams = try await fetchPlayableStreams(videoId: videoId, profile: profile, allowWebM: false)
            orderedStreams.append(contentsOf: streams)
        }

        let deduplicated = deduplicate(streams: orderedStreams)
        if deduplicated.isEmpty {
            throw YouTubeMusicServiceError.noPlayableStream
        }

        return Array(deduplicated.prefix(max(limit, 1)))
    }

    private func fetchPlayableStreams(videoId: String, profile: PlayerClientProfile, allowWebM: Bool) async throws -> [AudioStreamOption] {
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": profile.clientName,
                    "clientVersion": profile.clientVersion,
                    "hl": "en",
                    "gl": "US",
                    "osVersion": profile.osVersion
                ]
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/player",
            payload: payload,
            clientName: profile.clientId,
            clientVersion: profile.clientVersion,
            userAgent: profile.userAgent
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        guard
            let streamingData = object["streamingData"] as? [String: Any]
        else {
            return []
        }

        var resolved: [AudioStreamOption] = []

        if let hlsManifest = streamingData["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsManifest) {
            resolved.append(
                AudioStreamOption(
                    id: "hls:\(profile.clientName):\(hlsURL.absoluteString)",
                    url: hlsURL,
                    sourceClientName: profile.clientName,
                    sourceClientVersion: profile.clientVersion,
                    mimeType: "application/x-mpegURL",
                    codec: nil,
                    container: "HLS",
                    bitrate: nil,
                    averageBitrate: nil,
                    audioQuality: "AUTO",
                    contentLength: nil,
                    itag: nil,
                    isHLSManifest: true
                )
            )
        }

        let adaptive = (streamingData["adaptiveFormats"] as? [[String: Any]]) ?? []
        let formats = (streamingData["formats"] as? [[String: Any]]) ?? []
        let candidates = adaptive + formats
        let sortedAudioFormats = candidates
            .filter { format in
                isLikelyAudioFormat(format) && (allowWebM || !isWebMFormat(format))
            }
            .sorted { playbackPriority(for: $0) > playbackPriority(for: $1) }

        resolved.append(contentsOf: sortedAudioFormats.compactMap { extractPlayableStream(from: $0, profile: profile) })
        return deduplicate(streams: resolved)
    }

    private func fetchPlayableURLs(videoId: String, profile: PlayerClientProfile, allowWebM: Bool) async throws -> [URL] {
        let payload: [String: Any] = [
            "context": [
                "client": [
                    "clientName": profile.clientName,
                    "clientVersion": profile.clientVersion,
                    "hl": "en",
                    "gl": "US",
                    "osVersion": profile.osVersion
                ]
            ],
            "videoId": videoId,
            "contentCheckOk": true,
            "racyCheckOk": true
        ]

        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/player",
            payload: payload,
            clientName: profile.clientId,
            clientVersion: profile.clientVersion,
            userAgent: profile.userAgent
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        guard
            let streamingData = object["streamingData"] as? [String: Any]
        else {
            return []
        }

        var resolved: [URL] = []

        // HLS manifests are usually the most compatible option on iOS AVPlayer.
        if let hlsManifest = streamingData["hlsManifestUrl"] as? String,
           let hlsURL = URL(string: hlsManifest) {
            resolved.append(hlsURL)
        }

        let adaptive = (streamingData["adaptiveFormats"] as? [[String: Any]]) ?? []
        let formats = (streamingData["formats"] as? [[String: Any]]) ?? []
        let candidates = adaptive + formats
        let sortedAudioFormats = candidates
            .filter { format in
                isLikelyAudioFormat(format) && (allowWebM || !isWebMFormat(format))
            }
            .sorted { playbackPriority(for: $0) > playbackPriority(for: $1) }

        resolved.append(contentsOf: sortedAudioFormats.compactMap { extractPlayableURL(from: $0) })

        return deduplicate(urls: resolved)
    }

    private func requestJSON(
        endpoint: String,
        payload: [String: Any],
        clientName: String,
        clientVersion: String,
        userAgent: String,
        useLogin: Bool = false,
        loginSupported: Bool = true
    ) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw YouTubeMusicServiceError.invalidResponse
        }

        var finalPayload = payload
        let auth = useLogin ? authProvider?() : nil
        if let auth {
            if var context = finalPayload["context"] as? [String: Any],
               var client = context["client"] as? [String: Any] {
                if !auth.visitorData.isEmpty {
                    client["visitorData"] = auth.visitorData
                }
                context["client"] = client
                if loginSupported, !auth.dataSyncId.isEmpty {
                    context["user"] = ["onBehalfOfUser": auth.dataSyncId]
                }
                finalPayload["context"] = context
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: finalPayload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        if let auth, useLogin, loginSupported, !auth.cookie.isEmpty {
            request.setValue(auth.cookie, forHTTPHeaderField: "Cookie")
            if let sapisid = auth.sapisid {
                let timestamp = Int(Date().timeIntervalSince1970)
                let hash = sha1("\(timestamp) \(sapisid) https://music.youtube.com")
                let authHeader = "SAPISIDHASH \(timestamp)_\(hash) SAPISID1PHASH \(timestamp)_\(hash) SAPISID3PHASH \(timestamp)_\(hash)"
                request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw YouTubeMusicServiceError.invalidResponse
        }
        return data
    }

    private func sha1(_ input: String) -> String {
        // 純 Swift SHA-1，避免引入 CommonCrypto
        let bytes: [UInt8] = Array(input.utf8)
        var h0: UInt32 = 0x67452301
        var h1: UInt32 = 0xEFCDAB89
        var h2: UInt32 = 0x98BADCFE
        var h3: UInt32 = 0x10325476
        var h4: UInt32 = 0xC3D2E1F0

        var padded = bytes
        let messageLengthBits = UInt64(bytes.count) * 8
        padded.append(0x80)
        while padded.count % 64 != 56 {
            padded.append(0)
        }
        for i in stride(from: 7, through: 0, by: -1) {
            padded.append(UInt8((messageLengthBits >> UInt64(i * 8)) & 0xFF))
        }

        for chunkStart in stride(from: 0, to: padded.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0 ..< 16 {
                let base = chunkStart + i * 4
                w[i] = (UInt32(padded[base]) << 24) |
                       (UInt32(padded[base + 1]) << 16) |
                       (UInt32(padded[base + 2]) << 8) |
                       UInt32(padded[base + 3])
            }
            for i in 16 ..< 80 {
                let value = w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16]
                w[i] = (value << 1) | (value >> 31)
            }

            var a = h0, b = h1, c = h2, d = h3, e = h4

            for i in 0 ..< 80 {
                let f: UInt32
                let k: UInt32
                switch i {
                case 0 ..< 20:
                    f = (b & c) | ((~b) & d)
                    k = 0x5A827999
                case 20 ..< 40:
                    f = b ^ c ^ d
                    k = 0x6ED9EBA1
                case 40 ..< 60:
                    f = (b & c) | (b & d) | (c & d)
                    k = 0x8F1BBCDC
                default:
                    f = b ^ c ^ d
                    k = 0xCA62C1D6
                }

                let temp = ((a << 5) | (a >> 27)) &+ f &+ e &+ k &+ w[i]
                e = d
                d = c
                c = (b << 30) | (b >> 2)
                b = a
                a = temp
            }

            h0 = h0 &+ a
            h1 = h1 &+ b
            h2 = h2 &+ c
            h3 = h3 &+ d
            h4 = h4 &+ e
        }

        return String(format: "%08x%08x%08x%08x%08x", h0, h1, h2, h3, h4)
    }

    private func extractVideoId(from renderer: [String: Any]) -> String? {
        if
            let playlistItemData = renderer["playlistItemData"] as? [String: Any],
            let videoId = playlistItemData["videoId"] as? String,
            !videoId.isEmpty
        {
            return videoId
        }

        if
            let overlay = renderer["overlay"] as? [String: Any],
            let thumbnailOverlay = overlay["musicItemThumbnailOverlayRenderer"] as? [String: Any],
            let content = thumbnailOverlay["content"] as? [String: Any],
            let button = content["musicPlayButtonRenderer"] as? [String: Any],
            let nav = button["playNavigationEndpoint"] as? [String: Any],
            let watch = nav["watchEndpoint"] as? [String: Any],
            let videoId = watch["videoId"] as? String,
            !videoId.isEmpty
        {
            return videoId
        }

        return nil
    }

    private func extractTitle(from renderer: [String: Any]) -> String {
        guard
            let columns = renderer["flexColumns"] as? [[String: Any]],
            let first = columns.first,
            let firstRenderer = first["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
            let text = firstRenderer["text"] as? [String: Any],
            let runs = text["runs"] as? [[String: Any]]
        else {
            return ""
        }

        return runs.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func extractSubtitleParts(from renderer: [String: Any]) -> [String] {
        guard
            let columns = renderer["flexColumns"] as? [[String: Any]],
            columns.count > 1,
            let secondRenderer = columns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
            let text = secondRenderer["text"] as? [String: Any],
            let runs = text["runs"] as? [[String: Any]]
        else {
            return []
        }

        let merged = runs.compactMap { $0["text"] as? String }.joined()
        return merged
            .split(separator: "•")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func extractArtistName(from renderer: [String: Any], subtitleParts: [String]) -> String {
        if let fromRuns = extractArtistNameFromRuns(from: renderer) {
            return fromRuns
        }

        if let fromParts = subtitleParts.first(where: { !isMetadataArtistToken($0) }) {
            return fromParts
        }

        return subtitleParts.first ?? "Unknown Artist"
    }

    private func extractArtistNameFromRuns(from renderer: [String: Any]) -> String? {
        guard
            let columns = renderer["flexColumns"] as? [[String: Any]],
            columns.count > 1,
            let secondRenderer = columns[1]["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
            let text = secondRenderer["text"] as? [String: Any],
            let runs = text["runs"] as? [[String: Any]]
        else {
            return nil
        }

        var firstCandidate: String?

        for run in runs {
            guard let value = run["text"] as? String else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "•" || isMetadataArtistToken(trimmed) {
                continue
            }

            if firstCandidate == nil {
                firstCandidate = trimmed
            }

            if run["navigationEndpoint"] != nil {
                return trimmed
            }
        }

        return firstCandidate
    }

    private func isMetadataArtistToken(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.isEmpty {
            return true
        }

        if isDurationToken(value) {
            return true
        }

        if normalized.hasSuffix(" views") || normalized.hasSuffix(" view") {
            return true
        }

        let metadataTokens: Set<String> = [
            "song", "songs", "video", "videos", "album", "single", "ep", "playlist", "mix",
            "歌曲", "曲目", "影片", "專輯", "單曲", "播放清單", "混音"
        ]

        return metadataTokens.contains(normalized)
    }

    private func extractThumbnailURL(from renderer: [String: Any]) -> String? {
        guard
            let thumbnail = renderer["thumbnail"] as? [String: Any],
            let musicThumb = thumbnail["musicThumbnailRenderer"] as? [String: Any],
            let container = musicThumb["thumbnail"] as? [String: Any],
            let thumbs = container["thumbnails"] as? [[String: Any]]
        else {
            return nil
        }

        return thumbs.last?["url"] as? String
    }

    private func collectDictionaries(forKey key: String, in object: Any) -> [[String: Any]] {
        var results: [[String: Any]] = []
        if let dictionary = object as? [String: Any] {
            if let nested = dictionary[key] as? [String: Any] {
                results.append(nested)
            }
            for value in dictionary.values {
                results.append(contentsOf: collectDictionaries(forKey: key, in: value))
            }
        } else if let array = object as? [Any] {
            for element in array {
                results.append(contentsOf: collectDictionaries(forKey: key, in: element))
            }
        }
        return results
    }

    private func extractPlayableURL(from format: [String: Any]) -> URL? {
        if let urlString = format["url"] as? String {
            return URL(string: urlString)
        }

        guard
            let cipher = format["signatureCipher"] as? String,
            let components = URLComponents(string: "https://dummy.invalid/?\(cipher)"),
            let items = components.queryItems
        else {
            return nil
        }

        let values = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        guard let rawURL = values["url"], var finalComponents = URLComponents(string: rawURL) else {
            return nil
        }

        if let signature = values["sig"] ?? values["signature"],
           let sp = values["sp"] {
            var queryItems = finalComponents.queryItems ?? []
            queryItems.append(URLQueryItem(name: sp, value: signature))
            finalComponents.queryItems = queryItems
        }

        return finalComponents.url
    }

    private func extractPlayableStream(from format: [String: Any], profile: PlayerClientProfile) -> AudioStreamOption? {
        guard let url = extractPlayableURL(from: format) else {
            return nil
        }

        let mimeType = format["mimeType"] as? String
        let codec = parseCodec(from: mimeType)
        let container = containerLabel(from: mimeType)
        let bitrate = format["bitrate"] as? Int
        let averageBitrate = format["averageBitrate"] as? Int
        let audioQuality = format["audioQuality"] as? String
        let itag = format["itag"] as? Int

        var contentLength: Int64?
        if let rawContentLength = format["contentLength"] as? String {
            contentLength = Int64(rawContentLength)
        } else if let int64Length = format["contentLength"] as? Int64 {
            contentLength = int64Length
        } else if let intLength = format["contentLength"] as? Int {
            contentLength = Int64(intLength)
        }

        return AudioStreamOption(
            id: "fmt:\(profile.clientName):\(itag ?? -1):\(url.absoluteString)",
            url: url,
            sourceClientName: profile.clientName,
            sourceClientVersion: profile.clientVersion,
            mimeType: mimeType,
            codec: codec,
            container: container,
            bitrate: bitrate,
            averageBitrate: averageBitrate,
            audioQuality: audioQuality,
            contentLength: contentLength,
            itag: itag,
            isHLSManifest: false
        )
    }

    private func parseCodec(from mimeType: String?) -> String? {
        guard let mimeType else {
            return nil
        }

        let parts = mimeType.split(separator: ";")
        guard parts.count > 1 else {
            return nil
        }

        for part in parts {
            let trimmed = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.lowercased().hasPrefix("codecs=") else {
                continue
            }

            let rawValue = trimmed.dropFirst("codecs=".count)
            return String(rawValue).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }

        return nil
    }

    private func containerLabel(from mimeType: String?) -> String {
        guard let lowered = mimeType?.lowercased() else {
            return "Audio"
        }

        if lowered.contains("mpegurl") || lowered.contains("x-mpegurl") {
            return "HLS"
        }
        if lowered.contains("audio/mp4") || lowered.contains("audio/x-m4a") || lowered.contains("mp4a") {
            return "M4A"
        }
        if lowered.contains("audio/mpeg") || lowered.contains("audio/mp3") {
            return "MP3"
        }
        if lowered.contains("audio/aac") {
            return "AAC"
        }
        if lowered.contains("audio/webm") {
            return "WEBM"
        }
        if lowered.contains("audio/ogg") {
            return "OGG"
        }
        return "Audio"
    }

    private func isLikelyAudioFormat(_ format: [String: Any]) -> Bool {
        guard let mimeType = (format["mimeType"] as? String)?.lowercased() else {
            return false
        }

        guard mimeType.contains("audio/") else {
            return false
        }

        // Restrict to codecs/container families that are known to decode reliably in iOS AVPlayer.
        return mimeType.contains("audio/mp4") ||
            mimeType.contains("mp4a") ||
            mimeType.contains("audio/mpeg") ||
            mimeType.contains("audio/mp3") ||
            mimeType.contains("audio/aac") ||
            mimeType.contains("audio/x-m4a")
    }

    private func isWebMFormat(_ format: [String: Any]) -> Bool {
        guard let mimeType = (format["mimeType"] as? String)?.lowercased() else {
            return false
        }
        return mimeType.contains("webm") || mimeType.contains("opus")
    }

    private func playbackPriority(for format: [String: Any]) -> Int {
        guard let mimeType = (format["mimeType"] as? String)?.lowercased() else {
            return 0
        }

        var score = 0
        if mimeType.contains("audio/mp4") || mimeType.contains("mp4a") {
            score += 1_000
        } else if mimeType.contains("audio/aac") {
            score += 900
        } else if mimeType.contains("audio/mpeg") || mimeType.contains("audio/mp3") {
            score += 800
        } else if mimeType.contains("audio/ogg") {
            score += 600
        } else if mimeType.contains("audio/webm") {
            score += 100
        }

        if let averageBitrate = format["averageBitrate"] as? Int {
            score += min(averageBitrate / 1_000, 500)
        } else if let bitrate = format["bitrate"] as? Int {
            score += min(bitrate / 1_000, 500)
        }

        return score
    }

    private func isDurationToken(_ value: String) -> Bool {
        let regex = try? NSRegularExpression(pattern: "^\\d{1,2}:\\d{2}(:\\d{2})?$")
        let range = NSRange(location: 0, length: value.utf16.count)
        return regex?.firstMatch(in: value, range: range) != nil
    }

    private func deduplicate(urls: [URL]) -> [URL] {
        var seen = Set<String>()
        var result: [URL] = []

        for url in urls {
            let key = url.absoluteString
            if seen.insert(key).inserted {
                result.append(url)
            }
        }

        return result
    }

    private func deduplicate(streams: [AudioStreamOption]) -> [AudioStreamOption] {
        var seen = Set<String>()
        var result: [AudioStreamOption] = []

        for stream in streams {
            let key = stream.url.absoluteString
            if seen.insert(key).inserted {
                result.append(stream)
            }
        }

        return result
    }
}

private struct PlayerClientProfile {
    let clientName: String
    let clientVersion: String
    let clientId: String
    let userAgent: String
    let osVersion: String
}

private let playerClientProfiles: [PlayerClientProfile] = [
    PlayerClientProfile(
        clientName: "IOS",
        clientVersion: "20.10.4",
        clientId: "5",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        osVersion: "18.3.2.22D82"
    ),
    PlayerClientProfile(
        clientName: "ANDROID_VR",
        clientVersion: "1.61.48",
        clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Oculus Quest 3)",
        osVersion: "12"
    ),
    PlayerClientProfile(
        clientName: "WEB",
        clientVersion: "2.20250312.04.00",
        clientId: "1",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
        osVersion: "10.0"
    )
]
// MARK: - Account / Home / Library APIs

extension YouTubeMusicService {
    private var webRemixClientName: String { "WEB_REMIX" }
    private var webRemixClientVersion: String { "1.20250310.01.00" }
    private var webRemixClientId: String { "67" }
    private var webRemixUserAgent: String { "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0 Safari/537.36" }

    private func baseContext() -> [String: Any] {
        [
            "context": [
                "client": [
                    "clientName": webRemixClientName,
                    "clientVersion": webRemixClientVersion,
                    "hl": "zh-TW",
                    "gl": "TW"
                ]
            ]
        ]
    }

    /// 對應 Android 版 `YouTube.accountInfo()`，需要登入 cookie。
    func fetchAccountInfo() async throws -> YouTubeAccountInfo {
        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/account/account_menu",
            payload: baseContext(),
            clientName: webRemixClientId,
            clientVersion: webRemixClientVersion,
            userAgent: webRemixUserAgent,
            useLogin: true
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeMusicServiceError.parsingFailed
        }

        // 在 response 中尋找 activeAccountHeaderRenderer
        let renderers = collectDictionaries(forKey: "activeAccountHeaderRenderer", in: object)
        guard let renderer = renderers.first else {
            throw YouTubeMusicServiceError.notLoggedIn
        }

        let name = firstRunText(in: renderer["accountName"]) ?? ""
        let email = firstRunText(in: renderer["accountByline"])
        let channelHandle = firstRunText(in: renderer["channelHandle"])

        var avatarURL: String?
        if let photo = renderer["accountPhoto"] as? [String: Any],
           let thumbs = photo["thumbnails"] as? [[String: Any]] {
            avatarURL = thumbs.last?["url"] as? String
        }

        return YouTubeAccountInfo(
            name: name,
            email: email,
            channelHandle: channelHandle,
            avatarURL: avatarURL
        )
    }

    /// 取得首頁推薦（對應 Android HomePage，需登入才能拿到個人化結果，但未登入也可抓公共內容）。
    func fetchHomeFeed() async throws -> HomeFeed {
        var payload = baseContext()
        payload["browseId"] = "FEmusic_home"
        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/browse",
            payload: payload,
            clientName: webRemixClientId,
            clientVersion: webRemixClientVersion,
            userAgent: webRemixUserAgent,
            useLogin: true
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeMusicServiceError.parsingFailed
        }

        let carousels = collectDictionaries(forKey: "musicCarouselShelfRenderer", in: object)
        var sections: [HomeSection] = []

        for carousel in carousels {
            guard let section = parseHomeSection(from: carousel) else { continue }
            if section.items.isEmpty { continue }
            sections.append(section)
        }

        return HomeFeed(sections: sections)
    }

    /// 取得登入使用者的播放清單（對應 Android LibraryPage FEmusic_liked_playlists）。
    func fetchLibraryPlaylists() async throws -> [LibraryPlaylist] {
        var payload = baseContext()
        payload["browseId"] = "FEmusic_liked_playlists"
        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/browse",
            payload: payload,
            clientName: webRemixClientId,
            clientVersion: webRemixClientVersion,
            userAgent: webRemixUserAgent,
            useLogin: true
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeMusicServiceError.parsingFailed
        }

        let grids = collectDictionaries(forKey: "musicTwoRowItemRenderer", in: object)
        var playlists: [LibraryPlaylist] = []
        var seen = Set<String>()

        for renderer in grids {
            guard
                let nav = renderer["navigationEndpoint"] as? [String: Any],
                let browse = nav["browseEndpoint"] as? [String: Any],
                let browseId = browse["browseId"] as? String,
                browseId.hasPrefix("VL") || browseId.hasPrefix("MPRE") || browseId.hasPrefix("MPSP") || browseId.contains("playlist")
            else {
                continue
            }
            if seen.contains(browseId) { continue }
            seen.insert(browseId)

            let title = firstRunText(in: renderer["title"]) ?? "未命名播放清單"
            let subtitle = firstRunText(in: renderer["subtitle"])
            var thumbURL: String?
            if let thumbRenderer = renderer["thumbnailRenderer"] as? [String: Any],
               let musicThumb = thumbRenderer["musicThumbnailRenderer"] as? [String: Any],
               let container = musicThumb["thumbnail"] as? [String: Any],
               let thumbs = container["thumbnails"] as? [[String: Any]] {
                thumbURL = thumbs.last?["url"] as? String
            }

            playlists.append(
                LibraryPlaylist(id: browseId, title: title, subtitle: subtitle, thumbnailURL: thumbURL)
            )
        }

        return playlists
    }

    // MARK: parsing helpers

    private func parseHomeSection(from carousel: [String: Any]) -> HomeSection? {
        let header = (carousel["header"] as? [String: Any])?["musicCarouselShelfBasicHeaderRenderer"] as? [String: Any]
        let title = firstRunText(in: header?["title"]) ?? ""
        let strapline = firstRunText(in: header?["strapline"])
        let contents = (carousel["contents"] as? [[String: Any]]) ?? []
        var items: [HomeItem] = []

        for content in contents {
            if let twoRow = content["musicTwoRowItemRenderer"] as? [String: Any],
               let parsed = parseHomeItem(from: twoRow) {
                items.append(parsed)
                continue
            }
            if let responsive = content["musicResponsiveListItemRenderer"] as? [String: Any],
               let parsed = parseHomeItemFromResponsive(from: responsive) {
                items.append(parsed)
            }
        }

        guard !title.isEmpty else { return nil }
        return HomeSection(title: title, strapline: strapline, items: items)
    }

    private func parseHomeItem(from renderer: [String: Any]) -> HomeItem? {
        let title = firstRunText(in: renderer["title"]) ?? ""
        let subtitle = firstRunText(in: renderer["subtitle"])
        var thumb: String?
        if let thumbRenderer = renderer["thumbnailRenderer"] as? [String: Any],
           let musicThumb = thumbRenderer["musicThumbnailRenderer"] as? [String: Any],
           let container = musicThumb["thumbnail"] as? [String: Any],
           let thumbs = container["thumbnails"] as? [[String: Any]] {
            thumb = thumbs.last?["url"] as? String
        }

        guard let nav = renderer["navigationEndpoint"] as? [String: Any] else {
            return nil
        }

        if let watch = nav["watchEndpoint"] as? [String: Any],
           let videoId = watch["videoId"] as? String {
            return HomeItem(kind: .song, primaryId: videoId, title: title, subtitle: subtitle, thumbnailURL: thumb)
        }
        if let browse = nav["browseEndpoint"] as? [String: Any],
           let browseId = browse["browseId"] as? String {
            if browseId.hasPrefix("MPREb") {
                return HomeItem(kind: .album, primaryId: browseId, title: title, subtitle: subtitle, thumbnailURL: thumb)
            }
            if browseId.hasPrefix("UC") {
                return HomeItem(kind: .artist, primaryId: browseId, title: title, subtitle: subtitle, thumbnailURL: thumb)
            }
            return HomeItem(kind: .playlist, primaryId: browseId, title: title, subtitle: subtitle, thumbnailURL: thumb)
        }
        return nil
    }

    private func parseHomeItemFromResponsive(from renderer: [String: Any]) -> HomeItem? {
        let title = extractTitle(from: renderer)
        let subtitle = extractSubtitleParts(from: renderer).first
        let thumb = extractThumbnailURL(from: renderer)
        if let videoId = extractVideoId(from: renderer) {
            return HomeItem(kind: .song, primaryId: videoId, title: title, subtitle: subtitle, thumbnailURL: thumb)
        }
        return nil
    }

    private func firstRunText(in object: Any?) -> String? {
        guard let dict = object as? [String: Any] else { return nil }
        if let runs = dict["runs"] as? [[String: Any]] {
            let text = runs.compactMap { $0["text"] as? String }.joined()
            return text.isEmpty ? nil : text
        }
        if let simple = dict["simpleText"] as? String, !simple.isEmpty {
            return simple
        }
        return nil
    }
}