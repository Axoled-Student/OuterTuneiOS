import AVFoundation
import Foundation
import MediaPlayer
import SwiftUI

#if os(iOS)
import UIKit
#endif

@MainActor
final class AudioPlayerViewModel: ObservableObject {
    @Published var streamURL: String = "https://www.soundhelix.com/examples/mp3/SoundHelix-Song-1.mp3"
    @Published var searchQuery: String = ""
    @Published var searchResults: [YouTubeSearchSong] = []
    @Published var autocompleteSuggestions: [String] = []
    @Published var isLoadingAutocomplete: Bool = false
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
    @Published var audioQualityPreference: AudioQualityPreference = .auto
    @Published private(set) var availableStreamOptions: [AudioStreamOption] = []
    @Published private(set) var nowPlayingStreamInfo: AudioStreamOption?

    @Published var homeFeed: HomeFeed = .empty
    @Published var isLoadingHome: Bool = false
    @Published var homeErrorMessage: String?

    @Published var libraryPlaylists: [LibraryPlaylist] = []
    @Published var isLoadingLibraryPlaylists: Bool = false
    @Published var libraryErrorMessage: String?

    private var player: AVPlayer?
    private var periodicObserverToken: Any?
    private var playbackEndObserverToken: NSObjectProtocol?
    private var audioInterruptionObserverToken: NSObjectProtocol?
    private var audioRouteChangeObserverToken: NSObjectProtocol?
    private var mediaServicesResetObserverToken: NSObjectProtocol?
    private var playerItemStatusObservationToken: NSKeyValueObservation?
    private var playerItemKeepUpObservationToken: NSKeyValueObservation?

    private var playbackCandidates: [AudioStreamOption] = []
    private var playbackCandidateIndex: Int = 0
    private var activePlaybackTrackStableId: String?
    private var autocompleteTask: Task<Void, Never>?

    private var hasConfiguredRemoteCommands: Bool = false
    private var nowPlayingArtworkSourceURL: String?
    private var nowPlayingArtworkTask: Task<Void, Never>?

    private let youtubeService = YouTubeMusicService.shared
    private let lyricsService = LyricsService.shared
    private let accountStore = AccountStore.shared

    private let queueStorageKey = "ios.queue.v1"
    private let queueIndexStorageKey = "ios.queue.index.v1"
    private let downloadsStorageKey = "ios.downloads.v1"
    private let favoritesStorageKey = "ios.favorites.v1"
    private let historyStorageKey = "ios.history.v1"
    private let searchHistoryStorageKey = "ios.searchHistory.v1"
    private let audioQualityStorageKey = "ios.audioQualityPreference.v1"

    private var searchHistory: [String] = []

    var nowPlayingTrack: AppTrack? {
        guard let currentQueueIndex, currentQueueIndex >= 0, currentQueueIndex < queue.count else {
            return nil
        }
        return queue[currentQueueIndex]
    }

    init() {
        AudioSessionConfigurator.configureForPlayback()
        observeAudioSessionInterruptions()
        configureRemoteCommandCenterIfNeeded()
        restoreQueueState()
        restoreDownloadsState()
        restoreFavoritesState()
        restoreHistoryState()
        restoreAudioQualityPreferenceState()
        restoreSearchHistoryState()
        autocompleteSuggestions = Array(searchHistory.prefix(6))
        wireYouTubeAuthProvider()
    }

    private func wireYouTubeAuthProvider() {
        // Bridge AccountStore credentials into the YouTube Music service so
        // authenticated endpoints (home feed, library, account info) can
        // attach Cookie / Authorization headers.
        YouTubeMusicService.shared.authProvider = { [weak self] in
            guard let self else { return nil }
            let store = self.accountStore
            let cookie = store.cookie
            guard !cookie.isEmpty else { return nil }
            return YouTubeAuthContext(
                cookie: cookie,
                visitorData: store.visitorData,
                dataSyncId: store.dataSyncId,
                sapisid: store.sapisidValue()
            )
        }
    }

