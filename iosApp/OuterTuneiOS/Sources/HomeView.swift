import SwiftUI

/// Home: a dark, art-forward browse surface.
///
/// The top grid is the listener's personalised shelf, followed by the
/// language-split shelves the resolver builds. The DJ card starts an automatic
/// station in one tap - no prompt, no picking - and long-press opens the
/// prompt-driven version.
struct HomeView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @EnvironmentObject private var account: AccountStore
    @EnvironmentObject private var resolver: StreamResolverService

    let openNowPlaying: () -> Void
    let openLogin: () -> Void

    @State private var selectedPlaylist: LibraryPlaylist?
    @State private var isAIRadioPresented = false
    @State private var isDJBuilding = false
    @State private var djMessage: String?

    var body: some View {
        NavigationView {
            ZStack {
                AppTheme.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 26) {
                        header

                        DJCard(isBuilding: isDJBuilding,
                               subtitle: djSubtitle) {
                            Task { await startDJ() }
                        }
                        .padding(.horizontal, 16)
                        .contextMenu {
                            Button {
                                isAIRadioPresented = true
                            } label: {
                                Label("自訂電台…", systemImage: "text.bubble")
                            }
                        }

                        if !account.isLoggedIn {
                            loginPrompt
                        }

                        content

                        Color.clear.frame(height: 140)
                    }
                    .padding(.top, 8)
                }
                .refreshable {
                    await player.refreshHomeFeed(forceRefresh: true)
                    if account.isLoggedIn {
                        await player.refreshAccountInfo()
                    }
                }
            }
            .navigationBarHidden(true)
            .onAppear {
                Task {
                    if player.homeFeed.sections.isEmpty {
                        await player.refreshHomeFeed()
                    }
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
        .sheet(isPresented: $isAIRadioPresented) {
            AIRadioView()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            Text(AppTheme.greeting)
                .font(.system(size: 26, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)

            Spacer()

            if player.nowPlayingTrack != nil {
                Button(action: openNowPlaying) {
                    Image(systemName: "waveform")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private var djSubtitle: String {
        if let djMessage { return djMessage }
        // An automatic station names itself only once its long wave lands,
        // so the theme arrives here after playback has already begun.
        if let theme = resolver.lastAIRadioTheme, !theme.isEmpty { return theme }
        if isDJBuilding { return "正在為你挑選歌曲…" }
        return "一鍵播放，長按可自訂主題"
    }

    private var loginPrompt: some View {
        Button(action: openLogin) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.badge.plus")
                    .font(.system(size: 22))
                    .foregroundColor(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("登入 YouTube Music")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text("同步你的音樂庫與個人化推薦")
                        .font(.caption)
                        .foregroundColor(AppTheme.textSecondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .foregroundColor(AppTheme.textSecondary)
            }
            .padding(12)
            .background(AppTheme.surface)
            .cornerRadius(AppTheme.cardCorner)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if player.isLoadingHome && player.homeFeed.sections.isEmpty {
            ProgressView()
                .tint(AppTheme.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
        } else if let message = player.homeErrorMessage,
                  player.homeFeed.sections.isEmpty {
            errorBox(message)
        } else if player.homeFeed.sections.isEmpty {
            Text("目前沒有內容，下拉以重新整理")
                .font(.subheadline)
                .foregroundColor(AppTheme.textSecondary)
                .padding(.horizontal, 16)
        } else {
            // The first shelf becomes the compact grid at the top, the way the
            // big clients surface your most-likely picks above the carousels.
            if let first = player.homeFeed.sections.first {
                quickPicks(first)
            }
            ForEach(player.homeFeed.sections.dropFirst()) { section in
                shelf(section)
            }
        }
    }

    private func quickPicks(_ section: HomeSection) -> some View {
        let columns = [GridItem(.flexible(), spacing: 8),
                       GridItem(.flexible(), spacing: 8)]
        return VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: section.title, subtitle: section.strapline)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(section.items.prefix(8)) { item in
                    QuickTile(title: item.title,
                              artworkURL: item.thumbnailURL) {
                        handleTap(item)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func shelf(_ section: HomeSection) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ShelfHeader(title: section.title, subtitle: section.strapline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 14) {
                    ForEach(section.items) { item in
                        ShelfTile(title: item.title,
                                  subtitle: item.subtitle,
                                  artworkURL: item.thumbnailURL,
                                  rounded: item.kind == .artist) {
                            handleTap(item)
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func errorBox(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("載入失敗")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(AppTheme.textPrimary)
            Text(message)
                .font(.caption)
                .foregroundColor(AppTheme.textSecondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.surface)
        .cornerRadius(AppTheme.cardCorner)
        .padding(.horizontal, 16)
    }

    // MARK: - Actions

    /// One tap, one station. The server chooses the theme when none is given,
    /// so this needs no input from the listener.
    private func startDJ() async {
        guard resolver.isConfigured else {
            djMessage = "請先在設定中填入串流伺服器網址"
            return
        }
        isDJBuilding = true
        djMessage = nil
        defer { isDJBuilding = false }

        // The station starts on the first few songs the server resolves; the
        // rest arrive in the queue while these are playing. An automatic
        // station is not named until the long wave runs, so the theme shown
        // here fills in from the resolver a moment later.
        if let batch = await resolver.openAIRadio(prompt: "", limit: 30),
           !batch.tracks.isEmpty {
            djMessage = batch.theme
            player.startAIRadio(batch)
            openNowPlaying()
        } else {
            djMessage = resolver.lastErrorMessage ?? "無法建立電台，請稍後再試"
        }
    }

    private func handleTap(_ item: HomeItem) {
        if let track = item.asTrack() {
            // A home song behaves like a radio seed: play it and build a
            // personalised queue behind it.
            player.playHomeTrack(track)
            return
        }

        selectedPlaylist = LibraryPlaylist(
            id: item.primaryId,
            title: item.title,
            subtitle: item.subtitle,
            thumbnailURL: item.thumbnailURL
        )
    }
}
