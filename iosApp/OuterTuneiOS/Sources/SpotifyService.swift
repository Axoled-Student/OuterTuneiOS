import CryptoKit
import Foundation

#if os(iOS)
import AuthenticationServices
import UIKit
#endif

// MARK: - Models

struct SpotifyArtistSeed: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var genres: [String]
    var popularity: Int?
    var imageURL: String?
}

struct SpotifyTrackSeed: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var artistName: String
    var artistId: String?
    var imageURL: String?

    /// The query used to find the same recording on YouTube Music.
    var searchQuery: String { "\(artistName) \(name)" }
}

/// A snapshot of what the signed-in Spotify account actually listens to.
///
/// Spotify withdrew /v1/recommendations, /v1/audio-features and
/// /v1/artists/{id}/related-artists for apps registered after 2024-11-27, so
/// none of those can be used. Everything here comes from endpoints that are
/// still served, and together they *are* Spotify's affinity model output:
/// `/me/top/*` is ranked by Spotify's own listening algorithm.
struct SpotifyTasteProfile: Codable, Equatable {
    var topArtistsShort: [SpotifyArtistSeed] = []
    var topArtistsMedium: [SpotifyArtistSeed] = []
    var topArtistsLong: [SpotifyArtistSeed] = []
    var topTracksShort: [SpotifyTrackSeed] = []
    var topTracksMedium: [SpotifyTrackSeed] = []
    var recentlyPlayed: [SpotifyTrackSeed] = []
    var savedTracks: [SpotifyTrackSeed] = []
    var followedArtists: [SpotifyArtistSeed] = []
    var fetchedAt: Date = .distantPast

    static let empty = SpotifyTasteProfile()

    var isEmpty: Bool {
        topArtistsShort.isEmpty && topArtistsMedium.isEmpty && topArtistsLong.isEmpty
            && topTracksShort.isEmpty && topTracksMedium.isEmpty
            && recentlyPlayed.isEmpty && savedTracks.isEmpty && followedArtists.isEmpty
    }

    var isStale: Bool {
        Date().timeIntervalSince(fetchedAt) > 60 * 60 * 6
    }

    /// Artists ordered by how strongly they represent current taste.
    /// Short-term listening is weighted highest so the feed reacts to what the
    /// user is into now, with medium/long term and follows filling the tail.
    var weightedArtists: [(artist: SpotifyArtistSeed, weight: Double)] {
        var scores: [String: (SpotifyArtistSeed, Double)] = [:]

        func add(_ artists: [SpotifyArtistSeed], base: Double) {
            for (index, artist) in artists.enumerated() {
                // Rank decay: the first entry is worth roughly twice the tenth.
                let positional = base * (1.0 / (1.0 + Double(index) * 0.08))
                if let existing = scores[artist.id] {
                    scores[artist.id] = (existing.0, existing.1 + positional)
                } else {
                    scores[artist.id] = (artist, positional)
                }
            }
        }

        add(topArtistsShort, base: 1.0)
        add(topArtistsMedium, base: 0.65)
        add(topArtistsLong, base: 0.4)
        add(followedArtists, base: 0.3)

        return scores.values
            .sorted { $0.1 > $1.1 }
            .map { (artist: $0.0, weight: $0.1) }
    }

    /// Tracks ordered the same way, used both as queue material and as radio seeds.
    var weightedTracks: [(track: SpotifyTrackSeed, weight: Double)] {
        var scores: [String: (SpotifyTrackSeed, Double)] = [:]

        func add(_ tracks: [SpotifyTrackSeed], base: Double) {
            for (index, track) in tracks.enumerated() {
                let positional = base * (1.0 / (1.0 + Double(index) * 0.08))
                if let existing = scores[track.id] {
                    scores[track.id] = (existing.0, existing.1 + positional)
                } else {
                    scores[track.id] = (track, positional)
                }
            }
        }

        add(topTracksShort, base: 1.0)
        add(recentlyPlayed, base: 0.8)
        add(topTracksMedium, base: 0.6)
        add(savedTracks, base: 0.35)

        return scores.values
            .sorted { $0.1 > $1.1 }
            .map { (track: $0.0, weight: $0.1) }
    }

    var dominantGenres: [String] {
        var counts: [String: Double] = [:]
        for (artist, weight) in weightedArtists {
            for genre in artist.genres {
                counts[genre, default: 0] += weight
            }
        }
        return counts.sorted { $0.value > $1.value }.map(\.key)
    }
}

