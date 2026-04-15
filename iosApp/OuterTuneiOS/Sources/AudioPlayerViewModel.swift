import AVFoundation
import Foundation
import SwiftUI

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var streamURL: String = "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"
    @Published var searchQuery: String = ""
    @Published var searchResults: [YouTubeSearchSong] = []
    @Published var isSearching: Bool = false
    @Published var activeDownloadTrackIds: Set<String> = []

    @Published var queue: [AppTrack] = []
    @Published var currentQueueIndex: Int? = nil

    @Published var isPlaying: Bool = false
    @Published var statusMessage: String = "就緒"

    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var sliderPosition: Double = 0
    @Published var isScrubbing: Bool = false

    @Published var lyricsText: String = ""
    @Published var isLoadingLyrics: Bool = false

    @Published var downloadedTracks: [AppTrack] = []
    @Published var favoriteTracks: [AppTrack] = []
    @Published var playbackHistory: [AppTrack] = []

    private var player: AVPlayer?
    private var periodicObserverToken: Any?
    private var playbackEndObserverToken: NSObjectProtocol?
    private var playerItemStatusObservationToken: NSKeyValueObservation?
    private var playerItemKeepUpObservationToken: NSKeyValueObservation?

    private let youtubeService = YouTubeMusicService.shared
    private let lyricsService = LyricsService.shared

    private let queueStorageKey = "ios.queue.v1"
    private let queueIndexStorageKey = "ios.queue.index.v1"
    private let downloadsStorageKey = "ios.downloads.v1"
    private let favoritesStorageKey = "ios.favorites.v1"
    private let historyStorageKey = "ios.history.v1"

    var nowPlayingTrack: AppTrack? {
        guard let currentQueueIndex, currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            return nil
        }
        return queue[currentQueueIndex]
    }

    init() {
        restoreQueueState()
        restoreDownloadsState()
        restoreFavoritesState()
        restoreHistoryState()
    }

    deinit {
        if let token = periodicObserverToken {
            player?.removeTimeObserver(token)
        }
        if let playbackToken = playbackEndObserverToken {
            NotificationCenter.default.removeObserver(playbackToken)
        }
        playerItemStatusObservationToken?.invalidate()
        playerItemKeepUpObservationToken?.invalidate()
    }

    func loadAndPlay() {
        guard let url = URL(string: streamURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else {
            statusMessage = "請輸入有效音訊網址（http/https）"
            return
        }

        let track = AppTrack(
            id: UUID().uuidString,
            canonicalId: "url:\(url.absoluteString)",
            title: "直接串流",
            artist: "URL",
            thumbnailURL: nil,
            durationText: nil,
            source: .directURL(url.absoluteString)
        )

        Task {
            await replaceQueueAndPlay(track: track)
        }
    }

    func searchYouTube() async {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        isSearching = true
        defer { isSearching = false }

        do {
            searchResults = try await youtubeService.searchSongs(query: query)
            statusMessage = "搜尋完成：\(searchResults.count) 筆"
        } catch {
            searchResults = []
            statusMessage = "搜尋失敗：\(error.localizedDescription)"
        }
    }

    func playSearchResult(_ song: YouTubeSearchSong) {
        Task {
            await replaceQueueAndPlay(track: song.asTrack())
        }
    }

    func enqueueSearchResult(_ song: YouTubeSearchSong) {
        enqueueTrack(song.asTrack(), status: "已加入佇列")
    }

    func downloadSearchResult(_ song: YouTubeSearchSong) {
        let track = song.asTrack()
        Task {
            await downloadTrack(track)
        }
    }

    func isDownloading(_ song: YouTubeSearchSong) -> Bool {
        activeDownloadTrackIds.contains("yt:\(song.videoId)")
    }

    func enqueueTrack(_ track: AppTrack, status: String? = nil) {
        queue.append(track)
        persistQueueState()
        if let status {
            statusMessage = status
        }
    }

    func playDownloadedTrack(_ track: AppTrack) {
        Task {
            await replaceQueueAndPlay(track: track)
        }
    }

    func removeDownloadedTrack(_ track: AppTrack) {
        if case .localFile(let relativePath) = track.source {
            let fileURL = localFileURL(relativePath: relativePath)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        downloadedTracks.removeAll { $0.stableId == track.stableId }
        persistDownloadsState()
    }

    func toggleFavoriteForNowPlaying() {
        guard let track = nowPlayingTrack else { return }
        toggleFavorite(track)
    }

    func toggleFavorite(_ track: AppTrack) {
        if let index = favoriteTracks.firstIndex(where: { $0.stableId == track.stableId }) {
            favoriteTracks.remove(at: index)
            statusMessage = "已取消收藏"
        } else {
            favoriteTracks.insert(track, at: 0)
            statusMessage = "已加入收藏"
        }
        persistFavoritesState()
    }

    func removeFavorite(_ track: AppTrack) {
        favoriteTracks.removeAll { $0.stableId == track.stableId }
        persistFavoritesState()
    }

    func isFavorite(_ track: AppTrack) -> Bool {
        favoriteTracks.contains(where: { $0.stableId == track.stableId })
    }

    func importLocalAudioFiles(from pickedURLs: [URL]) {
        guard !pickedURLs.isEmpty else { return }

        var importedCount = 0
        for pickedURL in pickedURLs {
            if let importedTrack = importLocalAudioFile(from: pickedURL) {
                enqueueTrack(importedTrack)
                downloadedTracks.insert(importedTrack, at: 0)
                importedCount += 1
            }
        }

        if importedCount > 0 {
            persistDownloadsState()
            statusMessage = "已匯入 \(importedCount) 首本機音訊"
        }
    }

    func playQueueItem(at index: Int) {
        guard index >= 0, index < queue.count else { return }
        Task {
            await playTrack(at: index)
        }
    }

    func removeQueueItem(at offsets: IndexSet) {
        queue.remove(atOffsets: offsets)
        if let currentQueueIndex {
            if queue.isEmpty {
                self.currentQueueIndex = nil
                player?.pause()
                isPlaying = false
            } else if currentQueueIndex >= queue.count {
                self.currentQueueIndex = queue.count - 1
            }
        }
        persistQueueState()
    }

    func moveQueueItem(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
        persistQueueState()
    }

    func playNext() {
        guard let currentQueueIndex, currentQueueIndex + 1 < queue.count else {
            return
        }
        playQueueItem(at: currentQueueIndex + 1)
    }

    func playPrevious() {
        guard let currentQueueIndex, currentQueueIndex - 1 >= 0 else {
            return
        }
        playQueueItem(at: currentQueueIndex - 1)
    }

    func loadLyricsForCurrentTrack() {
        guard let track = nowPlayingTrack else {
            lyricsText = ""
            return
        }

        isLoadingLyrics = true
        Task {
            defer { isLoadingLyrics = false }
            let seconds: Int?
            if duration.isFinite && duration > 0 {
                seconds = Int(duration)
            } else {
                seconds = nil
            }
            let lyrics = await lyricsService.fetchSyncedLyrics(
                title: track.title,
                artist: track.artist,
                duration: seconds
            )
            lyricsText = lyrics ?? "找不到歌詞"
        }
    }

    func clearLyrics() {
        lyricsText = ""
    }

    func togglePlayback() {
        if isPlaying {
            pause()
        } else {
            play()
        }
    }

    func play() {
        guard player != nil else {
            if let currentQueueIndex {
                playQueueItem(at: currentQueueIndex)
            } else {
                loadAndPlay()
            }
            return
        }
        player?.play()
        isPlaying = true
        statusMessage = "播放中"
    }

    func pause() {
        player?.pause()
        isPlaying = false
        statusMessage = "已暫停"
    }

    func seekBackward15() {
        seek(to: max(currentTime - 15, 0))
    }

    func seekForward15() {
        let maxTime = duration > 0 ? duration : currentTime + 15
        seek(to: min(currentTime + 15, maxTime))
    }

    func beginScrubbing() {
        isScrubbing = true
    }

    func updateScrubbing(position: Double) {
        sliderPosition = position
    }

    func endScrubbing() {
        isScrubbing = false
        seek(to: sliderPosition)
    }

    func formattedTime(_ time: Double) -> String {
        guard time.isFinite && time >= 0 else { return "00:00" }
        let totalSeconds = Int(time)
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func replaceQueueAndPlay(track: AppTrack) async {
        queue = [track]
        currentQueueIndex = 0
        persistQueueState()
        await playTrack(at: 0)
    }

    private func playTrack(at index: Int) async {
        guard index >= 0, index < queue.count else { return }
        let track = queue[index]
        currentQueueIndex = index
        persistQueueState()

        statusMessage = "解析串流中..."
        do {
            let resolvedURL = try await resolvePlayableURL(for: track)
            streamURL = resolvedURL.absoluteString
            let item = AVPlayerItem(url: resolvedURL)
            if player == nil {
                player = AVPlayer(playerItem: item)
                installPeriodicTimeObserver()
            } else {
                player?.replaceCurrentItem(with: item)
            }

            currentTime = 0
            sliderPosition = 0
            duration = inferredFallbackDuration(for: track, streamURL: resolvedURL) ?? 0
            lyricsText = ""

            observePlayerItemState(item: item, trackTitle: track.title)
            observePlaybackEnd(item: item)
            player?.play()
            isPlaying = true
            trackDidStartPlaying(track)
            statusMessage = "緩衝中：\(track.title)"
        } catch {
            isPlaying = false
            statusMessage = "播放失敗：\(error.localizedDescription)"
        }
    }

    private func resolvePlayableURL(for track: AppTrack) async throws -> URL {
        switch track.source {
        case .directURL(let urlString):
            guard let url = URL(string: urlString) else {
                throw YouTubeMusicServiceError.invalidResponse
            }
            return url
        case .youtube(let videoId):
            return try await youtubeService.resolveAudioStreamURL(videoId: videoId)
        case .localFile(let relativePath):
            let localURL = localFileURL(relativePath: relativePath)
            if FileManager.default.fileExists(atPath: localURL.path) {
                return localURL
            }
            throw YouTubeMusicServiceError.invalidResponse
        }
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target)
        currentTime = seconds
        sliderPosition = seconds
    }

    private func installPeriodicTimeObserver() {
        guard let player else { return }
        if let token = periodicObserverToken {
            player.removeTimeObserver(token)
        }

        let observedPlayer = player

        periodicObserverToken = observedPlayer.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self, weak observedPlayer] time in
            let seconds = time.seconds
            let itemDuration = observedPlayer?.currentItem?.duration.seconds ?? 0
            let assetDuration = observedPlayer?.currentItem?.asset.duration.seconds ?? 0

            Task { @MainActor in
                guard let self else { return }

                if seconds.isFinite {
                    self.currentTime = max(seconds, 0)
                    if !self.isScrubbing {
                        self.sliderPosition = self.currentTime
                    }
                }

                if itemDuration.isFinite && itemDuration > 0 {
                    self.duration = itemDuration
                } else if assetDuration.isFinite && assetDuration > 0 {
                    self.duration = assetDuration
                }
            }
        }
    }

    private func observePlayerItemState(item: AVPlayerItem, trackTitle: String) {
        playerItemStatusObservationToken?.invalidate()
        playerItemKeepUpObservationToken?.invalidate()

        playerItemStatusObservationToken = item.observe(\.status, options: [.initial, .new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self else { return }

                switch observedItem.status {
                case .readyToPlay:
                    let resolvedDuration = observedItem.duration.seconds
                    if resolvedDuration.isFinite && resolvedDuration > 0 {
                        self.duration = resolvedDuration
                    }
                    if self.isPlaying {
                        self.statusMessage = "播放中：\(trackTitle)"
                    } else {
                        self.statusMessage = "已就緒：\(trackTitle)"
                    }
                case .failed:
                    self.isPlaying = false
                    let message = observedItem.error?.localizedDescription ?? "音訊格式不支援或串流已失效"
                    self.statusMessage = "播放失敗：\(message)"
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        playerItemKeepUpObservationToken = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observedItem, _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.isPlaying else { return }

                if observedItem.isPlaybackLikelyToKeepUp {
                    self.statusMessage = "播放中：\(trackTitle)"
                } else {
                    self.statusMessage = "緩衝中：\(trackTitle)"
                }
            }
        }
    }

    private func observePlaybackEnd(item: AVPlayerItem) {
        if let token = playbackEndObserverToken {
            NotificationCenter.default.removeObserver(token)
        }

        playbackEndObserverToken = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                self.isPlaying = false
                self.currentTime = 0
                self.sliderPosition = 0
                self.player?.seek(to: .zero)

                if self.shouldAutoPlayNext {
                    self.playNext()
                } else {
                    self.statusMessage = "播放完成"
                }
            }
        }
    }

    private func downloadTrack(_ track: AppTrack) async {
        let stableId = track.stableId
        if activeDownloadTrackIds.contains(stableId) {
            return
        }

        activeDownloadTrackIds.insert(stableId)
        defer { activeDownloadTrackIds.remove(stableId) }

        do {
            statusMessage = "下載中：\(track.title)"
            let streamURL = try await resolvePlayableURL(for: track)
            let downloadedTrack = try await downloadAudioFile(from: streamURL, originalTrack: track)

            downloadedTracks.removeAll { $0.stableId == downloadedTrack.stableId }
            downloadedTracks.insert(downloadedTrack, at: 0)
            persistDownloadsState()

            statusMessage = "下載完成：\(downloadedTrack.title)"
        } catch {
            statusMessage = "下載失敗：\(error.localizedDescription)"
        }
    }

    private func downloadAudioFile(from remoteURL: URL, originalTrack: AppTrack) async throws -> AppTrack {
        let request = URLRequest(url: remoteURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        let (temporaryURL, response) = try await URLSession.shared.download(for: request)

        let downloadsDirectory = try ensureDirectory(relativePath: "Downloads")
        let ext = suggestedAudioExtension(from: response, fallbackURL: remoteURL)
        let fileToken = preferredFileToken(for: originalTrack)
        let safeTitle = sanitizeFileName(originalTrack.title)
        let destinationFileName = "\(safeTitle)-\(fileToken).\(ext)"
        let destinationURL = downloadsDirectory.appendingPathComponent(destinationFileName)

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)

        return AppTrack(
            id: UUID().uuidString,
            canonicalId: originalTrack.stableId,
            title: originalTrack.title,
            artist: originalTrack.artist,
            thumbnailURL: originalTrack.thumbnailURL,
            durationText: originalTrack.durationText,
            source: .localFile(path: "Downloads/\(destinationFileName)")
        )
    }

    private func importLocalAudioFile(from pickedURL: URL) -> AppTrack? {
        let hasScopedAccess = pickedURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                pickedURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let importsDirectory = try ensureDirectory(relativePath: "Imports")

            let sourceExt = pickedURL.pathExtension.isEmpty ? "m4a" : pickedURL.pathExtension
            let baseName = pickedURL.deletingPathExtension().lastPathComponent
            let safeName = sanitizeFileName(baseName)
            let fileName = "\(safeName)-\(UUID().uuidString.prefix(8)).\(sourceExt)"
            let destinationURL = importsDirectory.appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            try FileManager.default.copyItem(at: pickedURL, to: destinationURL)

            return AppTrack(
                id: UUID().uuidString,
                canonicalId: "file:Imports/\(fileName)",
                title: baseName,
                artist: "本機檔案",
                thumbnailURL: nil,
                durationText: nil,
                source: .localFile(path: "Imports/\(fileName)")
            )
        } catch {
            statusMessage = "匯入失敗：\(error.localizedDescription)"
            return nil
        }
    }

    private func trackDidStartPlaying(_ track: AppTrack) {
        if let index = favoriteTracks.firstIndex(where: { $0.stableId == track.stableId }) {
            favoriteTracks[index] = track
            persistFavoritesState()
        }

        if let latest = playbackHistory.first, latest.stableId == track.stableId {
            return
        }

        playbackHistory.removeAll { $0.stableId == track.stableId }
        playbackHistory.insert(track, at: 0)
        if playbackHistory.count > 100 {
            playbackHistory.removeLast(playbackHistory.count - 100)
        }
        persistHistoryState()
    }

    private func localFileURL(relativePath: String) -> URL {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return documents.appendingPathComponent(relativePath)
    }

    private func ensureDirectory(relativePath: String) throws -> URL {
        let directoryURL = localFileURL(relativePath: relativePath)
        if !FileManager.default.fileExists(atPath: directoryURL.path) {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }
        return directoryURL
    }

    private func preferredFileToken(for track: AppTrack) -> String {
        switch track.source {
        case .youtube(let videoId):
            return sanitizeFileName(videoId)
        default:
            return String(UUID().uuidString.prefix(8))
        }
    }

    private func suggestedAudioExtension(from response: URLResponse, fallbackURL: URL) -> String {
        if let mimeType = response.mimeType?.lowercased() {
            if mimeType.contains("webm") {
                return "webm"
            }
            if mimeType.contains("mpeg") {
                return "mp3"
            }
            if mimeType.contains("aac") {
                return "aac"
            }
            if mimeType.contains("ogg") {
                return "ogg"
            }
            if mimeType.contains("mp4") {
                return "m4a"
            }
        }

        let fallbackExt = fallbackURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallbackExt.isEmpty ? "m4a" : sanitizeFileName(fallbackExt)
    }

    private func sanitizeFileName(_ value: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._- "))
        let sanitized = value.unicodeScalars.map { allowed.contains($0) ? String($0) : "-" }.joined()
        let collapsed = sanitized.replacingOccurrences(of: "-+", with: "-", options: .regularExpression)
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " .-_"))
        return trimmed.isEmpty ? "audio" : trimmed
    }

    private func inferredFallbackDuration(for track: AppTrack, streamURL: URL) -> Double? {
        if let fromURL = durationFromURL(streamURL), fromURL > 0 {
            return fromURL
        }
        if let durationText = track.durationText,
           let fromText = parseDurationText(durationText),
           fromText > 0 {
            return fromText
        }
        return nil
    }

    private func durationFromURL(_ url: URL) -> Double? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let items = components.queryItems,
            let raw = items.first(where: { $0.name == "dur" })?.value,
            let value = Double(raw),
            value.isFinite,
            value > 0
        else {
            return nil
        }
        return value
    }

    private func parseDurationText(_ value: String) -> Double? {
        let parts = value.split(separator: ":").compactMap { Int($0) }
        if parts.count == 2 {
            return Double(parts[0] * 60 + parts[1])
        }
        if parts.count == 3 {
            return Double(parts[0] * 3600 + parts[1] * 60 + parts[2])
        }
        return nil
    }

    private var shouldAutoPlayNext: Bool {
        if UserDefaults.standard.object(forKey: "settings.autoPlayNext") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "settings.autoPlayNext")
    }

    private func persistQueueState() {
        if let data = try? JSONEncoder().encode(queue) {
            UserDefaults.standard.set(data, forKey: queueStorageKey)
        }
        if let currentQueueIndex {
            UserDefaults.standard.set(currentQueueIndex, forKey: queueIndexStorageKey)
        } else {
            UserDefaults.standard.removeObject(forKey: queueIndexStorageKey)
        }
    }

    private func restoreQueueState() {
        guard
            let data = UserDefaults.standard.data(forKey: queueStorageKey),
            let restoredQueue = try? JSONDecoder().decode([AppTrack].self, from: data)
        else {
            return
        }

        queue = restoredQueue
        if let storedIndex = UserDefaults.standard.object(forKey: queueIndexStorageKey) as? Int,
           queue.indices.contains(storedIndex) {
            currentQueueIndex = storedIndex
        } else if !queue.isEmpty {
            currentQueueIndex = 0
        }
    }

    private func persistDownloadsState() {
        if let data = try? JSONEncoder().encode(downloadedTracks) {
            UserDefaults.standard.set(data, forKey: downloadsStorageKey)
        }
    }

    private func restoreDownloadsState() {
        guard
            let data = UserDefaults.standard.data(forKey: downloadsStorageKey),
            let restored = try? JSONDecoder().decode([AppTrack].self, from: data)
        else {
            return
        }

        downloadedTracks = restored.filter { track in
            if case .localFile(let path) = track.source {
                return FileManager.default.fileExists(atPath: localFileURL(relativePath: path).path)
            }
            return false
        }
    }

    private func persistFavoritesState() {
        if let data = try? JSONEncoder().encode(favoriteTracks) {
            UserDefaults.standard.set(data, forKey: favoritesStorageKey)
        }
    }

    private func restoreFavoritesState() {
        guard
            let data = UserDefaults.standard.data(forKey: favoritesStorageKey),
            let restored = try? JSONDecoder().decode([AppTrack].self, from: data)
        else {
            return
        }

        favoriteTracks = restored
    }

    private func persistHistoryState() {
        if let data = try? JSONEncoder().encode(playbackHistory) {
            UserDefaults.standard.set(data, forKey: historyStorageKey)
        }
    }

    private func restoreHistoryState() {
        guard
            let data = UserDefaults.standard.data(forKey: historyStorageKey),
            let restored = try? JSONDecoder().decode([AppTrack].self, from: data)
        else {
            return
        }

        playbackHistory = restored
    }
}

enum AudioSessionConfigurator {
    static func configureForPlayback() {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetooth])
            try session.setActive(true)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
#endif
    }
}
