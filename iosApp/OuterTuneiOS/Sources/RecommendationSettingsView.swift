import SwiftUI

/// Auto-queue settings.
///
/// The Spotify account and the AI model are configured on the resolver, since
/// that is where recommendation runs; this screen only covers what the app
/// itself decides.
struct RecommendationSettingsView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel

    var body: some View {
        Form {
            autoQueueSection
            serverManagedNote
        }
        .navigationTitle("推薦與自動佇列")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Spotify credentials and the AI key now live on the resolver, which is
    /// where recommendation actually runs. Duplicating them here would let the
    /// two disagree, so the app only points at the server.
    private var serverManagedNote: some View {
        Section {
            NavigationLink("串流伺服器設定") {
                ResolverSettingsView()
            }
        } header: {
            Text("推薦來源")
        } footer: {
            Text("Spotify 帳號、AI 模型與推薦演算法都在伺服器端執行，"
                 + "因此不需要在 App 內重複設定。")
        }
    }

    // MARK: - Auto queue

    private var autoQueueSection: some View {
        Section {
            Toggle("佇列播完後自動接續", isOn: Binding(
                get: { player.isAutoQueueEnabled },
                set: { player.setAutoQueueEnabled($0) }
            ))

            if player.isExtendingQueue {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("正在尋找相似歌曲…")
                        .foregroundColor(.secondary)
                }
            }
        } header: {
            Text("自動佇列")
        } footer: {
            Text("播放清單結束時，會用 YouTube Music 電台提供情境，並以 Spotify "
                 + "與本機聆聽紀錄限制為你熟悉的藝人；只有資料不足時才使用其他來源。")
        }
    }

}
