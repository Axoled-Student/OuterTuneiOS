import SwiftUI

struct ContentView: View {
    @StateObject private var player = AudioPlayerViewModel()
    @StateObject private var accountStore = AccountStore.shared
    @State private var isNowPlayingPresented: Bool = false
    @State private var isLoginPresented: Bool = false

    var body: some View {
        TabView {
            HomeView(
                openNowPlaying: { isNowPlayingPresented = true },
                openLogin: { isLoginPresented = true }
            )
            .tabItem {
                Label("首頁", systemImage: "house")
            }

            SearchView()
                .tabItem {
                    Label("搜尋", systemImage: "magnifyingglass")
                }

            LibraryView()
                .tabItem {
                    Label("音樂庫", systemImage: "books.vertical")
                }

            SettingsView()
                .tabItem {
                    Label("設定", systemImage: "gearshape")
                }
        }
        .environmentObject(player)
        .environmentObject(accountStore)
        .overlay(alignment: .bottom) {
            if player.nowPlayingTrack != nil {
                MiniPlayerBarView {
                    isNowPlayingPresented = true
                }
                .environmentObject(player)
                .padding(.horizontal, 12)
                .padding(.bottom, 54)
            }
        }
        .sheet(isPresented: $isNowPlayingPresented) {
            NowPlayingView()
                .environmentObject(player)
        }
        .sheet(isPresented: $isLoginPresented) {
            LoginContainerView()
                .environmentObject(accountStore)
                .environmentObject(player)
        }
    }
}

#Preview {
    ContentView()
}