enum SpotifyServiceError: LocalizedError {
    case notConfigured
    case notAuthenticated
    case authorizationFailed(String)
    case httpError(status: Int, path: String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "尚未設定 Spotify Client ID"
        case .notAuthenticated:
            return "尚未登入 Spotify"
        case .authorizationFailed(let reason):
            return "Spotify 授權失敗：\(reason)"
        case .httpError(let status, let path):
            return "Spotify API \(path) 回應 HTTP \(status)"
        }
    }
}

// MARK: - Token storage

/// Refresh tokens are long-lived credentials, so they live in the keychain
/// rather than UserDefaults.
private enum SpotifyKeychain {
    private static let service = "com.dd3boh.outertune.ios.spotify"

    static func set(_ value: String?, for account: String) {
        KeychainStore.set(value, service: service, account: account)
    }

    static func get(_ account: String) -> String? {
        KeychainStore.get(service: service, account: account)
    }
}

// MARK: - Service

@MainActor
final class SpotifyService: NSObject, ObservableObject {
    static let shared = SpotifyService()

    /// The user brings their own Spotify app, so no client secret is ever
    /// embedded and the flow must be Authorization Code + PKCE.
    @Published private(set) var clientId: String = ""
    @Published private(set) var isAuthenticated: Bool = false
    @Published private(set) var displayName: String?
    @Published private(set) var product: String?
    @Published private(set) var profile: SpotifyTasteProfile = .empty
    @Published private(set) var isRefreshingProfile: Bool = false
    @Published var lastErrorMessage: String?

    /// Registered as a Redirect URI on the user's own Spotify app.
    static let redirectURI = "outertune-ios://spotify-callback"

    private static let scopes = [
        "user-read-private",
        "user-read-email",
        "user-top-read",
        "user-read-recently-played",
        "user-library-read",
        "user-follow-read",
        "playlist-read-private",
        "playlist-read-collaborative",
    ].joined(separator: " ")

    private let clientIdKey = "ios.spotify.clientId.v1"
    private let profileKey = "ios.spotify.tasteProfile.v1"
    private let profileImportFilename = "spotify-taste-profile.json"
    private let accessTokenAccount = "accessToken"
    private let refreshTokenAccount = "refreshToken"
    private let expiryKey = "ios.spotify.tokenExpiry.v1"

    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast
    private var pendingVerifier: String?

#if os(iOS)
    private var authSession: ASWebAuthenticationSession?
    private let authPresenter = SpotifyAuthPresenter()
#endif

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    private override init() {
        super.init()
        restore()
    }

    // MARK: Configuration

    func updateClientId(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        clientId = trimmed
        UserDefaults.standard.set(trimmed, forKey: clientIdKey)
    }

    private func restore() {
        clientId = UserDefaults.standard.string(forKey: clientIdKey) ?? ""
        accessToken = SpotifyKeychain.get(accessTokenAccount)
        refreshToken = SpotifyKeychain.get(refreshTokenAccount)
        expiresAt = Date(timeIntervalSince1970:
                            UserDefaults.standard.double(forKey: expiryKey))
        isAuthenticated = refreshToken != nil
        displayName = UserDefaults.standard.string(forKey: "ios.spotify.displayName.v1")
        product = UserDefaults.standard.string(forKey: "ios.spotify.product.v1")

        importTasteProfileSnapshotIfPresent()
        if let data = UserDefaults.standard.data(forKey: profileKey),
           let restored = try? JSONDecoder().decode(SpotifyTasteProfile.self, from: data) {
            profile = restored
        }
    }

    /// Import a credential-free Spotify taste snapshot placed in Documents.
    /// This is useful for a sideloaded build where OAuth has not been connected
    /// on-device yet. The snapshot contains artist/track affinity only—never an
    /// access or refresh token—and is removed immediately after a valid import.
    private func importTasteProfileSnapshotIfPresent() {
        guard let documents = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            return
        }
        let url = documents.appendingPathComponent(profileImportFilename)
        guard let data = try? Data(contentsOf: url),
              let imported = try? JSONDecoder().decode(
                  SpotifyTasteProfile.self,
                  from: data
              ),
              !imported.isEmpty else {
            return
        }
        profile = imported
        UserDefaults.standard.set(data, forKey: profileKey)
        try? FileManager.default.removeItem(at: url)
    }

    func logout() {
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        isAuthenticated = false
        displayName = nil
        product = nil
        profile = .empty
        SpotifyKeychain.set(nil, for: accessTokenAccount)
        SpotifyKeychain.set(nil, for: refreshTokenAccount)
        UserDefaults.standard.removeObject(forKey: expiryKey)
        UserDefaults.standard.removeObject(forKey: profileKey)
        UserDefaults.standard.removeObject(forKey: "ios.spotify.displayName.v1")
        UserDefaults.standard.removeObject(forKey: "ios.spotify.product.v1")
    }

    // MARK: Authorization (PKCE)

    func authorize() async {
        guard !clientId.isEmpty else {
            lastErrorMessage = SpotifyServiceError.notConfigured.localizedDescription
            return
        }

        let verifier = Self.randomURLSafeString(length: 64)
        let challenge = Self.codeChallenge(for: verifier)
        pendingVerifier = verifier

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
        ]

        guard let url = components.url else { return }

