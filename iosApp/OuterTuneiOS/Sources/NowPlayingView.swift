import SwiftUI
import UniformTypeIdentifiers

/// 正在播放 sheet。iOS 風格大卡片 + 操作列 + 可展開歌詞。
struct NowPlayingView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var isImportPickerPresented: Bool = false
    @State private var showAdvancedSource: Bool = false
    @State private var isAudioInfoPresented: Bool = false

    var body: some View {
        NavigationView {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.92, green: 0.52, blue: 0.56).opacity(0.28),
                        Color(red: 0.26, green: 0.43, blue: 0.72).opacity(0.18),
                        Color(.systemBackground)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 22) {
                        if let track = player.nowPlayingTrack {
                            TrackArtworkView(
                                urlString: track.thumbnailURL,
                                dimension: 300,
                                cornerRadius: 24
                            )

                            VStack(spacing: 6) {
                                Text(track.title)
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                Text(track.artist)
                                    .font(.title3)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }

                            Text(player.statusMessage)
                                .font(.footnote)
                                .foregroundColor(.secondary)

                            progressSlider

                            primaryControls

                            secondaryControls(track: track)

                            lyricsCard

                        } else {
                            VStack(spacing: 8) {
                                Image(systemName: "music.note.list")
                                    .font(.system(size: 44))
                                    .foregroundColor(.secondary)
                                Text("尚未開始播放")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.top, 60)
                        }

                        advancedSourceBlock
                    }
                    .padding(20)
                }
            }
            .navigationTitle("正在播放")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down")
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
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 子區塊

    private var progressSlider: some View {
        VStack(spacing: 8) {
            Slider(
                value: Binding(
                    get: { player.sliderPosition },
                    set: { player.updateScrubbing(position: $0) }
                ),
                in: 0...max(player.duration, 1),
                onEditingChanged: { editing in
                    if editing { player.beginScrubbing() } else { player.endScrubbing() }
                }
            )
            HStack {
                Text(player.formattedTime(player.sliderPosition))
                Spacer()
                Text(player.formattedTime(player.duration))
            }
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    private var primaryControls: some View {
        HStack(spacing: 42) {
            Button(action: player.playPrevious) {
                Image(systemName: "backward.fill")
                    .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(.plain)

            Button(action: player.togglePlayback) {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34, weight: .bold))
                    .frame(width: 86, height: 86)
                    .foregroundColor(.white)
                    .background(Circle().fill(Color.accentColor))
            }
            .buttonStyle(.plain)

            Button(action: player.playNext) {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .semibold))
            }
            .buttonStyle(.plain)
        }
    }

    private func secondaryControls(track: AppTrack) -> some View {
        HStack(spacing: 26) {
            Button(action: player.seekBackward15) {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(.plain)

            Button(action: player.seekForward15) {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(.plain)

            Button {
                player.toggleFavorite(track)
            } label: {
                Image(systemName: player.isFavorite(track) ? "heart.fill" : "heart")
            }
            .buttonStyle(.plain)

            Button(action: player.loadLyricsForCurrentTrack) {
                Image(systemName: "text.quote")
            }
            .buttonStyle(.plain)

            Button {
                isAudioInfoPresented = true
            } label: {
                Image(systemName: "info.circle")
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 22, weight: .medium))
    }

    private var lyricsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("歌詞")
                    .font(.headline)
                Spacer()
                if player.isLoadingLyrics { ProgressView() }
            }

            if player.lyricsText.isEmpty {
                Text("尚未載入")
                    .foregroundColor(.secondary)
            } else {
                Text(player.lyricsText)
                    .font(.footnote)
                    .lineLimit(8)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
        )
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
