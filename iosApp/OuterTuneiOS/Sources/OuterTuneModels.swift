import Foundation

enum TrackSource: Codable, Equatable {
    case directURL(String)
    case youtube(videoId: String)
    case localFile(path: String)
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