    @MainActor
    func refreshAccountInfo() async {
        guard accountStore.isLoggedIn else {
            accountStore.updateAccountInfo(nil)
            return
        }
        do {
            let info = try await youtubeService.fetchAccountInfo()
            accountStore.updateAccountInfo(info)
        } catch {
            // Swallow: UI will just show logged-out state.
            accountStore.updateAccountInfo(nil)
        }
    }

    @MainActor
    func refreshHomeFeed() async {
        isLoadingHome = true
        homeErrorMessage = nil
        defer { isLoadingHome = false }
        do {
            let feed = try await youtubeService.fetchHomeFeed()
            homeFeed = feed
        } catch YouTubeMusicServiceError.notLoggedIn {
            homeFeed = .empty
            homeErrorMessage = "請先登入 Google 帳號以取得個人化首頁"
        } catch {
            homeErrorMessage = "載入首頁失敗：\(error.localizedDescription)"
        }
    }

    @MainActor
    func refreshLibraryPlaylists() async {
        isLoadingLibraryPlaylists = true
        libraryErrorMessage = nil
        defer { isLoadingLibraryPlaylists = false }
        do {
            let playlists = try await youtubeService.fetchLibraryPlaylists()
            libraryPlaylists = playlists
        } catch YouTubeMusicServiceError.notLoggedIn {
            libraryPlaylists = []
            libraryErrorMessage = "請先登入 Google 帳號以查看您的音樂庫"
        } catch {
            libraryErrorMessage = "載入音樂庫失敗：\(error.localizedDescription)"
        }
    }

    @MainActor
    func logoutYouTubeAccount() {
        accountStore.logout()
        homeFeed = .empty
        libraryPlaylists = []
        homeErrorMessage = nil
        libraryErrorMessage = nil
    }

