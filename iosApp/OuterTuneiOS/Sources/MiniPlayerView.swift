import SwiftUI

struct MiniPlayerBarView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    let onExpand: () -> Void

    var body: some View {
        if let track = player.nowPlayingTrack {
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    Button(action: onExpand) {
                        HStack(spacing: 10) {
                            TrackArtworkView(
                                urlString: track.thumbnailURL,
                                dimension: 42,
                                cornerRadius: 8
                            )

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                    .lineLimit(1)
                                Text(track.artist)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .buttonStyle(.plain)

                    Spacer(minLength: 8)

                    Button(action: player.playPrevious) {
                        Image(systemName: "backward.fill")
                    }
                    .buttonStyle(.plain)

                    Button(action: player.togglePlayback) {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 17, weight: .semibold))
                    }
                    .buttonStyle(.plain)

                    Button(action: player.playNext) {
                        Image(systemName: "forward.fill")
                    }
                    .buttonStyle(.plain)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.2))
                        Capsule()
                            .fill(Color.accentColor)
                            .frame(width: proxy.size.width * progress)
                    }
                }
                .frame(height: 4)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 2)
        }
    }

    private var progress: CGFloat {
        guard player.duration > 0 else { return 0 }
        let ratio = player.sliderPosition / player.duration
        return CGFloat(min(max(ratio, 0), 1))
    }
}
