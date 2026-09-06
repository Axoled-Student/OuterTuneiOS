import SwiftUI
import UniformTypeIdentifiers

/// 正在播放 sheet。iOS 風格大卡片 + 操作列 + 可展開歌詞。
struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @ObservedObject private var aiDJ = AIDJService.shared
    @Environment(\.dismiss) private var dismiss

    /// Set when the view is hosted as a side panel rather than presented, so
    /// the chevron collapses the panel instead of dismissing a sheet.
    var onClose: (() -> Void)?

    /// Set alongside `onClose` to offer a full-screen control: a docked panel
    /// is a narrow column, and the artwork and lyrics deserve the whole width
    /// when the listener wants them.
    var onExpand: (() -> Void)?

    @State private var isImportPickerPresented: Bool = false
    @State private var showAdvancedSource: Bool = false
    @State private var isAudioInfoPresented: Bool = false
    @State private var isQueuePresented: Bool = false
    @State private var isLyricsFullScreen: Bool = false

    var body: some View {
        ZStack {
            ArtworkGradient(artworkURL: player.nowPlayingTrack?.displayThumbnailURL)

            if let track = player.nowPlayingTrack {
                GeometryReader { geometry in
                    let artSize = min(geometry.size.width - 56,
                                      geometry.size.height * 0.46)
                    ScrollView(showsIndicators: false) {
                        VStack(spacing: 0) {
                            topBar

                            Spacer(minLength: 18)

                            TrackArtworkView(
                                urlString: track.displayThumbnailURL,
                                dimension: max(artSize, 200),
                                cornerRadius: 10
                            )
                            .shadow(color: .black.opacity(0.45), radius: 24, y: 12)

                            Spacer(minLength: 26)

                            titleRow(track: track)
                                .padding(.horizontal, 28)

                            djLine
                                .padding(.horizontal, 28)

                            progressSlider
                                .padding(.horizontal, 24)
                                .padding(.top, 18)

                            primaryControls
                                .padding(.top, 12)

                            bottomBar(track: track)
                                .padding(.horizontal, 28)
                                .padding(.top, 22)

                            lyricsCard
                                .padding(.horizontal, 20)
                                .padding(.top, 26)

                            advancedSourceBlock
                                .padding(.horizontal, 20)

                            Color.clear.frame(height: 40)
                        }
                        .frame(minHeight: geometry.size.height)
                    }
                }
            } else {
                VStack(spacing: 12) {
                    topBar
                    Spacer()
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44))
                        .foregroundColor(AppTheme.textSecondary)
                    Text("尚未開始播放")
                        .foregroundColor(AppTheme.textSecondary)
                    Spacer()
                }
            }
        }
        .fileImporter(
            isPresented: $isImportPickerPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                player.importLocalAudioFiles(from: urls)
            case .failure(let error):
                player.statusMessage = "匯入失敗：\(error.localizedDescription)"
            }
        }
        .sheet(isPresented: $isAudioInfoPresented) {
            AudioSourceInfoSheetView()
                .environmentObject(player)
        }
        .sheet(isPresented: $isQueuePresented) {
            PlaybackQueueView()
                .environmentObject(player)
        }
        .fullScreenCover(isPresented: $isLyricsFullScreen) {
            LyricsFullScreenView()
                .environmentObject(player)
        }
    }

    // MARK: - Chrome

    private var topBar: some View {
        HStack {
            Button {
                if let onClose { onClose() } else { dismiss() }
            } label: {
                Image(systemName: onClose == nil ? "chevron.down" : "chevron.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
            }
            Spacer()
            Text("正在播放")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
                .textCase(.uppercase)
            Spacer()
            if let onExpand {
                Button(action: onExpand) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                }
                .padding(.trailing, 16)
            }
            Button { isAudioInfoPresented = true } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
    }

    /// What the station DJ is saying over this intro.
    ///
    /// Also the whole of the DJ when the server could write a line but not
    /// speak it, so this is not decoration - it is the fallback.
    @ViewBuilder
    private var djLine: some View {
        if let line = aiDJ.spokenLine, !line.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "waveform")
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.accent)
                    .padding(.top, 1)
                Text(line)
                    .font(.system(size: 13))
                    .foregroundColor(AppTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.top, 10)
            .transition(.opacity)
        }
    }

    private func titleRow(track: AppTrack) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(track.title)
                    .font(.system(size: 23, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(track.artist)
                    .font(.system(size: 15))
                    .foregroundColor(AppTheme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                player.toggleFavoriteForNowPlaying()
            } label: {
                Image(systemName: player.isFavorite(track)
                      ? "checkmark.circle.fill" : "plus.circle")
                    .font(.system(size: 24))
                    .foregroundColor(player.isFavorite(track)
                                     ? AppTheme.accent : AppTheme.textSecondary)
            }
        }
    }

    private func bottomBar(track _: AppTrack) -> some View {
        HStack {
            Button { player.seekBackward15() } label: {
                Image(systemName: "gobackward.15")
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.trailing, 18)
            Button { player.seekForward15() } label: {
                Image(systemName: "goforward.15")
                    .font(.system(size: 17))
                    .foregroundColor(AppTheme.textSecondary)
            }
            Spacer()
            Button { isLyricsFullScreen = true } label: {
                Image(systemName: "quote.bubble")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(.trailing, 18)
            Button { isQueuePresented = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16))
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
    }

    // MARK: - 子區塊

    private var progressSlider: some View {
        VStack(spacing: 6) {
            Slider(
                value: Binding(
                    get: { player.sliderPosition },
                    set: { player.updateScrubbing(position: $0) }
                ),
                in: 0 ... max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing {
                        player.beginScrubbing()
                    } else {
                        player.endScrubbing()
                    }
                }
            )
            .tint(AppTheme.textPrimary)

            HStack {
                Text(player.formattedTime(player.sliderPosition))
                Spacer()
                Text(player.formattedTime(player.duration))
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(AppTheme.textSecondary)
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 0) {
            Button { player.toggleShuffle() } label: {
                Image(systemName: "shuffle")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(player.isShuffleEnabled
                                     ? AppTheme.accent : AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)

            Button { player.playPrevious() } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30))
                    .foregroundColor(AppTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)

            Button { player.togglePlayback() } label: {
                ZStack {
                    Circle()
                        .fill(AppTheme.textPrimary)
                        .frame(width: 66, height: 66)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 27))
                        .foregroundColor(.black)
                }
            }
            .frame(maxWidth: .infinity)

            Button { player.playNext() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30))
                    .foregroundColor(AppTheme.textPrimary)
            }
            .frame(maxWidth: .infinity)

            Button { player.toggleRepeatMode() } label: {
                Image(systemName: player.repeatMode.systemImageName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(player.repeatMode.isEnabled
                                     ? AppTheme.accent : AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 18)
    }

    private var lyricsCard: some View {
        let lyrics = player.lyrics
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("歌詞")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                Spacer()
                if player.isLoadingLyrics {
                    ProgressView().tint(AppTheme.textSecondary)
                } else if lyrics.isSynced {
                    Text("點一行可跳轉")
                        .font(.caption2)
                        .foregroundColor(AppTheme.textSecondary)
                }
                Button { isLyricsFullScreen = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppTheme.textSecondary)
                }
                .padding(.leading, 10)
            }

            if lyrics.isSynced {
                SyncedLyricsView(lines: lyrics.lines,
                                 currentTime: player.currentTime,
                                 showsTranslation: player.lyricsTranslationEnabled) { time in
                    player.seekTo(time)
                }
                .frame(height: 190)
            } else if !lyrics.plain.isEmpty {
                Text(lyrics.plain)
                    .font(.footnote)
                    .foregroundColor(AppTheme.textSecondary)
            } else {
                Text(player.isLoadingLyrics ? "載入中…" : "找不到歌詞")
                    .font(.footnote)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.07))
        )
        .contentShape(Rectangle())
        .onTapGesture { if !lyrics.isSynced { isLyricsFullScreen = true } }
    }

    private var advancedSourceBlock: some View {
        DisclosureGroup(isExpanded: $showAdvancedSource) {
            VStack(alignment: .leading, spacing: 10) {
                TextField("https://example.com/audio.mp3", text: $player.streamURL)
                    .urlKeyboardIfAvailable()
                    .noAutoInputAdjustments()
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("以網址播放") { player.loadAndPlay() }
                        .buttonStyle(.bordered)

                    Button("匯入本機音訊") { isImportPickerPresented = true }
                        .buttonStyle(.bordered)
                }
            }
            .padding(.top, 8)
        } label: {
            Text("進階來源")
                .font(.subheadline)
                .fontWeight(.semibold)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
    }
}

