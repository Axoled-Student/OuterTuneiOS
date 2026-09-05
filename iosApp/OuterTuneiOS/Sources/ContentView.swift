import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player = AudioPlayerViewModel()
    @StateObject private var accountStore = AccountStore.shared
    @StateObject private var spotify = SpotifyService.shared
    @StateObject private var aiRanker = AIRankingService.shared
    @StateObject private var resolver = StreamResolverService.shared

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var selectedTab: Tab = .home
    @State private var isNowPlayingPresented: Bool = false
    /// Wide layouts keep the player docked beside the content instead of
    /// covering it, which is how the tablet versions of these apps behave.
    @AppStorage("ui.sidePanelVisible") private var isSidePanelVisible: Bool = true
    @State private var isLoginPresented: Bool = false

    enum Tab: Hashable {
        case home, search, library, settings

        var title: String {
            switch self {
            case .home: return "首頁"
            case .search: return "搜尋"
            case .library: return "音樂庫"
            case .settings: return "設定"
            }
        }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .search: return "magnifyingglass"
            case .library: return "books.vertical.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    private var usesSidePanel: Bool {
        horizontalSizeClass == .regular
    }

    var body: some View {
        Group {
            if usesSidePanel {
                HStack(spacing: 0) {
                    mainColumn
                    if isSidePanelVisible, player.nowPlayingTrack != nil {
                        Divider().background(Color.white.opacity(0.08))
                        NowPlayingView(onClose: { isSidePanelVisible = false })
                            .environmentObject(player)
                            .frame(width: 380)
                            .transition(.move(edge: .trailing))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: isSidePanelVisible)
                .animation(.easeInOut(duration: 0.25),
                           value: player.nowPlayingTrack?.stableId)
            } else {
                mainColumn
            }
        }
        .preferredColorScheme(.dark)
        .tint(AppTheme.accent)
        .environmentObject(player)
        .environmentObject(accountStore)
        .environmentObject(spotify)
        .environmentObject(aiRanker)
        .environmentObject(resolver)
        .fullScreenCover(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .environmentObject(player)
        }
        .sheet(isPresented: $isLoginPresented) {
            LoginContainerView()
                .environmentObject(accountStore)
                .environmentObject(player)
        }
        .onChange(of: scenePhase) { phase in
            player.handleScenePhase(phase)
        }
        .onAppear {
            player.handleScenePhase(scenePhase)
        }
    }

    /// Reveal the player wherever it lives on this layout.
    private func presentNowPlaying() {
        if usesSidePanel {
            isSidePanelVisible = true
        } else {
            isNowPlayingPresented = true
        }
    }

    private var mainColumn: some View {
        ZStack(alignment: .bottom) {
            AppTheme.background.ignoresSafeArea()

            // A hand-rolled bar rather than TabView: iPadOS renders TabView's
            // tabs as a segmented control at the *top*, which is the wrong
            // shape for a music app and does not match the phone layout.
            Group {
                switch selectedTab {
                case .home:
                    HomeView(
                        openNowPlaying: { presentNowPlaying() },
                        openLogin: { isLoginPresented = true }
                    )
                case .search:
                    SearchView()
                case .library:
                    LibraryView()
                case .settings:
                    SettingsView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            VStack(spacing: 8) {
                // With the panel docked the mini player would duplicate it, so
                // it only appears when the player is not already on screen.
                if player.nowPlayingTrack != nil,
                   !(usesSidePanel && isSidePanelVisible) {
                    MiniPlayerBarView {
                        if usesSidePanel {
                            isSidePanelVisible = true
                        } else {
                            isNowPlayingPresented = true
                        }
                    }
                    .environmentObject(player)
                    .padding(.horizontal, 8)
                }
                tabBar
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach([Tab.home, .search, .library, .settings], id: \.self) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 19))
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundColor(selectedTab == tab
                                     ? AppTheme.textPrimary
                                     : AppTheme.textSecondary)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(AppTheme.surfaceRaised.opacity(0.96))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
        .frame(maxWidth: 460)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }
}

#Preview {
    ContentView()
}
