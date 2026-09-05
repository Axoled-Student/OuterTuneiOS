import SwiftUI

/// Configure the companion stream resolver.
struct ResolverSettingsView: View {
    @EnvironmentObject private var resolver: StreamResolverService

    @State private var baseURLDraft: String = ""
    @State private var tokenDraft: String = ""
    @State private var didSave: Bool = false

    var body: some View {
        Form {
            Section {
                TextField("https://xxx.trycloudflare.com", text: $baseURLDraft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .keyboardType(.URL)
                    .font(.system(.caption, design: .monospaced))

                SecureField("Token（選填；新版伺服器不需要）", text: $tokenDraft)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                Button("儲存並測試") {
                    resolver.configure(baseURL: baseURLDraft,
                                       token: tokenDraft)
                    tokenDraft = ""
                    didSave = true
                    Task { await resolver.checkHealth() }
                }
                .disabled(baseURLDraft.trimmingCharacters(in: .whitespaces).isEmpty)

                if resolver.isChecking {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("測試中…")
                    }
                } else if let reachable = resolver.isReachable {
                    Label(reachable ? "已連線" : "無法連線",
                          systemImage: reachable ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(reachable ? .green : .red)
                } else if didSave {
                    Text("已儲存").font(.footnote).foregroundColor(.secondary)
                }

                if let error = resolver.lastErrorMessage, resolver.isReachable == false {
                    Text(error).font(.footnote).foregroundColor(.red)
                }

                if resolver.isConfigured {
                    Button("清除設定", role: .destructive) {
                        resolver.clear()
                        baseURLDraft = ""
                    }
                }
            } header: {
                Text("串流伺服器")
            } footer: {
                Text("只需貼上 start.ps1 顯示的 Server URL；Token 可留空。"
                     + "trycloudflare 快速通道重新啟動後網址會改變。"
                     + "YouTube 會拒絕未經處理的完整下載（超過 1 MiB 即回傳 403），"
                     + "而 YouTube Music 的歌曲也沒有 HLS 串流可用。"
                     + "在電腦上執行 tools/resolver/server.py，再用 cloudflared 對外，"
                     + "即可正常串流與拖曳進度；未設定時仍會嘗試直接播放。")
            }
        }
        .navigationTitle("串流伺服器")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { baseURLDraft = resolver.baseURL }
        .task { await resolver.checkHealth() }
    }
}
