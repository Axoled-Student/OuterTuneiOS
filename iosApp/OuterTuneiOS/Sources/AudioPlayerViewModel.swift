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
    @Published var repeatMode: RepeatMode = .off
    @Published var isShuffleEnabled: Bool = false
    /// When the queue runs dry, keep playing by appending recommendations.
    @Published var isAutoQueueEnabled: Bool = true
    @Published private(set) var isExtendingQueue: Bool = false

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

    /// 最近的 debug 日誌（環形緩衝），供用戶回報問題時複製
    @Published var recentDebugLogs: [String] = []
    // A single failed track can emit a dozen lines (one per candidate plus
    // per-attempt results), so 50 truncated the very context needed to debug it.
    private let maxDebugLogCount = 400

    /// Everything needed to diagnose a playback failure in one pasteable block.
    func diagnosticsReport() -> String {
        var lines: [String] = []
        lines.append("=== OuterTune iOS diagnostics ===")
        lines.append("generated: \(ISO8601DateFormatter().string(from: Date()))")

        let bundle = Bundle.main
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        lines.append("app: \(version) (\(build))")
#if os(iOS)
        lines.append("ios: \(UIDevice.current.systemVersion) \(UIDevice.current.model)")
#endif

        lines.append("youtube signed in: \(accountStore.isLoggedIn)")
        lines.append("stream resolver: configured=\(StreamResolverService.shared.isConfigured) "
            + "reachable=\(StreamResolverService.shared.isReachable.map(String.init) ?? "unknown")")
        lines.append("audio session: \(AudioSessionConfigurator.diagnostics)")
        lines.append("spotify linked: \(SpotifyService.shared.isAuthenticated)")
        lines.append("ai ranker configured: \(AIRankingService.shared.isConfigured)")
        lines.append("audio quality preference: \(audioQualityPreference.rawValue)")
        lines.append("repeat: \(repeatMode.rawValue), shuffle: \(isShuffleEnabled), "
            + "auto-queue: \(isAutoQueueEnabled)")
        lines.append("recommendation learning: \(autoQueueService.diagnostics)")
        lines.append("queue: \(queue.count) items, index: "
            + "\(currentQueueIndex.map(String.init) ?? "nil")")
        lines.append("isPlaying: \(isPlaying), duration: \(duration), time: \(currentTime)")

        if let track = nowPlayingTrack {
            lines.append("now playing: \(track.artist) - \(track.title) [\(track.stableId)]")
        }
        if let stream = nowPlayingStreamInfo {
            lines.append("stream: \(stream.sourceClientName) itag=\(stream.itag ?? -1) "
                + "\(stream.container) \(stream.bitrateText) "
                + "quality=\(stream.audioQuality ?? "?") hls=\(stream.isHLSManifest) "
                + "premium=\(stream.isPremiumFormat)")
            lines.append("stream host: \(stream.url.host ?? "?")")
        }

        lines.append("candidates: \(availableStreamOptions.count)")
        for (index, option) in availableStreamOptions.enumerated() {
            lines.append("  [\(index)] \(option.sourceClientName) itag=\(option.itag ?? -1) "
                + "\(option.container) \(option.bitrateText) "
                + "hls=\(option.isHLSManifest) premium=\(option.isPremiumFormat)")
        }

        lines.append("status: \(statusMessage)")
        lines.append("")
        lines.append("=== log (\(recentDebugLogs.count) lines) ===")
        lines.append(contentsOf: recentDebugLogs)
        return lines.joined(separator: "\n")
    }

    func appendDebugLog(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let entry = "[\(ts)] \(msg)"
        recentDebugLogs.append(entry)
        if recentDebugLogs.count > maxDebugLogCount {
            recentDebugLogs.removeFirst(recentDebugLogs.count - maxDebugLogCount)
        }
    }

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
    private let autoQueueService = AutoQueueService.shared
    private let resolverService = StreamResolverService.shared

    private let queueStorageKey = "ios.queue.v1"
    private let queueIndexStorageKey = "ios.queue.index.v1"
    private let downloadsStorageKey = "ios.downloads.v1"
    private let favoritesStorageKey = "ios.favorites.v1"
    private let historyStorageKey = "ios.history.v1"
    private let searchHistoryStorageKey = "ios.searchHistory.v1"
    private let audioQualityStorageKey = "ios.audioQualityPreference.v1"
    private let repeatModeStorageKey = "ios.repeatMode.v1"
    private let shuffleStorageKey = "ios.shuffle.v1"
    private let autoQueueStorageKey = "ios.autoQueue.v1"
    private let resumePositionStorageKey = "ios.playback.resumePosition.v1"
    private let resumeWasPlayingStorageKey = "ios.playback.wasPlaying.v1"

    private var searchHistory: [String] = []
    private var pendingLaunchResumePosition: Double?
    private var hasHandledLaunchResume = false
    private var nextPreloadTask: Task<Void, Never>?
    private var autoQueueTask: Task<Void, Never>?
    private var activeRecommendationGeneration: UUID?
    private var feedbackTrack: AppTrack?

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
        restorePlaybackModeState()
        restoreSearchHistoryState()
        autoQueueService.bootstrapHistory(playbackHistory)
        if UserDefaults.standard.bool(forKey: resumeWasPlayingStorageKey),
           currentQueueIndex != nil {
            pendingLaunchResumePosition = UserDefaults.standard.double(
                forKey: resumePositionStorageKey
            )
        }
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
            // Spotify-derived shelves go first: they reflect where the
            // listener's taste actually lives, whereas YouTube's own home feed
            // is personalised to the YouTube account.
            let personalized = await autoQueueService.personalizedHomeSections()
            let feed = try await youtubeService.fetchHomeFeed()
            homeFeed = HomeFeed(sections: personalized + feed.sections)
            print("[Home] refreshHomeFeed: OK, \(personalized.count) personalised + \(feed.sections.count) YouTube sections")
        } catch {
            // A YouTube failure must not discard shelves we already built.
            let personalized = await autoQueueService.personalizedHomeSections()
            if !personalized.isEmpty {
                homeFeed = HomeFeed(sections: personalized)
            }
            homeErrorMessage = "載入首頁失敗：\(error.localizedDescription)"
            appendDebugLog("首頁失敗: \(error)")
            print("[Home] refreshHomeFeed FAILED: \(error)")
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
        nextPreloadTask?.cancel()
        autoQueueTask?.cancel()
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

    /// A home song is a radio seed, not a one-item queue. Start building its
    /// personalised tail immediately so the queue is visible while the first
    /// track is still resolving/buffering.
    func playHomeTrack(_ track: AppTrack) {
        Task {
            await replaceQueueAndPlay(
                tracks: [track],
                startingAt: 0,
                generateRecommendationsImmediately: true
            )
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

    func playPlaylist(_ songs: [YouTubeSearchSong], startingAt index: Int = 0) {
        let tracks = songs.map { $0.asTrack() }
        guard tracks.indices.contains(index) else { return }
        Task {
            await replaceQueueAndPlay(tracks: tracks, startingAt: index)
        }
    }

    func enqueuePlaylist(_ songs: [YouTubeSearchSong]) {
        let tracks = songs.map { $0.asTrack() }
        guard !tracks.isEmpty else { return }
        queue.append(contentsOf: tracks)
        persistQueueState()
        statusMessage = "已加入 \(tracks.count) 首歌曲"
        if let currentQueueIndex {
            preloadNextTrack(after: currentQueueIndex)
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
        guard let currentQueueIndex else { return }

        let nextIndex = currentQueueIndex + 1
        if nextIndex < queue.count {
            playQueueItem(at: nextIndex)
            return
        }

        if repeatMode == .all, !queue.isEmpty {
            playQueueItem(at: 0)
            return
        }

        if isAutoQueueEnabled {
            scheduleAutoQueueExtension(startPlaying: true)
        }
    }

    func playPrevious() {
        // Match the platform convention: past the first few seconds, "previous"
        // restarts the current track instead of leaving it.
        if currentTime > 3, currentQueueIndex != nil {
            seek(to: 0)
            return
        }

        guard let currentQueueIndex else { return }

        if currentQueueIndex - 1 >= 0 {
            playQueueItem(at: currentQueueIndex - 1)
            return
        }

        if repeatMode == .all, !queue.isEmpty {
            playQueueItem(at: queue.count - 1)
            return
        }

        seek(to: 0)
    }

    func toggleRepeatMode() {
        repeatMode = repeatMode.next
        persistPlaybackModeState()
        statusMessage = "循環模式：\(repeatMode.rawValue)"
    }

    func toggleShuffle() {
        isShuffleEnabled.toggle()
        persistPlaybackModeState()

        guard isShuffleEnabled else {
            statusMessage = "隨機播放：關閉"
            return
        }

        // Shuffle only what has not been played yet, so the current track keeps
        // its position and history stays meaningful.
        guard let index = currentQueueIndex, index + 1 < queue.count else {
            statusMessage = "隨機播放：開啟"
            return
        }

        let head = Array(queue[...index])
        let tail = Array(queue[(index + 1)...]).shuffled()
        queue = head + tail
        persistQueueState()
        statusMessage = "隨機播放：開啟"
    }

    func setAutoQueueEnabled(_ enabled: Bool) {
        isAutoQueueEnabled = enabled
        persistPlaybackModeState()
        statusMessage = enabled ? "自動佇列：開啟" : "自動佇列：關閉"
    }

    /// Called when the current item reaches its end and the queue should move on.
    private func advanceAfterPlaybackEnded() {
        guard let index = currentQueueIndex else {
            isPlaying = false
            updateNowPlayingPlaybackState()
            return
        }

        let nextIndex = index + 1
        if nextIndex < queue.count {
            playQueueItem(at: nextIndex)
            return
        }

        if repeatMode == .all, !queue.isEmpty {
            playQueueItem(at: 0)
            return
        }

        if isAutoQueueEnabled {
            scheduleAutoQueueExtension(startPlaying: true)
            return
        }

        isPlaying = false
        player?.seek(to: .zero)
        statusMessage = "播放完成"
        updateNowPlayingPlaybackState()
    }

    /// Append recommendations based on what is playing and optionally continue
    /// straight into them. Holds a background assertion because this runs at the
    /// exact moment audio has stopped.
    func extendQueueWithRecommendations(startPlaying: Bool) async {
        guard let seed = nowPlayingTrack ?? queue.last else {
            isPlaying = false
            updateNowPlayingPlaybackState()
            return
        }

        let generation = UUID()
        activeRecommendationGeneration = generation
        isExtendingQueue = true
        defer {
            if activeRecommendationGeneration == generation {
                activeRecommendationGeneration = nil
                isExtendingQueue = false
            }
        }

        statusMessage = "尋找相似歌曲..."
        let existing = Set(queue.map(\.stableId))
        let suggestions = await withBackgroundActivity("auto-queue") {
            await autoQueueService.recommendations(
                seed: seed,
                excluding: existing,
                limit: 20
            )
        }

        guard !Task.isCancelled,
              activeRecommendationGeneration == generation,
              nowPlayingTrack?.stableId == seed.stableId else {
            appendDebugLog("自動佇列：捨棄過期推薦（seed=\(seed.title)）")
            return
        }

        let currentIds = Set(queue.map(\.stableId))
        let freshSuggestions = suggestions.filter { !currentIds.contains($0.stableId) }
        guard !freshSuggestions.isEmpty else {
            appendDebugLog("自動佇列：找不到推薦（seed=\(seed.title)）")
            if startPlaying {
                isPlaying = false
                statusMessage = "播放完成"
                persistPlaybackResumeState()
                updateNowPlayingPlaybackState()
            }
            return
        }

        let insertionIndex = queue.count
        queue.append(contentsOf: freshSuggestions)
        persistQueueState()
        statusMessage = "已加入 \(freshSuggestions.count) 首推薦歌曲"

        if startPlaying {
            playQueueItem(at: insertionIndex)
        } else {
            preloadTrack(at: insertionIndex)
        }
    }

    private func persistPlaybackModeState() {
        UserDefaults.standard.set(repeatMode.rawValue, forKey: repeatModeStorageKey)
        UserDefaults.standard.set(isShuffleEnabled, forKey: shuffleStorageKey)
        UserDefaults.standard.set(isAutoQueueEnabled, forKey: autoQueueStorageKey)
    }

    private func persistPlaybackResumeState() {
        UserDefaults.standard.set(max(currentTime, 0), forKey: resumePositionStorageKey)
        UserDefaults.standard.set(isPlaying, forKey: resumeWasPlayingStorageKey)
    }

    private func restorePlaybackModeState() {
        if let raw = UserDefaults.standard.string(forKey: repeatModeStorageKey),
           let restored = RepeatMode(rawValue: raw) {
            repeatMode = restored
        }
        isShuffleEnabled = UserDefaults.standard.bool(forKey: shuffleStorageKey)
        if UserDefaults.standard.object(forKey: autoQueueStorageKey) != nil {
            isAutoQueueEnabled = UserDefaults.standard.bool(forKey: autoQueueStorageKey)
        }
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
        persistPlaybackResumeState()
        updateNowPlayingPlaybackState()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        statusMessage = "已暫停"
        persistPlaybackResumeState()
        updateNowPlayingPlaybackState()
    }

    /// Keep the playback session alive across ordinary Home-screen/background
    /// transitions, and restore an item automatically after a process relaunch.
    /// iOS still terminates audio when the user explicitly force-quits the app;
    /// the saved item resumes as soon as the app is opened again.
    func handleScenePhase(_ phase: ScenePhase) {
        let configured = AudioSessionConfigurator.configureForPlayback()
        appendDebugLog("場景狀態：\(String(describing: phase)) audioSession=\(configured)")

        switch phase {
        case .active:
            if !hasHandledLaunchResume {
                hasHandledLaunchResume = true
                if pendingLaunchResumePosition != nil,
                   let index = currentQueueIndex,
                   queue.indices.contains(index) {
                    Task { await self.playTrack(at: index) }
                    return
                }
            }
            if isPlaying {
                player?.play()
                updateNowPlayingPlaybackState()
            }
        case .inactive, .background:
            persistPlaybackResumeState()
            if isPlaying {
                player?.play()
            }
        @unknown default:
            break
        }
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
        await replaceQueueAndPlay(tracks: [track], startingAt: 0)
    }

    private func replaceQueueAndPlay(
        tracks: [AppTrack],
        startingAt index: Int,
        generateRecommendationsImmediately: Bool = false
    ) async {
        guard tracks.indices.contains(index) else { return }
        cancelAutoQueueGeneration()
        nextPreloadTask?.cancel()
        queue = tracks
        currentQueueIndex = index
        persistQueueState()
        if generateRecommendationsImmediately {
            scheduleAutoQueueExtension(startPlaying: false)
        }
        await playTrack(
            at: index,
            autoQueueAlreadyScheduled: generateRecommendationsImmediately
        )
    }

    private func playTrack(at index: Int, autoQueueAlreadyScheduled: Bool = false) async {
        guard index >= 0, index < queue.count else { return }
        // Resolving streams and downloading them happens while nothing is
        // rendering, and the `audio` background mode only protects us while
        // audio is actually playing. Without this assertion iOS suspends the
        // process mid-transition and playback never resumes - the single
        // biggest cause of "it stops when I leave the app".
        BackgroundActivityGuard.shared.begin("play-track")
        defer { BackgroundActivityGuard.shared.end() }

        let track = queue[index]
        finishListeningIfChanging(to: track)
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

            print("[Player] playTrack: resolved \(playbackCandidates.count) candidates for \(track.title)")
            appendDebugLog("解析完成[\(track.title)]：\(playbackCandidates.count) 個候選，"
                + "登入=\(accountStore.isLoggedIn)，音質偏好=\(audioQualityPreference.rawValue)")
            for (i, c) in playbackCandidates.enumerated() {
                print("[Player]   [\(i)] \(c.sourceClientName) HLS=\(c.isHLSManifest) itag=\(c.itag ?? 0) \(c.container ?? "?") \(c.audioQuality ?? "?")")
                appendDebugLog("  候選[\(i)] \(c.sourceClientName) itag=\(c.itag ?? 0) "
                    + "\(c.container) \(c.bitrateText) HLS=\(c.isHLSManifest) "
                    + "premium=\(c.isPremiumFormat)")
            }

            guard !playbackCandidates.isEmpty else {
                throw YouTubeMusicServiceError.noPlayableStream
            }

            startPlaybackAttempt(track: track)
            trackDidStartPlaying(track)

            // Build the tail while this track is still rendering. Waiting for
            // DidPlayToEnd leaves a silent network gap where iOS may suspend a
            // backgrounded app before recommendations finish loading.
            if isAutoQueueEnabled,
               !autoQueueAlreadyScheduled,
               index == queue.count - 1 {
                scheduleAutoQueueExtension(startPlaying: false)
            } else {
                preloadNextTrack(after: index)
            }
        } catch {
            isPlaying = false
            playbackCandidates = []
            availableStreamOptions = []
            nowPlayingStreamInfo = nil
            statusMessage = "播放失敗：\(error.localizedDescription)"
            appendDebugLog("播放失敗[\(track.title)]: \(error)")
            persistPlaybackResumeState()
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
                    sourceUserAgent: nil,
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
            var options: [AudioStreamOption] = []

            // A configured resolver is the only full-track source. Do not hide
            // an auth/network failure by falling through to a googlevideo URL:
            // that path is capped or rejected and creates silent, bad-duration
            // files after remuxing.
            if resolverService.isConfigured {
                let viaResolver = try await resolverService.playbackOption(for: videoId)
                options.append(viaResolver)
                appendDebugLog("使用串流伺服器：itag=\(viaResolver.itag ?? -1) "
                    + "\(viaResolver.bitrateText)")
                return options
            }

            let direct = try await youtubeService.resolveAudioStreams(videoId: videoId)
            options.append(contentsOf: prioritizePlaybackCandidates(direct))

            guard !options.isEmpty else {
                throw YouTubeMusicServiceError.noPlayableStream
            }
            return options
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
                        sourceUserAgent: nil,
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
            print("[Player] startPlaybackAttempt: no candidates at index \(playbackCandidateIndex)")
            updateNowPlayingPlaybackState()
            return
        }

        let selectedStream = playbackCandidates[playbackCandidateIndex]
        nowPlayingStreamInfo = selectedStream
        streamURL = selectedStream.url.absoluteString
        appendDebugLog("嘗試候選 \(playbackCandidateIndex + 1)/\(playbackCandidates.count)："
            + "\(selectedStream.sourceClientName) itag=\(selectedStream.itag ?? 0) "
            + "\(selectedStream.bitrateText) host=\(selectedStream.url.host ?? "?")")
        print("[Player] startPlaybackAttempt: idx=\(playbackCandidateIndex)/\(playbackCandidates.count), client=\(selectedStream.sourceClientName), HLS=\(selectedStream.isHLSManifest), itag=\(selectedStream.itag ?? 0), container=\(selectedStream.container ?? "?")")

        // HLS manifests and local/direct files can be played directly by AVPlayer.
        // NOTE: RESOLVER proxies YouTube's DASH fMP4 (Premium itag 141 when
        // available, otherwise itag 140). CoreMedia/AVPlayer cannot stream it
        // directly over plain HTTP, so download and remux it first.
        if selectedStream.isHLSManifest
            || !selectedStream.requiresRemux
            || selectedStream.sourceClientName == "LOCAL"
            || selectedStream.sourceClientName == "DIRECT" {
            playItemDirectly(url: selectedStream.url, track: track)
            return
        }

        // YouTube adaptive streams are DASH fMP4 — CoreMedia can't play them directly.
        // Download the complete stream, remux to standard M4A, then play from temp file.
        statusMessage = "下載串流中..."
        let streamToDownload = selectedStream
        Task { [weak self] in
            guard let self else { return }
            // This outlives playTrack's own assertion, so it takes its own.
            BackgroundActivityGuard.shared.begin("stream-download")
            defer { BackgroundActivityGuard.shared.end() }
            do {
                guard await self.validateStream(streamToDownload) else {
                    await MainActor.run {
                        guard self.activePlaybackTrackStableId == track.stableId else { return }
                        if !self.tryFallbackPlaybackIfNeeded(for: track) {
                            self.statusMessage = "播放失敗：所有串流來源皆無法存取"
                            self.isPlaying = false
                        }
                    }
                    return
                }
                let localURL = try await self.downloadAndRemux(stream: streamToDownload)
                await MainActor.run {
                    guard self.activePlaybackTrackStableId == track.stableId,
                          self.playbackCandidates.indices.contains(self.playbackCandidateIndex),
                          self.playbackCandidates[self.playbackCandidateIndex].id == streamToDownload.id else {
                        return // Track changed while downloading
                    }
                    self.playItemDirectly(url: localURL, track: track)
                }
            } catch {
                await MainActor.run {
                    guard self.activePlaybackTrackStableId == track.stableId else { return }
                    print("[Player] Download+remux failed: \(error.localizedDescription), trying fallback")
                    self.appendDebugLog("下載+remux失敗[itag=\(streamToDownload.itag ?? 0), \(streamToDownload.sourceClientName)]: \(error.localizedDescription)")
                    if !self.tryFallbackPlaybackIfNeeded(for: track) {
                        self.statusMessage = "播放失敗：\(error.localizedDescription)"
                        self.isPlaying = false
                    }
                }
            }
        }
    }

    private func playItemDirectly(url: URL, track: AppTrack) {
        let item = AVPlayerItem(url: url)
        // Everything reaching this point is either a local file or an HLS
        // manifest. For a file already on disk there is nothing to buffer, so
        // waiting to minimise stalling only delays the first sample.
        if url.isFileURL {
            item.preferredForwardBufferDuration = 0
        }
        if player == nil {
            player = AVPlayer(playerItem: item)
            installPeriodicTimeObserver()
        } else {
            player?.replaceCurrentItem(with: item)
        }
        player?.automaticallyWaitsToMinimizeStalling = !url.isFileURL

        currentTime = 0
        sliderPosition = 0
        duration = nowPlayingStreamInfo?.duration
            ?? inferredFallbackDuration(for: track, streamURL: url)
            ?? 0
        lyricsText = ""

        observePlayerItemState(item: item, track: track)
        observePlaybackEnd(item: item)
        player?.isMuted = false
        player?.volume = 1.0

        if let resumePosition = pendingLaunchResumePosition {
            pendingLaunchResumePosition = nil
            let bounded = duration > 0 ? min(resumePosition, duration) : resumePosition
            let target = max(bounded, 0)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600))
            currentTime = target
            sliderPosition = target
        }

        player?.play()
        isPlaying = true
        persistPlaybackResumeState()
        updateNowPlayingInfo(for: track)

        if playbackCandidateIndex == 0 {
            statusMessage = "緩衝中：\(track.title)"
        } else {
            statusMessage = "切換備援串流 \(playbackCandidateIndex + 1)/\(playbackCandidates.count)..."
        }
    }

    /// 專用於串流下載的 URLSession，不帶 cookie（避免登入 cookie 與 IOS/ANDROID_VR 串流 URL 身份衝突導致 403）
    private static let streamDownloadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    /// Cheap liveness check before committing to a whole-file download.
    ///
    /// Ported from the Android client's `validateStatus`. Without it a dead URL
    /// is only discovered after downloading the entire track, which both wastes
    /// the transfer and delays the fallback. It matters more here than on
    /// Android because YouTube expires IOS-client stream URLs aggressively -
    /// the upstream project notes "recent api changes produce error 403 after
    /// 30 seconds" - so a URL can rot between resolution and playback.
    private func validateStream(_ stream: AudioStreamOption) async -> Bool {
        guard !stream.isHLSManifest, !stream.url.isFileURL else { return true }

        var request = URLRequest(url: stream.url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("bytes=0-1", forHTTPHeaderField: "Range")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("", forHTTPHeaderField: "Cookie")
        if let userAgent = stream.sourceUserAgent, !userAgent.isEmpty {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }

        do {
            let (_, response) = try await Self.streamDownloadSession.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            let ok = (200 ... 206).contains(http.statusCode)
            if !ok {
                appendDebugLog("串流驗證失敗：itag=\(stream.itag ?? 0) "
                    + "\(stream.sourceClientName) HTTP \(http.statusCode)")
            }
            return ok
        } catch {
            appendDebugLog("串流驗證錯誤：itag=\(stream.itag ?? 0) "
                + "\(error.localizedDescription)")
            return false
        }
    }

    /// Download a YouTube adaptive stream and remux from DASH fMP4 to standard M4A.
    private func downloadAndRemux(stream: AudioStreamOption) async throws -> URL {
        var request = URLRequest(url: stream.url)
        request.httpShouldHandleCookies = false

        // 顯式設定 headers，防止 iOS 系統層注入意外的值
        if let ua = stream.sourceUserAgent, !ua.isEmpty {
            request.setValue(ua, forHTTPHeaderField: "User-Agent")
        }
        request.setValue("", forHTTPHeaderField: "Cookie")           // 強制清空 cookie
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding") // 不要 gzip
        request.setValue("bytes=0-", forHTTPHeaderField: "Range")    // yt-dlp 風格 range 請求

        // 清除 HTTPCookieStorage.shared 中可能汙染此請求的 cookies
        if let cookies = HTTPCookieStorage.shared.cookies(for: stream.url) {
            for c in cookies { HTTPCookieStorage.shared.deleteCookie(c) }
        }

        // 記錄實際發送的 headers 方便診斷
        let reqHeaders = request.allHTTPHeaderFields ?? [:]
        let sharedCookies = HTTPCookieStorage.shared.cookies(for: stream.url)?.map(\.name) ?? []
        appendDebugLog("[DL] itag=\(stream.itag ?? 0) client=\(stream.sourceClientName) sharedCookies=\(sharedCookies) reqHeaders=\(reqHeaders)")
        print("[Player] downloadAndRemux: itag=\(stream.itag ?? 0), client=\(stream.sourceClientName), reqHeaders=\(reqHeaders), sharedCookies=\(sharedCookies)")
        print("[Player] downloadAndRemux: url=\(stream.url.absoluteString.prefix(200))...")

        let (data, response) = try await Self.streamDownloadSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            print("[Player] downloadAndRemux: response is not HTTPURLResponse")
            throw YouTubeMusicServiceError.invalidResponse
        }

        // 記錄回應 headers（尤其 403 時的診斷資訊）
        let respHeaders = httpResponse.allHeaderFields as? [String: Any] ?? [:]
        print("[Player] downloadAndRemux: HTTP \(httpResponse.statusCode), respHeaders=\(respHeaders)")

        guard (200...206).contains(httpResponse.statusCode) else {
            let bodyPreview = String(data: data.prefix(300), encoding: .utf8) ?? "(binary)"
            appendDebugLog("[DL] FAIL HTTP \(httpResponse.statusCode) itag=\(stream.itag ?? 0) body=\(bodyPreview.prefix(150)) respHeaders=\(respHeaders)")
            print("[Player] downloadAndRemux: HTTP \(httpResponse.statusCode), body=\(bodyPreview.prefix(200))")
            throw YouTubeMusicServiceError.httpError(
                statusCode: httpResponse.statusCode,
                endpoint: "stream/itag=\(stream.itag ?? 0)",
                bodyPreview: String(bodyPreview.prefix(100))
            )
        }

        if let expected = stream.contentLength,
           expected > 0,
           Int64(data.count) < expected {
            appendDebugLog("[DL] TRUNCATED itag=\(stream.itag ?? 0) "
                + "expected=\(expected) actual=\(data.count)")
            throw YouTubeMusicServiceError.incompleteStream(
                expected: expected,
                actual: Int64(data.count)
            )
        }
        appendDebugLog("[DL] OK HTTP \(httpResponse.statusCode) itag=\(stream.itag ?? 0) bytes=\(data.count)")
        print("[Player] downloadAndRemux: downloaded \(data.count) bytes")

        guard let remuxedData = DashRemuxer.remux(data) else {
            throw YouTubeMusicServiceError.noPlayableStream
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "remuxed_\(stream.itag ?? 0)_\(UUID().uuidString.prefix(8)).m4a"
        let tempURL = tempDir.appendingPathComponent(fileName)
        try remuxedData.write(to: tempURL)

        return tempURL
    }

    private func tryFallbackPlaybackIfNeeded(for track: AppTrack) -> Bool {
        guard activePlaybackTrackStableId == track.stableId else {
            print("[Player] tryFallback: track changed, skipping")
            return false
        }

        let nextIndex = playbackCandidateIndex + 1
        guard playbackCandidates.indices.contains(nextIndex) else {
            print("[Player] tryFallback: no more candidates (was \(playbackCandidateIndex)/\(playbackCandidates.count))")
            appendDebugLog("所有 \(playbackCandidates.count) 個候選皆失敗，無法播放")
            return false
        }

        playbackCandidateIndex = nextIndex
        player?.pause()
        _ = AudioSessionConfigurator.configureForPlayback()
        startPlaybackAttempt(track: track)
        return true
    }

    /// Warm the PC-side fast-start M4A cache for the next YouTube item. The
    /// task is deliberately best-effort and never changes visible playback
    /// state; /stream prepares on demand if this did not finish in time.
    private func preloadNextTrack(after index: Int) {
        preloadTrack(at: index + 1)
    }

    private func scheduleAutoQueueExtension(startPlaying: Bool) {
        autoQueueTask?.cancel()
        autoQueueTask = Task { [weak self] in
            await self?.extendQueueWithRecommendations(startPlaying: startPlaying)
        }
    }

    private func cancelAutoQueueGeneration() {
        autoQueueTask?.cancel()
        autoQueueTask = nil
        activeRecommendationGeneration = nil
        isExtendingQueue = false
    }

    private func preloadTrack(at index: Int) {
        guard resolverService.isConfigured, queue.indices.contains(index) else { return }
        guard case .youtube(let videoId) = queue[index].source else { return }

        let title = queue[index].title
        nextPreloadTask?.cancel()
        nextPreloadTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.resolverService.prepare(videoId: videoId)
                guard !Task.isCancelled else { return }
                self.appendDebugLog("預載完成：\(title)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                self.appendDebugLog("預載失敗[\(title)]：\(error.localizedDescription)")
            }
        }
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
                    let failErr = observedItem.error
                    print("[Player] AVPlayerItem FAILED: \(failErr?.localizedDescription ?? "unknown"), idx=\(self.playbackCandidateIndex)/\(self.playbackCandidates.count)")
                    self.appendDebugLog("AVPlayer 失敗[候選 \(self.playbackCandidateIndex + 1)]："
                        + "\(self.describePlaybackFailure(from: observedItem))")
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

                if let feedbackTrack = self.feedbackTrack {
                    self.autoQueueService.recordFinished(
                        feedbackTrack,
                        listenedSeconds: self.currentTime,
                        duration: self.duration,
                        completed: true
                    )
                    self.feedbackTrack = nil
                }
                self.currentTime = 0
                self.sliderPosition = 0

                // Repeat-one restarts the same item without touching the queue.
                if self.repeatMode == .one {
                    self.player?.seek(to: .zero)
                    self.player?.play()
                    self.isPlaying = true
                    if let track = self.nowPlayingTrack {
                        self.trackDidStartPlaying(track)
                    }
                    self.updateNowPlayingPlaybackState()
                    return
                }

                guard self.shouldAutoPlayNext else {
                    self.isPlaying = false
                    self.player?.seek(to: .zero)
                    self.statusMessage = "播放完成"
                    self.updateNowPlayingPlaybackState()
                    return
                }

                // Deliberately leave `isPlaying` true across the handover.
                // Flipping it to false here published a paused state to the lock
                // screen and Control Center on every track change, and told the
                // system the session had gone idle at the exact moment we still
                // needed it alive to load the next track.
                self.advanceAfterPlaybackEnded()
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

        // Headphone and steering-wheel controls send togglePlayPause rather than
        // discrete play/pause, so without this a single-press control does
        // nothing at all.
        commandCenter.togglePlayPauseCommand.isEnabled = true
        commandCenter.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.togglePlayback() }
            return .success
        }

        commandCenter.stopCommand.isEnabled = true
        commandCenter.stopCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.pause() }
            return .success
        }

        // Music controls should show previous/next track, not podcast-style
        // 15-second buttons. nextTrackCommand/previousTrackCommand above remain
        // enabled for Lock Screen, Control Center, headphones, and CarPlay.
        commandCenter.skipForwardCommand.isEnabled = false
        commandCenter.skipBackwardCommand.isEnabled = false

        // Seeking by scrubbing on some accessories uses the rating/like slot;
        // leave those disabled so they do not appear as dead controls.
        commandCenter.ratingCommand.isEnabled = false
        commandCenter.likeCommand.isEnabled = false
        commandCenter.dislikeCommand.isEnabled = false

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
                    // AVPlayer is usually stopped for us, but not always (and not
                    // at all for a route we own). Pausing explicitly keeps our
                    // published state and the actual player in agreement.
                    self.player?.pause()
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
        // Premium formats (itag 141 / 774) are the reason to sign in with a
        // Music Premium account at all, so they outrank the instant-start HLS
        // manifest whenever the user has not explicitly asked for a lower tier.
        // They cost one download+remux before playback starts; that trade is
        // worth roughly double the bitrate (279kbps vs 143kbps, measured).
        let premium = candidates.filter { $0.isPremiumFormat }
        let hls = candidates.filter { !$0.isPremiumFormat && $0.isHLSManifest }
        let adaptive = candidates.filter { !$0.isPremiumFormat && !$0.isHLSManifest }

        // Premium formats only reach this point if they carry a usable URL;
        // ciphered ones are dropped during resolution because they always 403.
        if audioQualityPreference == .high || audioQualityPreference == .auto {
            if !premium.isEmpty {
                return premium + hls + adaptive
            }
        }

        guard audioQualityPreference != .auto else {
            // Auto favours the HLS manifest: it starts instantly with no
            // download+remux, and adapts on its own.
            return hls + adaptive + premium
        }

        let knownBitrate = adaptive.enumerated().filter { (_, stream) in
            guard let bitrate = stream.effectiveBitrate else {
                return false
            }
            return bitrate > 0
        }

        let unknownBitrate = adaptive.enumerated().filter { (_, stream) in
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

        // For an explicit quality preference the ranked adaptive streams come
        // first. Leading with HLS meant "high" silently played an adaptive
        // ladder of unknown bitrate instead of the best stream on offer.
        if audioQualityPreference == .high {
            return sortedKnown.map(\.element) + hls + unknownBitrate.map(\.element)
        }
        return hls + sortedKnown.map(\.element) + unknownBitrate.map(\.element)
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
        if feedbackTrack?.stableId != track.stableId {
            feedbackTrack = track
            autoQueueService.recordStarted(track)
        }

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

    /// A transition before natural end is a skip signal. Long/near-complete
    /// listens remain neutral or positive inside recordFinished, while early
    /// skips lower the track/artist affinity used by auto-queue.
    private func finishListeningIfChanging(to nextTrack: AppTrack) {
        guard let previous = feedbackTrack,
              previous.stableId != nextTrack.stableId else { return }
        autoQueueService.recordFinished(
            previous,
            listenedSeconds: currentTime,
            duration: duration,
            completed: false
        )
        feedbackTrack = nil
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
    private(set) static var diagnostics = "not configured"

    @discardableResult
    static func configureForPlayback() -> Bool {
#if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            // `.allowBluetooth` opts the session into HFP, a mono voice profile.
            // Requesting it on a playback-only session can drag a Bluetooth route
            // down to call quality, so a music player wants A2DP + AirPlay only.
            // `.playback` is the category that explicitly ignores the Ring/
            // Silent switch and remains eligible for the `audio` background
            // mode. Use the canonical overload here; route-sharing policy is
            // not required for either behavior and failed on some sideloaded
            // device/OS combinations.
            let wantedOptions: AVAudioSession.CategoryOptions = [
                .allowAirPlay,
                .allowBluetoothA2DP,
            ]
            if session.category != .playback
                || session.mode != .default
                || !session.categoryOptions.isSuperset(of: wantedOptions) {
                try session.setCategory(
                    .playback,
                    mode: .default,
                    options: wantedOptions
                )
            }
            try session.setActive(true, options: [])
            let outputs = session.currentRoute.outputs
                .map { "\($0.portType.rawValue):\($0.portName)" }
                .joined(separator: ",")
            diagnostics = "ok category=\(session.category.rawValue) "
                + "mode=\(session.mode.rawValue) route=\(outputs)"
            return true
        } catch {
            diagnostics = "failed: \(error.localizedDescription)"
            print("Failed to configure audio session: \(error)")
            return false
        }
#else
        diagnostics = "not iOS"
        return false
#endif
    }
}
