import Foundation
import CommonCrypto

struct AudioStreamOption: Identifiable, Equatable {
    let id: String
    let url: URL
    let sourceClientName: String
    let sourceClientVersion: String
    let sourceUserAgent: String?
    let mimeType: String?
    let codec: String?
    let container: String
    let bitrate: Int?
    let averageBitrate: Int?
    let audioQuality: String?
    let contentLength: Int64?
    let itag: Int?
    let isHLSManifest: Bool
    /// Raw YouTube DASH needs client-side remuxing. Resolver 1.1 serves a
    /// cached, fast-start M4A and can be handed directly to AVPlayer.
    let requiresRemux: Bool
    /// Authoritative media duration when supplied by the companion resolver.
    let duration: Double?

    init(
        id: String,
        url: URL,
        sourceClientName: String,
        sourceClientVersion: String,
        sourceUserAgent: String?,
        mimeType: String?,
        codec: String?,
        container: String,
        bitrate: Int?,
        averageBitrate: Int?,
        audioQuality: String?,
        contentLength: Int64?,
        itag: Int?,
        isHLSManifest: Bool,
        requiresRemux: Bool = true,
        duration: Double? = nil
    ) {
        self.id = id
        self.url = url
        self.sourceClientName = sourceClientName
        self.sourceClientVersion = sourceClientVersion
        self.sourceUserAgent = sourceUserAgent
        self.mimeType = mimeType
        self.codec = codec
        self.container = container
        self.bitrate = bitrate
        self.averageBitrate = averageBitrate
        self.audioQuality = audioQuality
        self.contentLength = contentLength
        self.itag = itag
        self.isHLSManifest = isHLSManifest
        self.requiresRemux = requiresRemux
        self.duration = duration
    }

    /// itag 141 is 256kbps AAC and itag 774 is high-rate Opus. YouTube only
    /// offers either to a session carrying a Music Premium account, so their
    /// presence is a reliable signal that premium audio was unlocked.
    static let premiumITags: Set<Int> = [141, 774]

    var isPremiumFormat: Bool {
        guard let itag else { return false }
        return Self.premiumITags.contains(itag)
    }

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
    case httpError(statusCode: Int, endpoint: String, bodyPreview: String)
    case parsingFailed
    case noPlayableStream
    case notLoggedIn
    case incompleteStream(expected: Int64, actual: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "YouTube 回應無效"
        case .httpError(let code, let endpoint, let body):
            let ep = endpoint.components(separatedBy: "?").first?.components(separatedBy: "/").last ?? endpoint
            return "HTTP \(code) (\(ep)): \(body)"
        case .parsingFailed:
            return "YouTube 資料解析失敗"
        case .noPlayableStream:
            return "找不到可播放音訊串流"
        case .notLoggedIn:
            return "尚未登入 YouTube Music"
        case .incompleteStream(let expected, let actual):
            return "音訊下載不完整（\(actual)/\(expected) bytes）"
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

    /// 登入請求專用 session（使用 HTTPCookieStorage.shared，帶 cookies）
    private let session: URLSession
    /// 匿名請求專用 session（ephemeral，完全不帶 cookies）
    /// 用於 player API 的 IOS/ANDROID_VR profile，避免 cookie 洩漏導致 stream URL 綁定認證
    private let anonymousSession: URLSession

    /// 提供帳號登入後的 cookie / visitorData / dataSyncId；可為 nil（未登入）。
    /// 這個 closure 會在每次建立 request 前讀取，因此 AccountStore 更新後會自動生效。
    var authProvider: (() -> YouTubeAuthContext?)?

    private init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        // 使用系統的 HTTPCookieStorage.shared（與 WKWebView default data store 共用）
        // 認證請求前會將 cookie 注入到 shared storage，URLSession 自動帶上
        self.session = URLSession(configuration: configuration)

        // 匿名 session：ephemeral 保證完全隔離，不與 HTTPCookieStorage.shared 共用
        let anonConfig = URLSessionConfiguration.ephemeral
        anonConfig.timeoutIntervalForRequest = 20
        anonConfig.timeoutIntervalForResource = 30
        anonConfig.httpCookieAcceptPolicy = .never
        anonConfig.httpShouldSetCookies = false
        anonConfig.httpCookieStorage = nil
        self.anonymousSession = URLSession(configuration: anonConfig)
    }

