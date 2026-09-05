import Foundation

/// Re-ranks already-resolved candidate tracks with an LLM.
///
/// The model is deliberately never asked to *name* songs. It is handed a list
/// of candidates that already carry real YouTube Music videoIds and may only
/// return ids drawn from that list; anything else is discarded. That keeps the
/// useful part of an LLM (taste and sequencing judgement) while making it
/// impossible for a hallucinated title to reach the queue as an unplayable
/// entry.
///
/// Talks to an OpenAI-compatible `/v1/chat/completions` endpoint, so it works
/// with a self-hosted gateway as well as the first-party providers.
@MainActor
final class AIRankingService: ObservableObject {
    static let shared = AIRankingService()

    @Published var isEnabled: Bool = true
    @Published private(set) var endpoint: String = ""
    @Published var model: String = "gemini-3.8-flash-high"
    @Published private(set) var hasAPIKey: Bool = false
    @Published private(set) var lastFailureReason: String?

    private let keychainService = "com.dd3boh.outertune.ios.ai"
    private let apiKeyAccount = "apiKey"
    private let endpointKey = "ios.ai.endpoint.v1"
    private let modelKey = "ios.ai.model.v1"
    private let enabledKey = "ios.ai.enabled.v1"

    private var apiKey: String? {
        KeychainStore.get(service: keychainService, account: apiKeyAccount)
    }

