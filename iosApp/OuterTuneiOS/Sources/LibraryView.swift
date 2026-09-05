import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @EnvironmentObject private var account: AccountStore

    @State private var selectedTab: LibrarySection = .youtube
    @State private var selectedPlaylist: LibraryPlaylist?

    enum LibrarySection: String, CaseIterable, Identifiable {
        case youtube = "YouTube"
        case downloads = "下載"
        case favorites = "收藏"
        case history = "最近"
        var id: String { rawValue }
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("", selection: $selectedTab) {
                    ForEach(LibrarySection.allCases) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                content
            }
            .navigationTitle("音樂庫")
            .refreshable {
                if selectedTab == .youtube, account.isLoggedIn {
                    await player.refreshLibraryPlaylists()
                }
            }
            .onAppear {
                if selectedTab == .youtube, account.isLoggedIn,
                   player.libraryPlaylists.isEmpty {
                    Task { await player.refreshLibraryPlaylists() }
                }
            }
            .onChange(of: selectedTab) { newValue in
                if newValue == .youtube, account.isLoggedIn,
                   player.libraryPlaylists.isEmpty {
                    Task { await player.refreshLibraryPlaylists() }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $selectedPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
                .environmentObject(player)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch selectedTab {
        case .youtube:
            youtubeSection
        case .downloads:
            downloadsSection
        case .favorites:
            favoritesSection
        case .history:
            historySection
        }
    }

    // MARK: - YouTube 音樂庫

    private var youtubeSection: some View {
        Group {
            if !account.isLoggedIn {
                emptyState(
                    icon: "person.crop.circle.badge.questionmark",
                    title: "尚未登入",
                    message: "請至設定頁登入以查看您的 YouTube Music 音樂庫。"
                )
            } else if player.isLoadingLibraryPlaylists && player.libraryPlaylists.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let err = player.libraryErrorMessage {
                emptyState(icon: "exclamationmark.triangle", title: "載入失敗", message: err)
            } else if player.libraryPlaylists.isEmpty {
                emptyState(
                    icon: "music.note.list",
                    title: "沒有播放清單",
                    message: "您在 YouTube Music 尚未建立或訂閱任何播放清單。"
                )
            } else {
                playlistGrid
            }
        }
    }

    private var playlistGrid: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)],
                spacing: 16
            ) {
                ForEach(player.libraryPlaylists) { playlist in
                    Button {
                        selectedPlaylist = playlist
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            TrackArtworkView(
                                urlString: playlist.thumbnailURL,
                                dimension: 160,
                                cornerRadius: 10
                            )
                            .frame(maxWidth: .infinity)
                            Text(playlist.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                                .foregroundColor(.primary)
                            if let sub = playlist.subtitle {
                                Text(sub)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
        }
    }

    // MARK: - 本機下載

    private var downloadsSection: some View {
        Group {
            if player.downloadedTracks.isEmpty {
                emptyState(icon: "arrow.down.circle", title: "沒有下載項目", message: "在搜尋結果中點擊下載即可離線聆聽。")
            } else {
                List {
                    ForEach(player.downloadedTracks) { track in
                        TrackRowView(
                            title: track.title,
                            subtitle: track.artist,
                            thumbnailURL: track.thumbnailURL,
                            onTap: { player.playDownloadedTrack(track) }
                        ) {
                            Menu {
                                Button("播放") { player.playDownloadedTrack(track) }
                                Button("加入佇列") { player.enqueueTrack(track, status: "已加入佇列") }
                                Button(role: .destructive) {
                                    player.removeDownloadedTrack(track)
                                } label: {
                                    Text("刪除")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var favoritesSection: some View {
        Group {
            if player.favoriteTracks.isEmpty {
                emptyState(icon: "heart", title: "尚未收藏", message: "在播放器按下愛心即可加入收藏。")
            } else {
                List {
                    ForEach(player.favoriteTracks) { track in
                        TrackRowView(
                            title: track.title,
                            subtitle: track.artist,
                            thumbnailURL: track.thumbnailURL,
                            onTap: { player.playDownloadedTrack(track) }
                        ) {
                            Button {
                                player.removeFavorite(track)
                            } label: {
                                Image(systemName: "heart.slash")
                                    .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private var historySection: some View {
        Group {
            if player.playbackHistory.isEmpty {
                emptyState(icon: "clock", title: "沒有播放紀錄", message: "開始聆聽後，這裡會顯示最近播放。")
            } else {
                List {
                    ForEach(player.playbackHistory) { track in
                        TrackRowView(
                            title: track.title,
                            subtitle: track.artist,
                            thumbnailURL: track.thumbnailURL,
                            onTap: { player.playDownloadedTrack(track) }
                        ) {
                            EmptyView()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func emptyState(icon: String, title: String, message: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
