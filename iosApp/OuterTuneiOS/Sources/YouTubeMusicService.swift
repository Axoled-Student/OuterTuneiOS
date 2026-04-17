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

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "YouTube 回應無效"
        case .parsingFailed:
            return "YouTube 資料解析失敗"
        case .noPlayableStream:
            return "找不到可播放音訊串流"
        }
    }
}

final class YouTubeMusicService {
    static let shared = YouTubeMusicService()

    private let session: URLSession

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
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
        userAgent: String
    ) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw YouTubeMusicServiceError.invalidResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(clientName, forHTTPHeaderField: "X-YouTube-Client-Name")
        request.setValue(clientVersion, forHTTPHeaderField: "X-YouTube-Client-Version")
        request.setValue("1", forHTTPHeaderField: "X-Goog-Api-Format-Version")
        request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw YouTubeMusicServiceError.invalidResponse
        }
        return data
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