    /// 將 cookie 字串解析後注入到 HTTPCookieStorage.shared，讓 URLSession 自動帶上
    private func injectCookies(_ cookieString: String, for url: URL) {
        let storage = HTTPCookieStorage.shared
        // 清除既有的 youtube.com cookies 以避免衝突
        if let existing = storage.cookies(for: url) {
            for c in existing { storage.deleteCookie(c) }
        }
        let pairs = cookieString.split(separator: ";")
        for pair in pairs {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let name = String(parts[0])
            let value = String(parts[1])
            let properties: [HTTPCookiePropertyKey: Any] = [
                .name: name,
                .value: value,
                .domain: ".youtube.com",
                .path: "/",
                .secure: "TRUE",
            ]
            if let cookie = HTTPCookie(properties: properties) {
                storage.setCookie(cookie)
            }
        }
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

        let isLoggedIn = authProvider?()?.cookie.isEmpty == false

        // Order matters. Premium formats (itag 141 / 774) are only ever offered
        // to WEB_REMIX when it carries the account cookie, so a signed-in user
        // must ask that client first. Asking IOS first - as this did - meant a
        // Premium subscriber was still served the free 128kbps ladder, because
        // IOS answered successfully and nothing ever consulted WEB_REMIX.
        // Anonymous sessions keep the old order, where IOS is the most reliable.
        let orderedProfiles: [PlayerClientProfile]
        if isLoggedIn {
            orderedProfiles = playerClientProfiles.filter { $0.useLogin }
                + playerClientProfiles.filter { !$0.useLogin }
        } else {
            orderedProfiles = playerClientProfiles
        }

        print("[YTService] resolveAudioStreams: videoId=\(videoId), isLoggedIn=\(isLoggedIn), profiles=\(orderedProfiles.map(\.clientName))")

        for profile in orderedProfiles {
            // WEB_REMIX 需要登入 + PoToken 才能取得串流，未登入時跳過
            if profile.useLogin && !isLoggedIn {
                print("[YTService] skipping \(profile.clientName) (needs login)")
                continue
            }

            do {
                let streams = try await fetchPlayableStreams(videoId: videoId, profile: profile, allowWebM: false)
                print("[YTService] \(profile.clientName) → \(streams.count) streams (HLS=\(streams.filter(\.isHLSManifest).count), adaptive=\(streams.filter { !$0.isHLSManifest }.count))")
                orderedStreams.append(contentsOf: streams)
            } catch {
                // 單一 profile 失敗不應阻斷其他 profile
                print("[YTService] \(profile.clientName) FAILED for \(videoId): \(error.localizedDescription)")
                continue
            }
        }

        let deduplicated = deduplicate(streams: orderedStreams)
        print("[YTService] resolveAudioStreams: total=\(orderedStreams.count), deduplicated=\(deduplicated.count)")
        if deduplicated.isEmpty {
            throw YouTubeMusicServiceError.noPlayableStream
        }

        return Array(deduplicated.prefix(max(limit, 1)))
    }

