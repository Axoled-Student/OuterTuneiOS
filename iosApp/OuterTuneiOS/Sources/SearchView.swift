import Foundation
import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                Picker("搜尋類型", selection: $player.searchScope) {
                    ForEach(YouTubeMusicSearchScope.allCases) { scope in
                        Text(scope.displayName).tag(scope)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)

                Divider()

                ZStack {
                    if player.searchResults.isEmpty && !player.isSearching {
                        placeholder
                    } else {
                        resultsList
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("搜尋")
            .searchable(
                text: $player.searchQuery,
                placement: .navigationBarDrawer(displayMode: .always),
                prompt: "搜尋 YouTube Music"
            )
            .onChange(of: player.searchQuery) { _ in
                player.scheduleAutocomplete()
            }
            .onChange(of: player.searchScope) { _ in
                guard !player.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty else { return }
                Task { await player.searchYouTube() }
            }
            .onSubmit(of: .search) {
                Task { await player.searchYouTube() }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var placeholder: some View {
        VStack(spacing: 16) {
            if !player.autocompleteSuggestions.isEmpty {
                List {
                    Section("建議") {
                        ForEach(player.autocompleteSuggestions, id: \.self) { suggestion in
                            Button {
                                player.applyAutocompleteSuggestion(suggestion)
                                Task { await player.searchYouTube() }
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "magnifyingglass")
                                        .foregroundColor(.secondary)
                                    Text(suggestion)
                                        .foregroundColor(.primary)
                                    Spacer()
                                    Image(systemName: "arrow.up.left")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
                .listStyle(.insetGrouped)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "music.note.list")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text(player.searchScope == .songs
                         ? "輸入關鍵字以搜尋音樂"
                         : "輸入關鍵字以搜尋音樂影片")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                .padding()
            }
        }
    }

    private var resultsList: some View {
        List {
            if player.isSearching {
                HStack {
                    Spacer()
                    ProgressView("搜尋中…")
                    Spacer()
                }
            }
            ForEach(player.searchResults) { song in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        TrackArtworkView(
                            urlString: song.thumbnailURL,
                            dimension: 54,
                            cornerRadius: 6
                        )
                        VStack(alignment: .leading, spacing: 3) {
                            Text(song.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                                .lineLimit(2)
                            Text(song.artist)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                            if let duration = song.durationText {
                                Text(duration)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                        Spacer(minLength: 6)
                        Menu {
                            Button {
                                player.playSearchResult(song)
                            } label: {
                                Label("播放", systemImage: "play.fill")
                            }
                            Button {
                                player.enqueueSearchResult(song)
                            } label: {
                                Label("加入佇列", systemImage: "text.badge.plus")
                            }
                            if !player.isDownloading(song) {
                                Button {
                                    player.downloadSearchResult(song)
                                } label: {
                                    Label("下載", systemImage: "arrow.down.circle")
                                }
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.title3)
                                .foregroundColor(.accentColor)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    player.playSearchResult(song)
                }
            }
        }
        .listStyle(.plain)
    }
}
