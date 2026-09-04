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
/// a JS runtime) to resolve, and proxies the bytes. Because it honours Range,
/// AVPlayer can stream and seek instead of downloading whole files up front.
@MainActor
final class StreamResolverService: ObservableObject {
    static let shared = StreamResolverService()

    @Published private(set) var baseURL: String = ""
    @Published private(set) var hasToken: Bool = false
    @Published private(set) var isReachable: Bool?
    @Published private(set) var isChecking: Bool = false
    @Published var lastErrorMessage: String?

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
            let (_, response) = try await session.data(from: healthURL)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            isReachable = (200 ..< 300).contains(status)
            lastErrorMessage = isReachable == true ? nil : "HTTP \(status)"
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
            streamURL: playbackURL
        )
    }

    /// A playback candidate for the resolver, or nil when unusable.
    func playbackOption(for videoId: String) async -> AudioStreamOption? {
        guard isConfigured else { return nil }
        do {
            let resolved = try await resolve(videoId: videoId)
            return AudioStreamOption(
                id: "resolver:\(videoId)",
                url: resolved.streamURL,
                sourceClientName: "RESOLVER",
                sourceClientVersion: "1",
                sourceUserAgent: nil,
                mimeType: resolved.mime,
                codec: resolved.ext,
                container: (resolved.ext ?? "audio").uppercased(),
                bitrate: resolved.bitrate,
                averageBitrate: resolved.bitrate,
                audioQuality: resolved.itag.map { "itag \($0)" },
                contentLength: resolved.filesize,
                itag: Int(resolved.itag ?? ""),
                isHLSManifest: false
            )
        } catch {
            lastErrorMessage = error.localizedDescription
            isReachable = false
            return nil
        }
    }
}