/// The actual upcoming playback queue, including auto-generated tracks.
struct PlaybackQueueView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if player.queue.isEmpty {
                    Text("佇列是空的")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(player.queue.indices, id: \.self) { index in
                        let track = player.queue[index]
                        TrackRowView(
                            title: track.title,
                            subtitle: track.artist,
                            thumbnailURL: track.displayThumbnailURL,
                            onTap: { player.playQueueItem(at: index) }
                        ) {
                            if player.currentQueueIndex == index {
                                Image(systemName: player.isPlaying
                                      ? "speaker.wave.2.fill" : "pause.circle.fill")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .onDelete(perform: player.removeQueueItem)
                    .onMove(perform: player.moveQueueItem)
                }
            }
            .navigationTitle("播放佇列（\(player.queue.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}

/// 音訊資訊 / 品質切換。
struct AudioSourceInfoSheetView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    private var selectedStreamId: String? {
        player.nowPlayingStreamInfo?.id
    }

    var body: some View {
        NavigationView {
            List {
                Section("音質偏好") {
                    Picker("音質", selection: Binding(
                        get: { player.audioQualityPreference },
                        set: { player.setAudioQualityPreference($0) }
                    )) {
                        ForEach(AudioQualityPreference.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(player.audioQualityPreference.description)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("目前播放來源") {
                    if let stream = player.nowPlayingStreamInfo {
                        AudioInfoRow(label: "格式", value: stream.container)
                        AudioInfoRow(label: "位元率", value: stream.bitrateText)
                        if let codec = stream.codec, !codec.isEmpty {
                            AudioInfoRow(label: "編碼", value: codec)
                        }
                        if let audioQuality = stream.audioQuality, !audioQuality.isEmpty {
                            AudioInfoRow(label: "品質標籤", value: audioQuality)
                        }
                        if let itag = stream.itag {
                            AudioInfoRow(label: "itag", value: String(itag))
                        }
                        if let contentLength = stream.contentLength, contentLength > 0 {
                            AudioInfoRow(label: "大小", value: ByteCountFormatter.string(fromByteCount: contentLength, countStyle: .file))
                        }
                        AudioInfoRow(label: "來源客戶端", value: "\(stream.sourceClientName) \(stream.sourceClientVersion)")

                        VStack(alignment: .leading, spacing: 4) {
                            Text("URL")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(stream.url.absoluteString)
                                .font(.caption2)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("目前沒有可顯示的音訊來源資訊")
                            .foregroundColor(.secondary)
                    }
                }

                if !player.availableStreamOptions.isEmpty {
                    Section("可切換來源") {
                        ForEach(player.availableStreamOptions) { stream in
                            Button {
                                player.selectAudioStream(stream)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(stream.displayTitle)
                                            .font(.subheadline)
                                            .foregroundColor(.primary)
                                        Text(stream.shortDescription)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    if selectedStreamId == stream.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("音訊資訊")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") { dismiss() }
                }
            }
            .listStyle(.insetGrouped)
        }
        .navigationViewStyle(.stack)
    }
}
