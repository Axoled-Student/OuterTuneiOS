import SwiftUI

/// Shared detail screen for playlists, albums, mixes, and artist song shelves.
struct PlaylistDetailView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    let playlist: LibraryPlaylist

    @State private var songs: [YouTubeSearchSong] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationView {
            Group {
                if isLoading && songs.isEmpty {
                    ProgressView("載入播放清單...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage, songs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 40))
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .multilineTextAlignment(.center)
                            .foregroundColor(.secondary)
                        Button("再試一次") { Task { await load() } }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        Section {
                            VStack(spacing: 12) {
                                TrackArtworkView(
                                    urlString: playlist.thumbnailURL,
                                    dimension: 190,
                                    cornerRadius: 14
                                )
                                Text(playlist.title)
                                    .font(.title2.bold())
                                    .multilineTextAlignment(.center)
                                if let subtitle = playlist.subtitle, !subtitle.isEmpty {
                                    Text(subtitle)
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                }

                                HStack(spacing: 12) {
                                    Button {
                                        player.playPlaylist(songs)
                                    } label: {
                                        Label("播放", systemImage: "play.fill")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(songs.isEmpty)

                                    Button {
                                        player.enqueuePlaylist(songs)
                                    } label: {
                                        Label("加入佇列", systemImage: "text.badge.plus")
                                            .frame(maxWidth: .infinity)
                                    }
                                    .buttonStyle(.bordered)
                                    .disabled(songs.isEmpty)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                        }

                        Section("歌曲（\(songs.count)）") {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                                TrackRowView(
                                    title: song.title,
                                    subtitle: song.artist,
                                    thumbnailURL: song.thumbnailURL ?? playlist.thumbnailURL,
                                    onTap: { player.playPlaylist(songs, startingAt: index) }
                                ) {
                                    Menu {
                                        Button("從這首播放") {
                                            player.playPlaylist(songs, startingAt: index)
                                        }
                                        Button("加入佇列") {
                                            player.enqueueSearchResult(song)
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("播放清單")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("關閉") { dismiss() }
                }
            }
            .task(id: playlist.id) {
                await load()
            }
        }
        .navigationViewStyle(.stack)
    }

    @MainActor
    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            songs = try await YouTubeMusicService.shared.fetchBrowseSongs(
                browseId: playlist.id
            )
            if songs.isEmpty {
                errorMessage = "此項目沒有可播放的歌曲"
            }
        } catch {
            errorMessage = "載入失敗：\(error.localizedDescription)"
        }
    }
}
