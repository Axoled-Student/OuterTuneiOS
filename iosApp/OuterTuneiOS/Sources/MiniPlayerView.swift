import SwiftUI

/// The persistent bar above the tab bar.
///
/// Tinted from the artwork like the full player, with a hairline progress
/// track along the bottom edge rather than a full slider - it is a status
/// surface first and a control second.
struct MiniPlayerBarView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @ObservedObject private var palette = ArtworkPalette.shared

    let openNowPlaying: () -> Void

    var body: some View {
        if let track = player.nowPlayingTrack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    TrackArtworkView(urlString: track.displayThumbnailURL,
                                     dimension: 42, cornerRadius: 4)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(AppTheme.textPrimary)
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 11))
                            .foregroundColor(AppTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 4)

                    Button {
                        player.toggleFavoriteForNowPlaying()
                    } label: {
                        Image(systemName: player.isFavorite(track)
                              ? "checkmark.circle.fill" : "plus.circle")
                            .font(.system(size: 19))
                            .foregroundColor(player.isFavorite(track)
                                             ? AppTheme.accent
                                             : AppTheme.textSecondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.togglePlayback()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 20))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.playNext()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 17))
                            .foregroundColor(AppTheme.textPrimary)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                progressTrack
            }
            .background(
                palette.color(for: track.displayThumbnailURL)
                    .overlay(Color.white.opacity(0.06))
            )
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: 8, y: 3)
            .contentShape(Rectangle())
            .onTapGesture(perform: openNowPlaying)
        }
    }

    private var progressTrack: some View {
        GeometryReader { geometry in
            let total = max(player.duration, 1)
            let ratio = min(max(player.currentTime / total, 0), 1)
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.22))
                Rectangle()
                    .fill(AppTheme.textPrimary)
                    .frame(width: geometry.size.width * ratio)
            }
        }
        .frame(height: 2)
    }
}