    deinit {
        if let token = periodicObserverToken {
            player?.removeTimeObserver(token)
        }
        if let playbackToken = playbackEndObserverToken {
            NotificationCenter.default.removeObserver(playbackToken)
        }
        if let interruptionToken = audioInterruptionObserverToken {
            NotificationCenter.default.removeObserver(interruptionToken)
        }
        if let routeChangeToken = audioRouteChangeObserverToken {
            NotificationCenter.default.removeObserver(routeChangeToken)
        }
        if let mediaResetToken = mediaServicesResetObserverToken {
            NotificationCenter.default.removeObserver(mediaResetToken)
        }
        playerItemStatusObservationToken?.invalidate()
        playerItemKeepUpObservationToken?.invalidate()
        autocompleteTask?.cancel()
        nowPlayingArtworkTask?.cancel()
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

        saveSearchHistoryQuery(query)
        autocompleteSuggestions = []

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

    func scheduleAutocomplete() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        autocompleteTask?.cancel()

        if query.isEmpty {
            autocompleteSuggestions = Array(searchHistory.prefix(6))
            isLoadingAutocomplete = false
            return
        }

        let local = localAutocompleteSuggestions(for: query)
        autocompleteSuggestions = local

        autocompleteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.fetchRemoteAutocomplete(for: query, localSeed: local)
        }
    }

    func applyAutocompleteSuggestion(_ suggestion: String) {
        searchQuery = suggestion
        autocompleteSuggestions = []
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
                playbackCandidates = []
                availableStreamOptions = []
                nowPlayingStreamInfo = nil
                clearNowPlayingInfo()
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

    func setAudioQualityPreference(_ preference: AudioQualityPreference) {
        guard audioQualityPreference != preference else {
            return
        }

        audioQualityPreference = preference
        persistAudioQualityPreferenceState()

        guard let track = nowPlayingTrack else {
            return
        }

        playbackCandidates = prioritizePlaybackCandidates(playbackCandidates)
        availableStreamOptions = playbackCandidates

        guard !playbackCandidates.isEmpty else {
            return
        }

        let resumeTime = currentTime
        playbackCandidateIndex = 0
        statusMessage = "音質：\(preference.displayName)"
        player?.pause()
        _ = AudioSessionConfigurator.configureForPlayback()
        startPlaybackAttempt(track: track)

        if resumeTime > 1 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.seekAfterSwitch(resumeTime: resumeTime)
            }
        }
    }

    func selectAudioStream(_ stream: AudioStreamOption) {
        guard let track = nowPlayingTrack else {
            return
        }

        guard let index = playbackCandidates.firstIndex(where: { $0.id == stream.id }) else {
            return
        }

        guard index != playbackCandidateIndex else {
            return
        }

        let resumeTime = currentTime
        playbackCandidateIndex = index
        statusMessage = "切換來源：\(stream.displayTitle)"
        player?.pause()
        _ = AudioSessionConfigurator.configureForPlayback()
        startPlaybackAttempt(track: track)

        if resumeTime > 1 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 350_000_000)
                self?.seekAfterSwitch(resumeTime: resumeTime)
            }
        }
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
        _ = AudioSessionConfigurator.configureForPlayback()
        guard player != nil else {
            if let currentQueueIndex {
                playQueueItem(at: currentQueueIndex)
            } else {
                loadAndPlay()
            }
            return
        }
        player?.isMuted = false
        player?.volume = 1.0
        player?.play()
        isPlaying = true
        statusMessage = "播放中"
        updateNowPlayingPlaybackState()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        statusMessage = "已暫停"
        updateNowPlayingPlaybackState()
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
            _ = AudioSessionConfigurator.configureForPlayback()
            playbackCandidates = try await resolvePlayableStreams(for: track)
            availableStreamOptions = playbackCandidates
            playbackCandidateIndex = 0
            activePlaybackTrackStableId = track.stableId
            nowPlayingStreamInfo = playbackCandidates.first

            guard !playbackCandidates.isEmpty else {
                throw YouTubeMusicServiceError.noPlayableStream
            }

            startPlaybackAttempt(track: track)
            trackDidStartPlaying(track)
        } catch {
            isPlaying = false
            playbackCandidates = []
            availableStreamOptions = []
            nowPlayingStreamInfo = nil
            statusMessage = "播放失敗：\(error.localizedDescription)"
        }
    }

    private func resolvePlayableStreams(for track: AppTrack) async throws -> [AudioStreamOption] {
        switch track.source {
        case .directURL(let urlString):
            guard let url = URL(string: urlString) else {
                throw YouTubeMusicServiceError.invalidResponse
            }
            return [
                AudioStreamOption(
                    id: "direct:\(url.absoluteString)",
                    url: url,
                    sourceClientName: "DIRECT",
                    sourceClientVersion: "-",
                    mimeType: nil,
                    codec: nil,
                    container: "URL",
                    bitrate: nil,
                    averageBitrate: nil,
                    audioQuality: nil,
                    contentLength: nil,
                    itag: nil,
                    isHLSManifest: false
                )
            ]
        case .youtube(let videoId):
            let resolved = try await youtubeService.resolveAudioStreams(videoId: videoId)
            return prioritizePlaybackCandidates(resolved)
        case .localFile(let relativePath):
            let localURL = localFileURL(relativePath: relativePath)
            if FileManager.default.fileExists(atPath: localURL.path) {
                let ext = localURL.pathExtension.uppercased()
                return [
                    AudioStreamOption(
                        id: "local:\(localURL.absoluteString)",
                        url: localURL,
                        sourceClientName: "LOCAL",
                        sourceClientVersion: "-",
                        mimeType: nil,
                        codec: nil,
                        container: ext.isEmpty ? "LOCAL" : ext,
                        bitrate: nil,
                        averageBitrate: nil,
                        audioQuality: nil,
                        contentLength: nil,
                        itag: nil,
                        isHLSManifest: false
                    )
                ]
            }
            throw YouTubeMusicServiceError.invalidResponse
        }
    }

    private func startPlaybackAttempt(track: AppTrack) {
        guard playbackCandidates.indices.contains(playbackCandidateIndex) else {
            isPlaying = false
            nowPlayingStreamInfo = nil
            statusMessage = "播放失敗：找不到可播放串流"
            updateNowPlayingPlaybackState()
            return
        }

        let selectedStream = playbackCandidates[playbackCandidateIndex]
        let resolvedURL = selectedStream.url
        nowPlayingStreamInfo = selectedStream
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

        observePlayerItemState(item: item, track: track)
        observePlaybackEnd(item: item)
        player?.isMuted = false
        player?.volume = 1.0
        player?.play()
        isPlaying = true
        updateNowPlayingInfo(for: track)

        if playbackCandidateIndex == 0 {
            statusMessage = "緩衝中：\(track.title)"
        } else {
            statusMessage = "切換備援串流 \(playbackCandidateIndex + 1)/\(playbackCandidates.count)..."
        }
    }

    private func tryFallbackPlaybackIfNeeded(for track: AppTrack) -> Bool {
        guard activePlaybackTrackStableId == track.stableId else {
            return false
        }

        let nextIndex = playbackCandidateIndex + 1
        guard playbackCandidates.indices.contains(nextIndex) else {
            return false
        }

        playbackCandidateIndex = nextIndex
        player?.pause()
        _ = AudioSessionConfigurator.configureForPlayback()
        startPlaybackAttempt(track: track)
        return true
    }

    private func seek(to seconds: Double) {
        guard let player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target)
        currentTime = seconds
        sliderPosition = seconds
        updateNowPlayingPlaybackState()
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

                self.updateNowPlayingPlaybackState()
            }
        }
    }

    private func observePlayerItemState(item: AVPlayerItem, track: AppTrack) {
        playerItemStatusObservationToken?.invalidate()
        playerItemKeepUpObservationToken?.invalidate()

        let trackTitle = track.title

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
                        if self.playbackCandidateIndex == 0 {
                            self.statusMessage = "播放中：\(trackTitle)"
                        } else {
                            self.statusMessage = "播放中（備援）：\(trackTitle)"
                        }
                        self.updateNowPlayingPlaybackState()
                    } else {
                        self.statusMessage = "已就緒：\(trackTitle)"
                        self.updateNowPlayingInfo(for: track)
                    }
                case .failed:
                    if self.tryFallbackPlaybackIfNeeded(for: track) {
                        return
                    }

                    self.isPlaying = false
                    let message = self.describePlaybackFailure(from: observedItem)
                    self.statusMessage = "播放失敗：\(message)"
                    self.updateNowPlayingPlaybackState()
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
                self.updateNowPlayingPlaybackState()

                if self.shouldAutoPlayNext {
                    self.playNext()
                } else {
                    self.statusMessage = "播放完成"
                }
            }
        }
    }

    private func describePlaybackFailure(from item: AVPlayerItem) -> String {
        if let error = item.error as NSError? {
            if error.domain == "CoreMediaErrorDomain", error.code == -12660 {
                return "串流格式不相容（CoreMedia -12660）"
            }

            if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
                if underlying.domain == "CoreMediaErrorDomain", underlying.code == -12660 {
                    return "串流格式不相容（CoreMedia -12660）"
                }
                return "\(error.localizedDescription) [\(underlying.domain):\(underlying.code)]"
            }
            return "\(error.localizedDescription) [\(error.domain):\(error.code)]"
        }

        if let event = item.errorLog()?.events.last {
            if event.errorStatusCode != 0 {
                return "串流錯誤碼 \(event.errorStatusCode)"
            }
            return "串流暫時不可用"
        }

        return "unknown error"
    }

    private func fetchRemoteAutocomplete(for query: String, localSeed: [String]) async {
        isLoadingAutocomplete = true
        defer { isLoadingAutocomplete = false }

        do {
            let remote = try await youtubeService.autocompleteSuggestions(query: query)
            var merged = localSeed
            for item in remote where !merged.contains(where: { $0.caseInsensitiveCompare(item) == .orderedSame }) {
                merged.append(item)
            }
            autocompleteSuggestions = Array(merged.prefix(10))
        } catch {
            autocompleteSuggestions = localSeed
        }
    }

    private func localAutocompleteSuggestions(for query: String) -> [String] {
        let normalized = query.lowercased()
        let prefixMatches = searchHistory.filter {
            $0.lowercased().hasPrefix(normalized)
        }
        let containsMatches = searchHistory.filter {
            !$0.lowercased().hasPrefix(normalized) && $0.lowercased().contains(normalized)
        }
        return Array((prefixMatches + containsMatches).prefix(8))
    }

    private func saveSearchHistoryQuery(_ query: String) {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        searchHistory.removeAll { $0.caseInsensitiveCompare(normalized) == .orderedSame }
        searchHistory.insert(normalized, at: 0)
        if searchHistory.count > 30 {
            searchHistory.removeLast(searchHistory.count - 30)
        }

        if let data = try? JSONEncoder().encode(searchHistory) {
            UserDefaults.standard.set(data, forKey: searchHistoryStorageKey)
        }
    }

    private func restoreSearchHistoryState() {
        guard
            let data = UserDefaults.standard.data(forKey: searchHistoryStorageKey),
            let restored = try? JSONDecoder().decode([String].self, from: data)
        else {
            return
        }

        searchHistory = restored
    }

    private func configureRemoteCommandCenterIfNeeded() {
#if os(iOS)
        guard !hasConfiguredRemoteCommands else { return }
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.changePlaybackPositionCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.play() }
            return .success
        }
        commandCenter.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }
        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playNext() }
            return .success
        }
        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.playPrevious() }
            return .success
        }
        commandCenter.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let changeEvent = event as? MPChangePlaybackPositionCommandEvent else {
                return .commandFailed
            }
            Task { @MainActor in
                self?.seek(to: changeEvent.positionTime)
            }
            return .success
        }

        hasConfiguredRemoteCommands = true
