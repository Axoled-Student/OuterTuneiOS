import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var player = AudioPlayerViewModel()

    var body: some View {
        TabView {
            HomeTabView()
                .tabItem {
                    Label("首頁", systemImage: "house")
                }

            SearchTabView()
                .tabItem {
                    Label("搜尋", systemImage: "magnifyingglass")
                }

            LibraryTabView()
                .tabItem {
                    Label("資料庫", systemImage: "books.vertical")
                }

            PlayerTabView()
                .tabItem {
                    Label("播放中", systemImage: "play.circle")
                }

            SettingsTabView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
        .environmentObject(player)
    }
}

private struct HomeTabView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel

    var body: some View {
        NavigationView {
            List {
                Section("目前狀態") {
                    if let track = player.nowPlayingTrack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(track.title)
                                .font(.headline)
                            Text(track.artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(player.statusMessage)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("尚未開始播放")
                            .foregroundColor(.secondary)
                    }
                }

                Section("快速操作") {
                    Button(player.isPlaying ? "暫停" : "播放") {
                        player.togglePlayback()
                    }
                    Button("下一首") {
                        player.playNext()
                    }
                    Button("上一首") {
                        player.playPrevious()
                    }
                }

                Section("佇列概覽") {
                    Text("佇列歌曲：\(player.queue.count)")
                    if let current = player.currentQueueIndex {
                        Text("目前索引：\(current + 1)")
                    }
                }
            }
            .navigationTitle("OuterTune")
        }
    }
}

private struct SearchTabView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                HStack {
                    TextField("搜尋 YouTube Music", text: $player.searchQuery)
                        .textFieldStyle(.roundedBorder)
                        .noAutoInputAdjustments()

                    Button("搜尋") {
                        Task {
                            await player.searchYouTube()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.horizontal)
                .padding(.top, 8)

                if player.isSearching {
                    ProgressView("搜尋中...")
                        .padding(.bottom, 8)
                }

                List(player.searchResults) { song in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .top, spacing: 10) {
                            AsyncImage(url: URL(string: song.thumbnailURL ?? "")) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                Color.gray.opacity(0.2)
                            }
                            .frame(width: 54, height: 54)
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(song.title)
                                    .font(.headline)
                                    .lineLimit(2)
                                Text(song.artist)
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                if let duration = song.durationText {
                                    Text(duration)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }

                        HStack {
                            Button("播放") {
                                player.playSearchResult(song)
                            }
                            .buttonStyle(.borderedProminent)

                            Button("加入佇列") {
                                player.enqueueSearchResult(song)
                            }
                            .buttonStyle(.bordered)

                            if player.isDownloading(song) {
                                ProgressView()
                                    .frame(width: 24, height: 24)
                            } else {
                                Button("下載") {
                                    player.downloadSearchResult(song)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .listStyle(.plain)
            }
            .navigationTitle("線上搜尋")
        }
    }
}

private struct LibraryTabView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel

    var body: some View {
        NavigationView {
            List {
                Section("移植進度") {
                    Text("線上搜尋")
                    Text("播放佇列")
                    Text("歌詞抓取")
                    Text("離線下載")
                    Text("本機音訊匯入")
                    Text("收藏與歷史")
                    Text("設定儲存")
                }

                Section("已下載與本機") {
                    if player.downloadedTracks.isEmpty {
                        Text("目前沒有資料")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(player.downloadedTracks) { track in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(track.title)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)

                                HStack {
                                    Button("播放") {
                                        player.playDownloadedTrack(track)
                                    }
                                    .buttonStyle(.borderedProminent)

                                    Button("加入佇列") {
                                        player.enqueueTrack(track, status: "已加入佇列")
                                    }
                                    .buttonStyle(.bordered)

                                    Button("刪除") {
                                        player.removeDownloadedTrack(track)
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                Section("收藏") {
                    if player.favoriteTracks.isEmpty {
                        Text("尚未收藏歌曲")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(player.favoriteTracks) { track in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("播放") {
                                    player.playDownloadedTrack(track)
                                }
                                .buttonStyle(.bordered)
                                Button("移除") {
                                    player.removeFavorite(track)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }

                Section("最近播放") {
                    if player.playbackHistory.isEmpty {
                        Text("尚無播放紀錄")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(player.playbackHistory) { track in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("播放") {
                                    player.playDownloadedTrack(track)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            .navigationTitle("資料庫")
        }
    }
}

private struct PlayerTabView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @State private var isImportPickerPresented: Bool = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("目前播放")
                            .font(.headline)

                        if let track = player.nowPlayingTrack {
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title)
                                        .font(.title3)
                                        .lineLimit(2)
                                    Text(track.artist)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button(player.isFavorite(track) ? "已收藏" : "收藏") {
                                    player.toggleFavorite(track)
                                }
                                .buttonStyle(.bordered)
                            }
                        } else {
                            Text("尚未開始播放")
                                .foregroundColor(.secondary)
                        }
                    }

                    Text("目前來源")
                        .font(.headline)
                    TextField("https://example.com/audio.mp3", text: $player.streamURL)
                        .urlKeyboardIfAvailable()
                        .noAutoInputAdjustments()
                        .textFieldStyle(.roundedBorder)

                    HStack {
                        Button("以網址播放") {
                            player.loadAndPlay()
                        }
                        .buttonStyle(.bordered)

                        Button("匯入本機音訊") {
                            isImportPickerPresented = true
                        }
                        .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Slider(
                            value: Binding(
                                get: { player.sliderPosition },
                                set: { player.updateScrubbing(position: $0) }
                            ),
                            in: 0...max(player.duration, 1),
                            onEditingChanged: { editing in
                                if editing {
                                    player.beginScrubbing()
                                } else {
                                    player.endScrubbing()
                                }
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

                    HStack(spacing: 12) {
                        Button(action: player.seekBackward15) {
                            Label("-15", systemImage: "gobackward.15")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)

                        Button(action: player.togglePlayback) {
                            Label(player.isPlaying ? "暫停" : "播放", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button(action: player.seekForward15) {
                            Label("+15", systemImage: "goforward.15")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                    }

                    HStack(spacing: 12) {
                        Button("上一首") { player.playPrevious() }
                            .buttonStyle(.bordered)
                        Button("下一首") { player.playNext() }
                            .buttonStyle(.bordered)
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("歌詞")
                                .font(.headline)
                            Spacer()
                            Button("載入") {
                                player.loadLyricsForCurrentTrack()
                            }
                            .buttonStyle(.bordered)
                        }

                        if player.isLoadingLyrics {
                            ProgressView("載入歌詞中...")
                        } else if player.lyricsText.isEmpty {
                            Text("尚未載入")
                                .foregroundColor(.secondary)
                        } else {
                            Text(player.lyricsText)
                                .font(.footnote)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("播放佇列")
                                .font(.headline)
                        }

                        ForEach(Array(player.queue.enumerated()), id: \.element.id) { index, track in
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(track.title)
                                        .lineLimit(1)
                                    Text(track.artist)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if player.currentQueueIndex == index {
                                    Image(systemName: "speaker.wave.2.fill")
                                        .foregroundColor(.accentColor)
                                }
                                Button("播放") {
                                    player.playQueueItem(at: index)
                                }
                                .buttonStyle(.bordered)

                                Button("刪除") {
                                    player.removeQueueItem(at: IndexSet(integer: index))
                                }
                                .buttonStyle(.bordered)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("播放中")
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
        }
    }
}

private struct SettingsTabView: View {
    @AppStorage("settings.autoPlayNext") private var autoPlayNext: Bool = true
    @AppStorage("settings.allowCellular") private var allowCellular: Bool = true
    @AppStorage("settings.showExplicit") private var showExplicit: Bool = true

    var body: some View {
        NavigationView {
            Form {
                Section("播放") {
                    Toggle("自動播放下一首", isOn: $autoPlayNext)
                    Toggle("允許行動網路播放", isOn: $allowCellular)
                    Toggle("顯示 Explicit 標記", isOn: $showExplicit)
                }

                Section("版本") {
                    Text("OuterTune iOS 移植版")
                    Text("目標：功能對齊 Android 主版本")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("設定")
        }
    }
}

#Preview {
    ContentView()
}

private extension View {
    @ViewBuilder
    func noAutoInputAdjustments() -> some View {
#if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
#else
        self
#endif
    }

    @ViewBuilder
    func urlKeyboardIfAvailable() -> some View {
#if os(iOS)
        self.keyboardType(.URL)
#else
        self
#endif
    }
}
