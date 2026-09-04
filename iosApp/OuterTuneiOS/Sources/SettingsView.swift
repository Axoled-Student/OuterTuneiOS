import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @EnvironmentObject private var account: AccountStore

    @AppStorage("settings.autoPlayNext") private var autoPlayNext: Bool = true
    @AppStorage("settings.allowCellular") private var allowCellular: Bool = true
    @AppStorage("settings.showExplicit") private var showExplicit: Bool = true

    @State private var isLoginSheetPresented: Bool = false
    @State private var confirmLogout: Bool = false

    var body: some View {
        NavigationView {
            Form {
                accountSection
                audioSection
                playbackSection
                recommendationSection
                aboutSection
            }
            .navigationTitle("設定")
            .sheet(isPresented: $isLoginSheetPresented) {
                LoginContainerView()
                    .environmentObject(account)
                    .environmentObject(player)
            }
            .confirmationDialog(
                "確定要登出？",
                isPresented: $confirmLogout,
                titleVisibility: .visible
            ) {
                Button("登出", role: .destructive) {
                    player.logoutYouTubeAccount()
                }
                Button("取消", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 帳號

    @ViewBuilder
    private var accountSection: some View {
        Section("帳號") {
            if account.isLoggedIn {
                HStack(spacing: 12) {
                    if let avatar = account.accountInfo?.avatarURL, let url = URL(string: avatar) {
                        AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: {
                            Color.secondary.opacity(0.2)
                        }
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                    } else {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.accountInfo?.name ?? "已登入")
                            .font(.headline)
                        if let email = account.accountInfo?.email ?? account.accountInfo?.channelHandle {
                            Text(email)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Button {
                    Task {
                        await player.refreshAccountInfo()
                        await player.refreshHomeFeed()
                        await player.refreshLibraryPlaylists()
                    }
                } label: {
                    Label("重新同步", systemImage: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    confirmLogout = true
                } label: {
                    Label("登出 YouTube 帳號", systemImage: "rectangle.portrait.and.arrow.right")
                }
            } else {
                Button {
                    isLoginSheetPresented = true
                } label: {
                    Label("使用 Google 登入", systemImage: "person.crop.circle.badge.plus")
                }
                Text("登入後可同步個人化推薦、播放清單，並取得更高音質串流授權。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - 音訊 / 播放偏好

    private var audioSection: some View {
        Section("音訊") {
            Picker("音質", selection: Binding(
                get: { player.audioQualityPreference },
                set: { player.setAudioQualityPreference($0) }
            )) {
                ForEach(AudioQualityPreference.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            Text(player.audioQualityPreference.description)
                .font(.footnote)
                .foregroundColor(.secondary)
        }
    }

    private var playbackSection: some View {
        Section("播放") {
            Toggle("自動播放下一首", isOn: $autoPlayNext)
            Toggle("允許行動網路播放", isOn: $allowCellular)
            Toggle("顯示 Explicit 標記", isOn: $showExplicit)

            Picker("循環模式", selection: Binding(
                get: { player.repeatMode },
                set: { mode in
                    while player.repeatMode != mode { player.toggleRepeatMode() }
                }
            )) {
                Text("關閉").tag(RepeatMode.off)
                Text("全部循環").tag(RepeatMode.all)
                Text("單曲循環").tag(RepeatMode.one)
            }

            Toggle("隨機播放", isOn: Binding(
                get: { player.isShuffleEnabled },
                set: { _ in player.toggleShuffle() }
            ))
        }
    }

    private var recommendationSection: some View {
        Section("推薦") {
            NavigationLink("推薦與自動佇列") {
                RecommendationSettingsView()
            }
        }
    }

    private var aboutSection: some View {
        Section("關於") {
            VStack(alignment: .leading, spacing: 4) {
                Text("OuterTune iOS")
                    .font(.headline)
                Text("移植自 Android 主版本，目標功能對齊")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }

            NavigationLink("Debug 日誌") {
                DebugLogView()
                    .environmentObject(player)
            }
        }
    }
}

struct DebugLogView: View {
    @EnvironmentObject var player: AudioPlayerViewModel

    var body: some View {
        List {
            if player.recentDebugLogs.isEmpty {
                Text("尚無日誌")
                    .foregroundColor(.secondary)
            } else {
                ForEach(Array(player.recentDebugLogs.enumerated()), id: \.offset) { _, log in
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Debug 日誌")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("複製全部") {
                    let all = player.recentDebugLogs.joined(separator: "\n")
                    #if os(iOS)
                    UIPasteboard.general.string = all
                    #endif
                }
            }
        }
    }
}
