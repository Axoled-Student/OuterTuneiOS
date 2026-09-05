import Foundation

enum TrackSource: Codable, Equatable {
    case directURL(String)
    case youtube(videoId: String)
    case localFile(path: String)
}

enum AudioQualityPreference: String, Codable, CaseIterable, Identifiable {
    case auto
    case high
    case medium
    case low

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:
            return "自動"
        case .high:
            return "高"
        case .medium:
            return "中"
        case .low:
            return "低"
        }
    }

    var description: String {
        switch self {
        case .auto:
            return "系統自動選擇穩定且高相容的音訊來源"
        case .high:
            return "優先選擇較高位元率"
        case .medium:
            return "優先選擇約 128 kbps"
        case .low:
            return "優先選擇較低位元率以節省流量"
        }
    }
}

enum YouTubeMusicSearchScope: String, CaseIterable, Identifiable, Equatable {
    case songs
    case videos

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .songs:
            return "音樂"
        case .videos:
            return "音樂影片"
        }
    }

    /// Official WEB_REMIX search chips used by YouTube Music.
    var apiParams: String {
        switch self {
        case .songs:
            return "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        case .videos:
            return "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
        }
    }
}

struct AppTrack: Codable, Identifiable, Equatable {
    var id: String
    var canonicalId: String? = nil
    var title: String
    var artist: String
    var thumbnailURL: String?
    var durationText: String?
    var source: TrackSource

    var stableId: String {
        if let canonicalId, !canonicalId.isEmpty {
            return canonicalId
        }

        switch source {
        case .youtube(let videoId):
            return "yt:\(videoId)"
        case .directURL(let url):
            return "url:\(url)"
        case .localFile(let path):
            return "file:\(path)"
        }
    }

    /// YouTube always exposes a deterministic video thumbnail even when a
    /// particular InnerTube renderer omits its artwork object. This also heals
    /// queue rows persisted by older builds with a nil thumbnail URL.
    var displayThumbnailURL: String? {
        if let thumbnailURL,
           !thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return thumbnailURL
        }
        if case .youtube(let videoId) = source, !videoId.isEmpty {
            return "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg"
        }
        return nil
    }

    /// Alternate uploads and music-video variants often have different
    /// videoIds for the same recording. Auto-queue de-duplicates on this
    /// normalized title as well as on stableId so the user does not get two
    /// copies of the same song in one batch.
    var recommendationIdentity: String {
        let normalized = Self.normalizedRecommendationTitle(title)
        return normalized.isEmpty ? stableId : normalized
    }

    static func normalizedRecommendationTitle(_ title: String) -> String {
        let baseTitle = title.replacingOccurrences(
            of: #"\s*[\(（\[【].*$"#,
            with: "",
            options: .regularExpression
        )
        let folded = baseTitle.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        let normalized = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return normalized
    }
}

struct YouTubeSearchSong: Identifiable, Equatable {
    var id: String { videoId }
    var videoId: String
    var title: String
    var artist: String
    var thumbnailURL: String?
    var durationText: String?

    func asTrack() -> AppTrack {
        AppTrack(
            id: UUID().uuidString,
            canonicalId: "yt:\(videoId)",
            title: title,
            artist: artist,
            thumbnailURL: thumbnailURL
                ?? "https://i.ytimg.com/vi/\(videoId)/hqdefault.jpg",
            durationText: durationText,
            source: .youtube(videoId: videoId)
        )
    }
}