    private func fetchPlayableStreams(videoId: String, profile: PlayerClientProfile, allowWebM: Bool) async throws -> [AudioStreamOption] {
        var payload: [String: Any] = [
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

        // 帶登入的 client 需要注入 visitorData 與 dataSyncId
        if profile.useLogin, let auth = authProvider?() {
            if var context = payload["context"] as? [String: Any],
               var client = context["client"] as? [String: Any] {
                if !auth.visitorData.isEmpty {
                    client["visitorData"] = auth.visitorData
                }
                context["client"] = client
                if profile.loginSupported, !auth.dataSyncId.isEmpty {
                    var user = context["user"] as? [String: Any] ?? [:]
                    user["onBehalfOfUser"] = auth.dataSyncId
                    context["user"] = user
                }
                payload["context"] = context
            }
        }

        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/player",
            payload: payload,
            clientName: profile.clientId,
            clientVersion: profile.clientVersion,
            userAgent: profile.userAgent,
            useLogin: profile.useLogin,
            loginSupported: profile.loginSupported
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        // 檢查 playabilityStatus，只有 OK 才繼續解析串流
        if let playabilityStatus = object["playabilityStatus"] as? [String: Any] {
            let status = playabilityStatus["status"] as? String ?? "UNKNOWN"
            if status != "OK" {
                let reason = playabilityStatus["reason"] as? String
                print("[YouTubeMusicService] [\(profile.clientName)] playabilityStatus=\(status)\(reason.map { ", reason=\($0)" } ?? "")")
                return []
            }
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
                    sourceUserAgent: profile.userAgent,
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
        var payload: [String: Any] = [
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

        if profile.useLogin, let auth = authProvider?() {
            if var context = payload["context"] as? [String: Any],
               var client = context["client"] as? [String: Any] {
                if !auth.visitorData.isEmpty {
                    client["visitorData"] = auth.visitorData
                }
                context["client"] = client
                if profile.loginSupported, !auth.dataSyncId.isEmpty {
                    var user = context["user"] as? [String: Any] ?? [:]
                    user["onBehalfOfUser"] = auth.dataSyncId
                    context["user"] = user
                }
                payload["context"] = context
            }
        }

        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/player",
            payload: payload,
            clientName: profile.clientId,
            clientVersion: profile.clientVersion,
            userAgent: profile.userAgent,
            useLogin: profile.useLogin,
            loginSupported: profile.loginSupported
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
        // YouTube Music API 要求所有請求帶上 prettyPrint=false
        var components = URLComponents(string: endpoint)!
        let existing = components.queryItems ?? []
        if !existing.contains(where: { $0.name == "prettyPrint" }) {
            components.queryItems = existing + [URLQueryItem(name: "prettyPrint", value: "false")]
        }
        guard let url = components.url else {
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
                    // 保留 baseContext 中的 lockedSafetyMode，只追加 onBehalfOfUser
                    var user = context["user"] as? [String: Any] ?? [:]
                    user["onBehalfOfUser"] = auth.dataSyncId
                    context["user"] = user
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
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        // Origin/Referer 只有 web client 才需要
        // IOS/ANDROID_VR 是 mobile app，不應帶 web headers，否則 YouTube 可能回傳受限的 stream URL
        let isWebClient = userAgent.hasPrefix("Mozilla")
        if isWebClient {
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "Origin")
            request.setValue("https://music.youtube.com", forHTTPHeaderField: "X-Origin")
            request.setValue("https://music.youtube.com/", forHTTPHeaderField: "Referer")
        }

        if let auth, useLogin, loginSupported, !auth.cookie.isEmpty {
            // 注入 cookie 到 session 的 cookieStorage，讓 URLSession 自動帶上 Cookie header
            injectCookies(auth.cookie, for: url)
            request.httpShouldHandleCookies = true
            if let sapisid = auth.sapisid {
                let timestamp = Int(Date().timeIntervalSince1970)
                let hash = sha1("\(timestamp) \(sapisid) https://music.youtube.com")
                request.setValue("SAPISIDHASH \(timestamp)_\(hash)", forHTTPHeaderField: "Authorization")
            }
        } else {
            request.httpShouldHandleCookies = false
            // 顯式清空 Cookie header，防止 iOS 系統層洩漏
            request.setValue("", forHTTPHeaderField: "Cookie")
            // 如果是 player API，同時清除 HTTPCookieStorage.shared 中 youtube.com 的 cookies
            if endpoint.contains("/player") {
                let ytDomains = ["music.youtube.com", ".youtube.com", "www.youtube.com"]
                for domain in ytDomains {
                    if let domainURL = URL(string: "https://\(domain)"),
                       let cookies = HTTPCookieStorage.shared.cookies(for: domainURL) {
                        print("[YTService] clearing \(cookies.count) shared cookies for \(domain) before player API")
                        for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
                    }
                }
            }
        }

        // 選擇 session：登入請求用 session（帶 cookies），匿名請求用 anonymousSession（完全無 cookies）
        let activeSession = (useLogin && auth != nil) ? session : anonymousSession
        let sessionLabel = (useLogin && auth != nil) ? "auth" : "anon"
        let sharedCookieCount = HTTPCookieStorage.shared.cookies(for: url)?.count ?? 0
        print("[YTService] requestJSON: \(endpoint.split(separator: "/").last ?? "?") via \(sessionLabel) session, sharedCookies=\(sharedCookieCount), useLogin=\(useLogin), hasAuth=\(auth != nil)")

        let (data, response) = try await activeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            print("[YTService] requestJSON: response is NOT HTTPURLResponse for \(endpoint)")
            throw YouTubeMusicServiceError.invalidResponse
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? "(binary)"
            print("[YTService] requestJSON: HTTP \(http.statusCode) for \(endpoint), body=\(bodyPreview.prefix(200))")
            throw YouTubeMusicServiceError.httpError(
                statusCode: http.statusCode,
                endpoint: endpoint,
                bodyPreview: String(bodyPreview.prefix(200))
            )
        }
        return data
    }

    private func sha1(_ input: String) -> String {
        let data = Data(input.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { bytes in
            _ = CC_SHA1(bytes.baseAddress, CC_LONG(data.count), &digest)
        }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func extractVideoId(from renderer: [String: Any]) -> String? {
        if
            let navigation = renderer["navigationEndpoint"] as? [String: Any],
            let watch = navigation["watchEndpoint"] as? [String: Any],
            let videoId = watch["videoId"] as? String,
            !videoId.isEmpty
        {
            return videoId
        }

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

        // Quick-pick rows sometimes put the playable endpoint only on a text
        // run instead of playlistItemData or the artwork overlay.
        if let columns = renderer["flexColumns"] as? [[String: Any]] {
            for column in columns {
                guard
                    let flex = column["musicResponsiveListItemFlexColumnRenderer"] as? [String: Any],
                    let text = flex["text"] as? [String: Any],
                    let runs = text["runs"] as? [[String: Any]]
                else { continue }

                for run in runs {
                    if let navigation = run["navigationEndpoint"] as? [String: Any],
                       let watch = navigation["watchEndpoint"] as? [String: Any],
                       let videoId = watch["videoId"] as? String,
                       !videoId.isEmpty {
                        return videoId
                    }
                }
            }
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

        // A pre-cleared signature is rare but does occur, and can be used as-is.
        if let signature = values["sig"] ?? values["signature"] {
            var queryItems = finalComponents.queryItems ?? []
            queryItems.append(URLQueryItem(name: values["sp"] ?? "signature", value: signature))
            finalComponents.queryItems = queryItems
            return finalComponents.url
        }

        // Otherwise the format carries `s=`, an obfuscated signature that only
        // YouTube's player JS can descramble. Returning the URL without it
        // yields a link googlevideo answers with HTTP 403 every single time,
        // which is worse than having no candidate at all: it displaces working
        // streams and surfaces as a playback failure. Drop it instead, so the
        // resolver falls through to a client that hands out direct URLs.
        if values["s"] != nil {
            print("[YTService] skipping itag \(format["itag"] as? Int ?? -1): "
                  + "ciphered signature cannot be descrambled")
            return nil
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
            sourceUserAgent: profile.userAgent,
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

        // AVPlayer 不支援 Opus codec（即使在 MP4 容器中也不行）
        if mimeType.contains("opus") {
            return false
        }
        // 也排除 vorbis
        if mimeType.contains("vorbis") {
            return false
        }

        // Restrict to codecs/container families that are known to decode reliably in iOS AVPlayer.
        // 只接受 AAC (mp4a)、MP3、HE-AAC 等
        return mimeType.contains("mp4a") ||
            mimeType.contains("audio/mp4") ||
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

        // Premium formats outrank every codec preference below: a 256kbps AAC
        // stream is the whole point of signing in with Premium.
        if let itag = format["itag"] as? Int,
           AudioStreamOption.premiumITags.contains(itag) {
            score += 10_000
        }

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
    let loginSupported: Bool
    let useLogin: Bool
}

private let playerClientProfiles: [PlayerClientProfile] = [
    // IOS 最穩定，支援 HLS + AAC/M4A，優先使用
    PlayerClientProfile(
        clientName: "IOS",
        clientVersion: "20.10.4",
        clientId: "5",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        osVersion: "18.3.2.22D82",
        loginSupported: false,
        useLogin: false
    ),
    // ANDROID_VR 不需登入，作為備援（部分影片可能觸發 bot detection）
    PlayerClientProfile(
        clientName: "ANDROID_VR",
        clientVersion: "1.61.48",
        clientId: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; en_US; Oculus Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)",
        osVersion: "12",
        loginSupported: false,
        useLogin: false
    ),
    // WEB_REMIX 需要登入 + PoToken，未登入時自動跳過（resolveAudioStreams 控制）
    PlayerClientProfile(
        clientName: "WEB_REMIX",
        clientVersion: "1.20250310.01.00",
        clientId: "67",
        userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0",
        osVersion: "10.0",
        loginSupported: true,
        useLogin: true
    ),
]
// MARK: - Account / Home / Library APIs

extension YouTubeMusicService {
    private var webRemixClientName: String { "WEB_REMIX" }
    private var webRemixClientVersion: String { "1.20250310.01.00" }
    private var webRemixClientId: String { "67" }
    private var webRemixUserAgent: String { "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0" }

    private func baseContext() -> [String: Any] {
        [
            "context": [
                "client": [
                    "clientName": webRemixClientName,
                    "clientVersion": webRemixClientVersion,
                    "hl": "zh-TW",
                    "gl": "TW"
                ],
                "request": [
                    "internalExperimentFlags": [] as [Any],
                    "useSsl": true
                ],
                "user": [
                    "lockedSafetyMode": false
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
        // 先嘗試帶 cookie 取得個人化結果；若失敗則 fallback 到匿名取得公共內容
        let data: Data
        do {
            var payload = baseContext()
            payload["browseId"] = "FEmusic_home"
            data = try await requestJSON(
                endpoint: "https://music.youtube.com/youtubei/v1/browse",
                payload: payload,
                clientName: webRemixClientId,
                clientVersion: webRemixClientVersion,
                userAgent: webRemixUserAgent,
                useLogin: true
            )
        } catch {
            // 登入態請求失敗 → 匿名 fallback
            var payload = baseContext()
            payload["browseId"] = "FEmusic_home"
            data = try await requestJSON(
                endpoint: "https://music.youtube.com/youtubei/v1/browse",
                payload: payload,
                clientName: webRemixClientId,
                clientVersion: webRemixClientVersion,
                userAgent: webRemixUserAgent,
                useLogin: false
            )
        }

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

    /// Load the playable rows for a YouTube Music playlist, album, mix, or
    /// artist shelf. Continuations are followed so large playlists are not
    /// silently truncated at the first 100 items.
    func fetchBrowseSongs(browseId: String, maxTracks: Int = 500) async throws -> [YouTubeSearchSong] {
        let normalizedId = browseId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedId.isEmpty else {
            throw YouTubeMusicServiceError.invalidResponse
        }

        var payload = baseContext()
        payload["browseId"] = normalizedId
        var seenVideoIds = Set<String>()
        var seenContinuations = Set<String>()
        var songs: [YouTubeSearchSong] = []

        for _ in 0..<10 {
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

            let renderers = collectDictionaries(
                forKey: "musicResponsiveListItemRenderer",
                in: object
            )
            for renderer in renderers {
                guard let videoId = extractVideoId(from: renderer),
                      seenVideoIds.insert(videoId).inserted else { continue }

                let title = extractTitle(from: renderer)
                guard !title.isEmpty else { continue }
                let subtitleParts = extractSubtitleParts(from: renderer)
                songs.append(
                    YouTubeSearchSong(
                        videoId: videoId,
                        title: title,
                        artist: extractArtistName(from: renderer, subtitleParts: subtitleParts),
                        thumbnailURL: extractThumbnailURL(from: renderer),
                        durationText: subtitleParts.reversed().first(where: { isDurationToken($0) })
                    )
                )
                if songs.count >= maxTracks { return songs }
            }

            let continuation = collectDictionaries(
                forKey: "continuationItemRenderer",
                in: object
            ).compactMap { renderer -> String? in
                let endpoint = renderer["continuationEndpoint"] as? [String: Any]
                let command = endpoint?["continuationCommand"] as? [String: Any]
                return command?["token"] as? String
            }.first { !$0.isEmpty && !seenContinuations.contains($0) }

            guard let continuation else { break }
            seenContinuations.insert(continuation)
            payload = baseContext()
            payload["continuation"] = continuation
        }

        return songs
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
        if let watch = nav["watchEndpoint"] as? [String: Any],
           let playlistId = watch["playlistId"] as? String,
           !playlistId.isEmpty {
            let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
            return HomeItem(kind: .playlist, primaryId: browseId, title: title, subtitle: subtitle, thumbnailURL: thumb)
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

// MARK: - Radio / auto-queue

extension YouTubeMusicService {
    /// YouTube Music's own radio continuation for a track.
    ///
    /// `RDAMVM<videoId>` is the "start radio from this song" playlist the web
    /// player uses. It works without login and returns roughly 50 ordered
    /// tracks, which makes it the reliable backbone of the auto-queue: every
    /// entry already has a playable videoId, so nothing downstream has to
    /// guess or resolve a title back into an id.
    func fetchRadioQueue(videoId: String, limit: Int = 40) async throws -> [YouTubeSearchSong] {
        // requestJSON expects callers to supply the InnerTube context. The old
        // payload omitted it, so /next returned no usable radio rows in-app
        // even though the same endpoint produced a full queue in live tests.
        var payload = baseContext()
        payload["videoId"] = videoId
        payload["playlistId"] = "RDAMVM" + videoId
        payload["isAudioOnly"] = true
        payload["params"] = "wAEB"

        let data = try await requestJSON(
            endpoint: "https://music.youtube.com/youtubei/v1/next",
            payload: payload,
            clientName: webRemixClientId,
            clientVersion: webRemixClientVersion,
            userAgent: webRemixUserAgent,
            useLogin: true,
            loginSupported: true
        )

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }

        let renderers = collectDictionaries(forKey: "playlistPanelVideoRenderer", in: object)
        var seen = Set<String>()
        var songs: [YouTubeSearchSong] = []

        for renderer in renderers {
            guard let id = renderer["videoId"] as? String, !id.isEmpty else { continue }
            guard id != videoId, seen.insert(id).inserted else { continue }

            var title = extractTitle(from: renderer)
            if title.isEmpty {
                title = firstText(in: renderer["title"]) ?? ""
            }
            guard !title.isEmpty else { continue }

            let byline = firstText(in: renderer["longBylineText"])
                ?? firstText(in: renderer["shortBylineText"])

            songs.append(
                YouTubeSearchSong(
                    videoId: id,
                    title: title,
                    artist: byline ?? "Unknown",
                    thumbnailURL: extractThumbnailURL(from: renderer),
                    durationText: firstText(in: renderer["lengthText"])
                )
            )

            if songs.count >= limit { break }
        }

        return songs
    }

    /// First `text` run inside a `{ runs: [...] }` / `{ simpleText: }` node.
    private func firstText(in node: Any?) -> String? {
        guard let dict = node as? [String: Any] else { return nil }
        if let simple = dict["simpleText"] as? String, !simple.isEmpty {
            return simple
        }
        guard let runs = dict["runs"] as? [[String: Any]] else { return nil }
        let joined = runs.compactMap { $0["text"] as? String }.joined()
        return joined.isEmpty ? nil : joined
    }
}