#endif
    }

    private func updateNowPlayingInfo(for track: AppTrack) {
#if os(iOS)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPMediaItemPropertyTitle] = track.title
        info[MPMediaItemPropertyArtist] = track.artist
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(currentTime, 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused

        updateNowPlayingArtworkIfNeeded(for: track)
#endif
    }

    private func updateNowPlayingPlaybackState() {
#if os(iOS)
        guard nowPlayingTrack != nil else {
            return
        }

        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(currentTime, 0)
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
#endif
    }

    private func clearNowPlayingInfo() {
#if os(iOS)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
#endif
    }

    private func updateNowPlayingArtworkIfNeeded(for track: AppTrack) {
#if os(iOS)
        guard let rawURL = track.thumbnailURL, !rawURL.isEmpty else {
            return
        }

        guard nowPlayingArtworkSourceURL != rawURL else {
            return
        }

        nowPlayingArtworkSourceURL = rawURL
        nowPlayingArtworkTask?.cancel()

        nowPlayingArtworkTask = Task {
            guard let url = URL(string: rawURL) else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            guard !Task.isCancelled else { return }
            guard let image = UIImage(data: data) else { return }

            let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
            var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            info[MPMediaItemPropertyArtwork] = artwork
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        }
#endif
    }

    private func observeAudioSessionInterruptions() {
#if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()

        audioInterruptionObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }

                guard
                    let info = notification.userInfo,
                    let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                    let type = AVAudioSession.InterruptionType(rawValue: rawType)
                else {
                    return
                }

                switch type {
                case .began:
                    self.isPlaying = false
                    self.statusMessage = "音訊被中斷"
                case .ended:
                    let optionsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                    let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
                    _ = AudioSessionConfigurator.configureForPlayback()

                    if options.contains(.shouldResume) {
                        self.isPlaying = true
                        self.refreshAudioOutput(shouldForcePlay: true, status: "播放中")
                    }
                @unknown default:
                    break
                }
            }
        }

        audioRouteChangeObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor in
                guard let self else { return }

                let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
                guard let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) else {
                    return
                }

                switch reason {
                case .newDeviceAvailable, .oldDeviceUnavailable, .categoryChange, .override, .routeConfigurationChange:
                    self.refreshAudioOutput(shouldForcePlay: self.isPlaying)
                default:
                    break
                }
            }
        }

        mediaServicesResetObserverToken = NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: audioSession,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }

                _ = AudioSessionConfigurator.configureForPlayback()
                guard self.isPlaying, let queueIndex = self.currentQueueIndex else {
                    self.refreshAudioOutput(shouldForcePlay: false)
                    return
                }

                self.statusMessage = "音訊服務重置，重新載入中..."
                Task {
                    await self.playTrack(at: queueIndex)
                }
            }
        }
