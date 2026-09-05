import SwiftUI

/// 首頁：登入後顯示 YouTube Music 個人化 feed；未登入顯示登入提示。
/// 另外保留「目前播放」快速卡片與快速動作。
struct HomeView: View {
    @State private var isAIRadioPresented = false
    @EnvironmentObject private var player: AudioPlayerViewModel
    @EnvironmentObject private var account: AccountStore

    let openNowPlaying: () -> Void
    let openLogin: () -> Void

    @State private var selectedPlaylist: LibraryPlaylist?

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    nowPlayingCard

                    if account.isLoggedIn {
                        accountBanner
                    } else {
                        loginPromptBanner
                    }

                    if player.isLoadingHome && player.homeFeed.sections.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    } else if let msg = player.homeErrorMessage {
                        errorBox(msg)
                    } else if player.homeFeed.sections.isEmpty {
                        Text("目前沒有首頁內容，下拉以重新整理")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .padding(.horizontal)
                    } else {
                        ForEach(player.homeFeed.sections) { section in
                            homeSectionView(section)
                        }
                    }

                    Color.clear.frame(height: 120)
                }
                .padding(.vertical)
            }
            .navigationTitle("首頁")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isAIRadioPresented = true
                    } label: {
                        Label("AI 電台", systemImage: "sparkles")
                    }
                }
            }
            .sheet(isPresented: $isAIRadioPresented) {
                AIRadioView()
            }
            .refreshable {
                await player.refreshHomeFeed()
                if account.isLoggedIn {
                    await player.refreshAccountInfo()
                }
            }
            .onAppear {
                Task {
                    if player.homeFeed.sections.isEmpty { await player.refreshHomeFeed() }
                    if account.isLoggedIn, account.accountInfo == nil {
                        await player.refreshAccountInfo()
                    }
                }
            }
        }
        .navigationViewStyle(.stack)
        .sheet(item: $selectedPlaylist) { playlist in
            PlaylistDetailView(playlist: playlist)
                .environmentObject(player)
        }
    }

    // MARK: - 子區塊

    private var nowPlayingCard: some View {
        Group {
            if let track = player.nowPlayingTrack {
                Button(action: openNowPlaying) {
                    HStack(spacing: 12) {
                        TrackArtworkView(urlString: track.displayThumbnailURL, dimension: 72, cornerRadius: 10)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("正在播放")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                            Text(track.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.accentColor)
                            .onTapGesture {
                                player.togglePlayback()
                            }
                    }
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .padding(.horizontal)
                }
                .buttonStyle(.plain)
            } else {
                EmptyView()
            }
        }
    }

    private var accountBanner: some View {
        HStack(spacing: 12) {
            if let avatar = account.accountInfo?.avatarURL, let url = URL(string: avatar) {
                AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
                    Color.secondary.opacity(0.2)
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 40))
                    .foregroundColor(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(account.accountInfo?.name ?? "YouTube Music")
                    .font(.headline)
                if let email = account.accountInfo?.email ?? account.accountInfo?.channelHandle {
                    Text(email)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal)
    }

    private var loginPromptBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 34))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("登入以取得個人化內容")
                        .font(.headline)
                    Text("同步您在 YouTube Music 的推薦與音樂庫")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Button(action: openLogin) {
                Text("使用 Google 登入")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .padding(.horizontal)
    }

    private func errorBox(_ msg: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
            Text(msg)
                .font(.footnote)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.12))
        )
        .padding(.horizontal)
    }

    private func homeSectionView(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeaderView(title: section.title, subtitle: section.strapline)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    ForEach(section.items) { item in
                        homeItemTile(item)
                    }
                }
                .padding(.horizontal)
            }
        }
    }

    private func homeItemTile(_ item: HomeItem) -> some View {
        Button {
            handleTap(item)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                TrackArtworkView(
                    urlString: item.thumbnailURL,
                    dimension: 140,
                    cornerRadius: item.kind == .artist ? 70 : 10
                )
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .foregroundColor(.primary)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: 140, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func handleTap(_ item: HomeItem) {
        if let track = item.asTrack() {
            // A home song behaves like YouTube Music's radio: play the seed and
            // immediately generate a visible personalised queue behind it.
            player.playHomeTrack(track)
            return
        }

        // Browse-backed cards are real playlists/albums/artist shelves. Open
        // their rows instead of leaving a visually tappable no-op tile.
        selectedPlaylist = LibraryPlaylist(
            id: item.primaryId,
            title: item.title,
            subtitle: item.subtitle,
            thumbnailURL: item.thumbnailURL
        )
    }
}