    var isConfigured: Bool {
        isEnabled && hasAPIKey && !endpoint.isEmpty
    }

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        return URLSession(configuration: configuration)
    }()

    private init() {
        endpoint = UserDefaults.standard.string(forKey: endpointKey) ?? ""
        model = UserDefaults.standard.string(forKey: modelKey) ?? "gemini-3.8-flash-high"
        if UserDefaults.standard.object(forKey: enabledKey) != nil {
            isEnabled = UserDefaults.standard.bool(forKey: enabledKey)
        }
        hasAPIKey = apiKey != nil
    }

    // MARK: Configuration

    func configure(endpoint: String, apiKey: String?, model: String?) {
        let trimmedEndpoint = endpoint
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        self.endpoint = trimmedEndpoint
        UserDefaults.standard.set(trimmedEndpoint, forKey: endpointKey)

        if let model, !model.trimmingCharacters(in: .whitespaces).isEmpty {
            self.model = model.trimmingCharacters(in: .whitespaces)
            UserDefaults.standard.set(self.model, forKey: modelKey)
        }

        if let apiKey {
            let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
            KeychainStore.set(trimmed.isEmpty ? nil : trimmed,
                              service: keychainService, account: apiKeyAccount)
            hasAPIKey = !trimmed.isEmpty
        }
    }

    func setEnabled(_ value: Bool) {
        isEnabled = value
        UserDefaults.standard.set(value, forKey: enabledKey)
    }

    func clearCredentials() {
        KeychainStore.set(nil, service: keychainService, account: apiKeyAccount)
        hasAPIKey = false
    }

    // MARK: Ranking

    /// Returns candidates reordered by the model, or `nil` if the model could
    /// not be consulted. `nil` means "fall back to the scored blend" - playback
    /// must never stop because an LLM was unreachable.
    func rank(
        candidates: [AppTrack],
        nowPlaying: AppTrack?,
        taste: SpotifyTasteProfile,
        localFeedback: String?,
        limit: Int
    ) async -> [AppTrack]? {
        guard isConfigured, let apiKey else { return nil }
        guard candidates.count > 1 else { return candidates }

        // Keep the prompt bounded; the candidate pool is already ranked well
        // enough that the tail rarely matters.
        let pool = Array(candidates.prefix(60))
        let prompt = buildPrompt(pool: pool, nowPlaying: nowPlaying,
                                 taste: taste, localFeedback: localFeedback,
                                 limit: limit)

        do {
            let content = try await complete(prompt: prompt, apiKey: apiKey)
            guard let ids = Self.parseIDArray(from: content) else {
                lastFailureReason = "model did not return a JSON array"
                return nil
            }

            // Only ids that actually exist in the pool survive.
            var byId: [String: AppTrack] = [:]
            for track in pool {
                byId[Self.identifier(for: track)] = track
            }

            var ordered: [AppTrack] = []
            var used = Set<String>()
            for id in ids {
                guard let track = byId[id], used.insert(id).inserted else { continue }
                ordered.append(track)
            }

            guard !ordered.isEmpty else {
                lastFailureReason = "model returned no usable ids"
                return nil
            }

            // Backfill from the original ordering so the queue is never shorter
            // than asked for just because the model was terse.
            if ordered.count < limit {
                for track in pool where ordered.count < limit {
                    let id = Self.identifier(for: track)
                    if used.insert(id).inserted {
                        ordered.append(track)
                    }
                }
            }

            lastFailureReason = nil
            return Array(ordered.prefix(limit))
        } catch {
            lastFailureReason = error.localizedDescription
            return nil
        }
    }

    // MARK: Internals

    private static func identifier(for track: AppTrack) -> String {
        if case .youtube(let videoId) = track.source {
            return videoId
        }
        return track.stableId
    }

    private func buildPrompt(
        pool: [AppTrack],
        nowPlaying: AppTrack?,
        taste: SpotifyTasteProfile,
        localFeedback: String?,
        limit: Int
    ) -> String {
        let listing = pool.enumerated().map { index, track in
            "\(index + 1). [\(Self.identifier(for: track))] \(track.artist) - \(track.title)"
        }.joined(separator: "\n")

        var profileLines: [String] = []
        let artists = taste.weightedArtists.prefix(12).map(\.artist.name)
        if !artists.isEmpty {
            profileLines.append("Top artists: " + artists.joined(separator: ", "))
        }
        let tracks = taste.weightedTracks.prefix(10).map {
            "\($0.track.artistName) - \($0.track.name)"
        }
        if !tracks.isEmpty {
            profileLines.append("Frequently played: " + tracks.joined(separator: "; "))
        }
        let genres = taste.dominantGenres.prefix(8)
        if !genres.isEmpty {
            profileLines.append("Genres: " + genres.joined(separator: ", "))
        }
        if let localFeedback, !localFeedback.isEmpty {
            profileLines.append(localFeedback)
        }
        let profileText = profileLines.isEmpty
            ? "(no listening history available)"
            : profileLines.joined(separator: "\n")

        let nowPlayingText = nowPlaying.map { "\($0.artist) - \($0.title)" }
            ?? "(nothing playing)"

        return """
        You are the recommendation engine for a music player.

        The listener's taste profile:
        \(profileText)

        Now playing: \(nowPlayingText)

        Candidate tracks, one per line as `N. [id] artist - title`:
        \(listing)

        Choose the \(limit) best tracks to play next, ordered best first.
        Rules:
        - Only choose ids that appear in the candidate list above.
        - Never invent a track. Never repeat the now-playing track.
        - Never choose two uploads or language variants of the same song title.
        - Strongly avoid tracks or artists marked as frequently skipped.
        - Prefer artists already present in the listener profile. Unknown-artist
          discovery must be at most 20% of the result, never the opening track.
        - Avoid cover, karaoke, acoustic, sped-up, slowed, nightcore and remix
          uploads unless that exact version appears in the listener profile.
        - Choose no more than three tracks by one artist.
        - Prefer stylistically close tracks from artists the listener has
          completed or repeatedly listened to over unrelated novelty.
        - Favour a coherent listening flow: keep energy and genre consistent
          with what is playing while matching the listener's taste profile.
        - Prefer variety of artists over stacking one artist back to back.

        Respond with ONLY a JSON array of id strings and no other text.
        """
    }

    private func complete(prompt: String, apiKey: String) async throws -> String {
        guard let url = URL(string: endpoint + "/v1/chat/completions") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization")
        // Some gateways sit behind Cloudflare rules that reject non-browser
        // user agents outright, so present a conventional one.
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_3 like Mac OS X) AppleWebKit/605.1.15 "
                + "(KHTML, like Gecko) Version/18.3 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent")

        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.4,
            "max_tokens": 2000,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            let preview = String(data: data.prefix(200), encoding: .utf8) ?? ""
            throw NSError(domain: "AIRankingService", code: http.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HTTP \(http.statusCode) \(preview)"])
        }

        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw NSError(domain: "AIRankingService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "malformed completion"])
        }
        return content
    }

    /// Pulls a JSON string array out of a model reply, tolerating fenced blocks
    /// and surrounding prose.
    static func parseIDArray(from raw: String) -> [String]? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let fenceStart = text.range(of: "```") {
            let afterFence = text[fenceStart.upperBound...]
            if let fenceEnd = afterFence.range(of: "```") {
                text = String(afterFence[..<fenceEnd.lowerBound])
            } else {
                text = String(afterFence)
            }
            if text.hasPrefix("json") {
                text = String(text.dropFirst(4))
            }
        }

        guard
            let start = text.firstIndex(of: "["),
            let end = text.lastIndex(of: "]"),
            start < end
        else {
            return nil
        }

        let slice = String(text[start ... end])
        guard
            let data = slice.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else {
            return nil
        }

        let ids = parsed.compactMap { $0 as? String }
        return ids.isEmpty ? nil : ids
    }
}