#endif
    }

    private func refreshAudioOutput(shouldForcePlay: Bool, status: String? = nil) {
#if os(iOS)
        _ = AudioSessionConfigurator.configureForPlayback()
        player?.isMuted = false
        player?.volume = 1.0
        if shouldForcePlay {
            player?.play()
            isPlaying = true
        }
        if let status {
            statusMessage = status
        }
        updateNowPlayingPlaybackState()
#endif
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
            guard let streamURL = try await resolvePlayableStreams(for: track).first?.url else {
                throw YouTubeMusicServiceError.noPlayableStream
            }
            let downloadedTrack = try await downloadAudioFile(from: streamURL, originalTrack: track)

            downloadedTracks.removeAll { $0.stableId == downloadedTrack.stableId }
            downloadedTracks.insert(downloadedTrack, at: 0)
            persistDownloadsState()

            statusMessage = "下載完成：\(downloadedTrack.title)"
        } catch {
            statusMessage = "下載失敗：\(error.localizedDescription)"
        }
    }

    private func prioritizePlaybackCandidates(_ candidates: [AudioStreamOption]) -> [AudioStreamOption] {
        guard audioQualityPreference != .auto else {
            return candidates
        }

        let knownBitrate = candidates.enumerated().filter { (_, stream) in
            guard let bitrate = stream.effectiveBitrate else {
                return false
            }
            return bitrate > 0
        }

        let unknownBitrate = candidates.enumerated().filter { (_, stream) in
            stream.effectiveBitrate == nil || stream.effectiveBitrate == 0
        }

        let sortedKnown = knownBitrate.sorted { lhs, rhs in
            let leftBitrate = lhs.element.effectiveBitrate ?? 0
            let rightBitrate = rhs.element.effectiveBitrate ?? 0

            switch audioQualityPreference {
            case .high:
                if leftBitrate == rightBitrate {
                    return lhs.offset < rhs.offset
                }
                return leftBitrate > rightBitrate
            case .medium:
                let target = 128_000
                let leftDistance = abs(leftBitrate - target)
                let rightDistance = abs(rightBitrate - target)
                if leftDistance == rightDistance {
                    if leftBitrate == rightBitrate {
                        return lhs.offset < rhs.offset
                    }
                    return leftBitrate > rightBitrate
                }
                return leftDistance < rightDistance
            case .low:
                if leftBitrate == rightBitrate {
                    return lhs.offset < rhs.offset
                }
                return leftBitrate < rightBitrate
            case .auto:
                return lhs.offset < rhs.offset
            }
        }

        return sortedKnown.map(\.element) + unknownBitrate.map(\.element)
    }

    private func seekAfterSwitch(resumeTime: Double) {
        let target: Double
        if duration > 0 {
            target = min(resumeTime, max(duration - 1, 0))
        } else {
            target = resumeTime
        }

        if target > 0 {
            seek(to: target)
        }
    }

    private func persistAudioQualityPreferenceState() {
        UserDefaults.standard.set(audioQualityPreference.rawValue, forKey: audioQualityStorageKey)
    }

    private func restoreAudioQualityPreferenceState() {
        guard
            let rawValue = UserDefaults.standard.string(forKey: audioQualityStorageKey),
            let restored = AudioQualityPreference(rawValue: rawValue)
        else {
            return
        }

        audioQualityPreference = restored
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
    @discardableResult
    static func configureForPlayback() -> Bool {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playback,
                mode: .default,
                options: [.allowAirPlay, .allowBluetooth, .allowBluetoothA2DP]
            )
            try session.setActive(true)
            return true
        } catch {
            print("Failed to configure audio session: \(error)")
            return false
        }
#else
        return false
#endif
    }
}
