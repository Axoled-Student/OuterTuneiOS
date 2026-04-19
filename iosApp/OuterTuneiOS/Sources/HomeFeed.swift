import Foundation

enum HomeItemKind: String, Codable {
    case song
    case album
    case playlist
    case artist
    case video
}

struct HomeItem: Identifiable, Equatable {
    var id: String { "\(kind.rawValue):\(primaryId)" }
    var kind: HomeItemKind
    var primaryId: String          // videoId / browseId / playlistId / channelId
    var title: String
    var subtitle: String?
    var thumbnailURL: String?

    /// 若為歌曲 / 影片類型，回傳對應的 AppTrack。
    func asTrack() -> AppTrack? {
        switch kind {
        case .song, .video:
            return AppTrack(
                id: UUID().uuidString,
                canonicalId: "yt:\(primaryId)",
                title: title,
                artist: subtitle ?? "Unknown",
                thumbnailURL: thumbnailURL,
                durationText: nil,
                source: .youtube(videoId: primaryId)
            )
        default:
            return nil
        }
    }
}

struct HomeSection: Identifiable, Equatable {
    var id: String { title + "-" + items.prefix(1).map(\.id).joined() }
    var title: String
    var strapline: String?
    var items: [HomeItem]
}

struct HomeFeed: Equatable {
    var sections: [HomeSection]

    static let empty = HomeFeed(sections: [])
}

struct LibraryPlaylist: Identifiable, Equatable {
    var id: String           // browseId
    var title: String
    var subtitle: String?
    var thumbnailURL: String?
}