#if os(iOS)
        do {
            let callback = try await presentAuthSession(url: url)
            try await exchange(callbackURL: callback, verifier: verifier)
            await refreshAccountInfo()
            await refreshTasteProfile(force: true)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
#endif
    }

#if os(iOS)
    private func presentAuthSession(url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let scheme = URL(string: Self.redirectURI)?.scheme
            let session = ASWebAuthenticationSession(
                url: url,
                callbackURLScheme: scheme
            ) { callbackURL, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let callbackURL {
                    continuation.resume(returning: callbackURL)
                } else {
                    continuation.resume(
                        throwing: SpotifyServiceError.authorizationFailed("no callback"))
                }
            }
            session.presentationContextProvider = self.authPresenter
            // A private session avoids silently reusing a previously signed-in
            // Spotify account from Safari's shared cookie jar.
            session.prefersEphemeralWebBrowserSession = false
            self.authSession = session
            session.start()
        }
    }
#endif

    private func exchange(callbackURL: URL, verifier: String) async throws {
        let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?
            .queryItems ?? []
        if let error = items.first(where: { $0.name == "error" })?.value {
            throw SpotifyServiceError.authorizationFailed(error)
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else {
            throw SpotifyServiceError.authorizationFailed("missing code")
        }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "code_verifier", value: verifier),
        ]
        try await requestToken(formBody: body.percentEncodedQuery ?? "")
    }

    private func renewIfNeeded() async throws {
        if let accessToken, !accessToken.isEmpty, Date() < expiresAt.addingTimeInterval(-60) {
            return
        }
        guard let refreshToken else {
            throw SpotifyServiceError.notAuthenticated
        }

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: clientId),
        ]
        try await requestToken(formBody: body.percentEncodedQuery ?? "")
    }

    private func requestToken(formBody: String) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded",
                         forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let detail = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw SpotifyServiceError.authorizationFailed("HTTP \(status) \(detail)")
        }

        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["access_token"] as? String else {
            throw SpotifyServiceError.authorizationFailed("malformed token response")
        }

        accessToken = token
        SpotifyKeychain.set(token, for: accessTokenAccount)

        // A refresh grant does not always return a new refresh token; keep the
        // existing one when it is omitted.
        if let newRefresh = object["refresh_token"] as? String {
            refreshToken = newRefresh
            SpotifyKeychain.set(newRefresh, for: refreshTokenAccount)
        }

        let lifetime = (object["expires_in"] as? Double) ?? 3600
        expiresAt = Date().addingTimeInterval(lifetime)
        UserDefaults.standard.set(expiresAt.timeIntervalSince1970, forKey: expiryKey)
        isAuthenticated = refreshToken != nil
    }

    // MARK: Requests

    private func get(_ path: String, query: [String: String] = [:]) async throws -> [String: Any] {
        try await renewIfNeeded()
        guard let accessToken else { throw SpotifyServiceError.notAuthenticated }

        var components = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { return [:] }

        var request = URLRequest(url: url)
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return [:] }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw SpotifyServiceError.httpError(status: http.statusCode, path: path)
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    func refreshAccountInfo() async {
        do {
            let me = try await get("/me")
            displayName = me["display_name"] as? String
            product = me["product"] as? String
            UserDefaults.standard.set(displayName, forKey: "ios.spotify.displayName.v1")
            UserDefaults.standard.set(product, forKey: "ios.spotify.product.v1")
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: Taste profile

    func refreshTasteProfile(force: Bool = false) async {
        guard isAuthenticated else { return }
        guard force || profile.isEmpty || profile.isStale else { return }
        guard !isRefreshingProfile else { return }

        isRefreshingProfile = true
        defer { isRefreshingProfile = false }

        var next = SpotifyTasteProfile()

        // Each of these is independently optional: a single failure (a revoked
        // scope, a rate limit) must not wipe out the whole profile.
        next.topArtistsShort = await artists("/me/top/artists",
                                             query: ["limit": "30", "time_range": "short_term"])
        next.topArtistsMedium = await artists("/me/top/artists",
                                              query: ["limit": "30", "time_range": "medium_term"])
        next.topArtistsLong = await artists("/me/top/artists",
                                            query: ["limit": "30", "time_range": "long_term"])
        next.topTracksShort = await tracks("/me/top/tracks",
                                           query: ["limit": "40", "time_range": "short_term"])
        next.topTracksMedium = await tracks("/me/top/tracks",
                                            query: ["limit": "40", "time_range": "medium_term"])
        next.recentlyPlayed = await tracks("/me/player/recently-played",
                                           query: ["limit": "40"], itemsAreWrapped: true)
        next.savedTracks = await tracks("/me/tracks",
                                        query: ["limit": "40"], itemsAreWrapped: true)
        next.followedArtists = await followed()
        next.fetchedAt = Date()

        guard !next.isEmpty else { return }

        profile = next
        if let data = try? JSONEncoder().encode(next) {
            UserDefaults.standard.set(data, forKey: profileKey)
        }
    }

    private func artists(_ path: String, query: [String: String]) async -> [SpotifyArtistSeed] {
        guard let body = try? await get(path, query: query) else { return [] }
        let items = (body["items"] as? [[String: Any]]) ?? []
        return items.compactMap(Self.parseArtist)
    }

    private func followed() async -> [SpotifyArtistSeed] {
        guard let body = try? await get("/me/following",
                                        query: ["type": "artist", "limit": "50"]) else {
            return []
        }
        let container = (body["artists"] as? [String: Any]) ?? [:]
        let items = (container["items"] as? [[String: Any]]) ?? []
        return items.compactMap(Self.parseArtist)
    }

    /// `itemsAreWrapped` covers /me/tracks and /me/player/recently-played, whose
    /// items nest the actual track under a "track" key.
    private func tracks(_ path: String,
                        query: [String: String],
                        itemsAreWrapped: Bool = false) async -> [SpotifyTrackSeed] {
        guard let body = try? await get(path, query: query) else { return [] }
        let items = (body["items"] as? [[String: Any]]) ?? []
        return items.compactMap { item in
            let raw = itemsAreWrapped ? (item["track"] as? [String: Any]) : item
            guard let raw else { return nil }
            return Self.parseTrack(raw)
        }
    }

    private static func parseArtist(_ raw: [String: Any]) -> SpotifyArtistSeed? {
        guard let id = raw["id"] as? String, let name = raw["name"] as? String else {
            return nil
        }
        let images = (raw["images"] as? [[String: Any]]) ?? []
        return SpotifyArtistSeed(
            id: id,
            name: name,
            genres: (raw["genres"] as? [String]) ?? [],
            popularity: raw["popularity"] as? Int,
            imageURL: images.first?["url"] as? String
        )
    }

    private static func parseTrack(_ raw: [String: Any]) -> SpotifyTrackSeed? {
        guard let id = raw["id"] as? String, let name = raw["name"] as? String else {
            return nil
        }
        let artists = (raw["artists"] as? [[String: Any]]) ?? []
        let album = (raw["album"] as? [String: Any]) ?? [:]
        let images = (album["images"] as? [[String: Any]]) ?? []
        return SpotifyTrackSeed(
            id: id,
            name: name,
            artistName: (artists.first?["name"] as? String) ?? "Unknown",
            artistId: artists.first?["id"] as? String,
            imageURL: images.first?["url"] as? String
        )
    }

    // MARK: PKCE helpers

    private static func randomURLSafeString(length: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: length)
        _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        return base64URL(Data(bytes))
    }

    private static func codeChallenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

#if os(iOS)
/// The presentation anchor must be readable from whatever context
/// ASWebAuthenticationSession asks from. Keeping the conformance on a plain
/// NSObject (rather than the @MainActor service) avoids needing
/// `MainActor.assumeIsolated`, which is iOS 17+ while this app targets iOS 15.
final class SpotifyAuthPresenter: NSObject, ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        let window = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first { $0.isKeyWindow }
        return window ?? ASPresentationAnchor()
    }
}
#endif
