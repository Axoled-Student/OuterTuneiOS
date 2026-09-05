import SwiftUI

/// Build a station from a written description.
///
/// The model proposes songs and the server looks every one up on YouTube Music
/// before returning it, so a suggestion that does not exist never reaches the
/// queue as an unplayable row.
struct AIRadioView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @EnvironmentObject private var resolver: StreamResolverService
    @Environment(\.dismiss) private var dismiss

    @State private var prompt: String = ""
    @State private var isBuilding = false
    @State private var results: [AppTrack] = []
    @State private var errorMessage: String?

    private let examples = [
        "深夜讀書的 city pop",
        "energetic english workout songs",
        "sad japanese piano ballads",
        "2000s mandopop classics",
        "upbeat vocaloid for coding",
    ]

    var body: some View {
        NavigationView {
            List {
                Section {
                    // TextField(axis:) and ranged lineLimit are iOS 16+;
                    // this app targets iOS 15.
                    TextField("想聽什麼？例如：下雨天的爵士樂", text: $prompt)
                        .disabled(isBuilding)
                        .submitLabel(.go)
                        .onSubmit { Task { await build() } }

                    Button {
                        Task { await build() }
                    } label: {
                        if isBuilding {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("正在挑選歌曲…")
                            }
                        } else {
                            Label("建立電台", systemImage: "sparkles")
                        }
                    }
                    .disabled(isBuilding || trimmedPrompt.isEmpty || !resolver.isConfigured)
                } header: {
                    Text("AI 電台")
                } footer: {
                    if resolver.isConfigured {
                        Text("AI 只會挑選 YouTube Music 上真實存在的歌曲；找不到的建議會被丟棄。")
                    } else {
                        Text("需要先在「串流伺服器」設定伺服器網址。")
                            .foregroundColor(.orange)
                    }
                }

                if results.isEmpty, !isBuilding {
                    Section("試試看") {
                        ForEach(examples, id: \.self) { example in
                            Button(example) {
                                prompt = example
                                Task { await build() }
                            }
                            .disabled(!resolver.isConfigured)
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                }

                if !results.isEmpty {
                    Section {
                        Button {
                            player.playTracks(results)
                            dismiss()
                        } label: {
                            Label("播放全部（\(results.count) 首）", systemImage: "play.fill")
                        }
                    }

                    Section("曲目") {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, track in
                            Button {
                                player.playTracks(results, startingAt: index)
                                dismiss()
                            } label: {
                                HStack(spacing: 12) {
                                    TrackArtworkView(
                                        urlString: track.displayThumbnailURL,
                                        dimension: 44,
                                        cornerRadius: 6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(track.title)
                                            .font(.subheadline)
                                            .lineLimit(1)
                                        Text(track.artist)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .navigationTitle("AI 電台")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("關閉") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    private var trimmedPrompt: String {
        prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func build() async {
        let request = trimmedPrompt
        guard !request.isEmpty else { return }
        isBuilding = true
        errorMessage = nil
        defer { isBuilding = false }

        if let tracks = await resolver.fetchAIRadio(prompt: request, limit: 25) {
            results = tracks
        } else {
            results = []
            errorMessage = resolver.lastErrorMessage ?? "無法建立電台，請稍後再試。"
        }
    }
}
