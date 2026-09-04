import SwiftUI

/// Settings for the auto-queue: the Spotify account that supplies the taste
/// profile, and the optional LLM that re-ranks candidates.
struct RecommendationSettingsView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @EnvironmentObject private var spotify: SpotifyService
    @EnvironmentObject private var ranker: AIRankingService

    @State private var clientIdDraft: String = ""
    @State private var endpointDraft: String = ""
    @State private var apiKeyDraft: String = ""
    @State private var modelDraft: String = ""
    @State private var didSaveAI: Bool = false
    @State private var confirmSpotifyLogout: Bool = false

    var body: some View {
        Form {
            autoQueueSection
            spotifySection
            aiSection
        }
        .navigationTitle("推薦與自動佇列")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            clientIdDraft = spotify.clientId
            endpointDraft = ranker.endpoint
            modelDraft = ranker.model
        }
        .confirmationDialog("確定要中斷 Spotify 連結？",
                            isPresented: $confirmSpotifyLogout,
                            titleVisibility: .visible) {
            Button("中斷連結", role: .destructive) { spotify.logout() }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - Auto queue

    private var autoQueueSection: some View {
        Section {
            Toggle("佇列播完後自動接續", isOn: Binding(
                get: { player.isAutoQueueEnabled },
                set: { player.isAutoQueueEnabled = $0 }
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
            Text("播放清單結束時，會依照 YouTube Music 電台、Spotify 聆聽紀錄與 "
                 + "Deezer 相似藝人自動加入歌曲。")
        }
    }

    // MARK: - Spotify

    @ViewBuilder
    private var spotifySection: some View {
        Section {
            if spotify.isAuthenticated {
                HStack {
                    Text("已連結")
                    Spacer()
                    Text(spotify.displayName ?? "Spotify")
                        .foregroundColor(.secondary)
                }
                if let product = spotify.product {
                    HStack {
                        Text("方案")
                        Spacer()
                        Text(product)
                            .foregroundColor(.secondary)
                    }
                }

                tasteSummary

                Button {
                    Task { await spotify.refreshTasteProfile(force: true) }
                } label: {
                    if spotify.isRefreshingProfile {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("更新中…")
                        }
                    } else {
                        Text("重新整理聆聽紀錄")
                    }
                }
                .disabled(spotify.isRefreshingProfile)

                Button("中斷連結", role: .destructive) {
                    confirmSpotifyLogout = true
                }
            } else {
                TextField("Spotify Client ID", text: $clientIdDraft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(.body, design: .monospaced))

                HStack {
                    Text("Redirect URI")
                    Spacer()
                    Text(SpotifyService.redirectURI)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Button("連結 Spotify") {
                    spotify.updateClientId(clientIdDraft)
                    Task { await spotify.authorize() }
                }
                .disabled(clientIdDraft.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            if let error = spotify.lastErrorMessage {
                Text(error)
                    .font(.footnote)
                    .foregroundColor(.red)
            }
        } header: {
            Text("Spotify")
        } footer: {
            Text("在 developer.spotify.com 建立自己的 App，把上方 Redirect URI "
                 + "加入該 App 設定，再貼上 Client ID。不需要 Client Secret，"
                 + "也不需要 Premium。")
        }
    }

    @ViewBuilder
    private var tasteSummary: some View {
        let artists = spotify.profile.weightedArtists.prefix(5).map(\.artist.name)
        if !artists.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("常聽藝人")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(artists.joined(separator: "、"))
                    .font(.footnote)
            }
        }
    }

    // MARK: - AI ranking

    @ViewBuilder
    private var aiSection: some View {
        Section {
            Toggle("使用 AI 排序推薦", isOn: Binding(
                get: { ranker.isEnabled },
                set: { ranker.setEnabled($0) }
            ))

            if ranker.isEnabled {
                TextField("API Endpoint", text: $endpointDraft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .font(.system(.caption, design: .monospaced))

                SecureField(ranker.hasAPIKey ? "API Key（已儲存，可留空）" : "API Key",
                            text: $apiKeyDraft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                TextField("Model", text: $modelDraft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .font(.system(.caption, design: .monospaced))

                Button("儲存") {
                    ranker.configure(
                        endpoint: endpointDraft,
                        apiKey: apiKeyDraft.isEmpty ? nil : apiKeyDraft,
                        model: modelDraft
                    )
                    apiKeyDraft = ""
                    didSaveAI = true
                }
                .disabled(endpointDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                if didSaveAI {
                    Text("已儲存")
                        .font(.footnote)
                        .foregroundColor(.green)
                }

                if ranker.hasAPIKey {
                    Button("清除 API Key", role: .destructive) {
                        ranker.clearCredentials()
                    }
                }

                if let failure = ranker.lastFailureReason {
                    Text("上次失敗：\(failure)")
                        .font(.footnote)
                        .foregroundColor(.orange)
                }
            }
        } header: {
            Text("AI 推薦排序")
        } footer: {
            Text("相容 OpenAI 格式的 /v1/chat/completions 端點。AI 只會從已解析出的"
                 + "候選歌曲中挑選與排序，不會自行編造歌名；呼叫失敗時會自動改用"
                 + "內建的權重排序，播放不會中斷。")
        }
    }
}
