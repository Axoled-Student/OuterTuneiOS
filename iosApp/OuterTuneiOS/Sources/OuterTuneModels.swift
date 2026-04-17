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
            thumbnailURL: thumbnailURL,
            durationText: durationText,
            source: .youtube(videoId: videoId)
        )
    }
}
