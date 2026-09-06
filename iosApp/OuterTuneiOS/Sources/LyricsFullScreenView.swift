import SwiftUI

/// The words, given the whole screen.
///
/// The card inside the player only fits a handful of lines, which is fine while
/// glancing but not while actually reading along - and it has no room at all for
/// a translation under each line. This is the same transcript at reading size,
/// over the artwork's own colour, with the transport left in reach so following
/// the words never means leaving playback behind.
struct LyricsFullScreenView: View {
    @EnvironmentObject private var player: AudioPlayerViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            ArtworkGradient(artworkURL: player.nowPlayingTrack?.displayThumbnailURL)
            Color.black.opacity(0.28).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                transcript
                    .frame(maxHeight: .infinity)
                transport
            }
            .padding(.horizontal, 22)
            .padding(.top, 10)
        }
        .onAppear {
            // Opened straight from a track whose words were never asked for.
            if player.lyrics.isEmpty, !player.isLoadingLyrics {
                player.loadLyricsForCurrentTrack()
            }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(player.nowPlayingTrack?.title ?? "歌詞")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundColor(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
            translationToggle
        }
        .padding(.bottom, 14)
    }

    private var subtitle: String {
        let artist = player.nowPlayingTrack?.artist ?? ""
        if player.lyrics.translating {
            return artist.isEmpty ? "翻譯中…" : "\(artist) · 翻譯中…"
        }
        return artist
    }

    /// Off is a real preference, not a fallback: plenty of listeners read the
    /// original and find a second column in the way.
    private var translationToggle: some View {
        Button {
            player.lyricsTranslationEnabled.toggle()
        } label: {
            HStack(spacing: 5) {
                if player.lyrics.translating, player.lyricsTranslationEnabled {
                    ProgressView()
                        .scaleEffect(0.6)
                        .tint(AppTheme.textPrimary)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 12, weight: .semibold))
                }
                Text("翻譯")
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundColor(player.lyricsTranslationEnabled
                             ? Color.black : AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(player.lyricsTranslationEnabled
                               ? AppTheme.accent
                               : Color.white.opacity(0.16))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Body

    @ViewBuilder
    private var transcript: some View {
        let lyrics = player.lyrics

        if lyrics.isSynced {
            SyncedLyricsView(lines: lyrics.lines,
                             currentTime: player.currentTime,
                             metrics: .fullScreen,
                             showsTranslation: player.lyricsTranslationEnabled) { time in
                player.seekTo(time)
            }
        } else if !lyrics.plain.isEmpty {
            // No timestamps came back, so nothing can follow along - but the
            // words are still worth reading.
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    Text(lyrics.plain)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(AppTheme.textPrimary.opacity(0.9))
                    if player.lyricsTranslationEnabled,
                       let translated = lyrics.plainTranslated,
                       !translated.isEmpty {
                        Text(translated)
                            .font(.system(size: 15))
                            .foregroundColor(AppTheme.textPrimary.opacity(0.62))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 12)
            }
        } else {
            VStack(spacing: 10) {
                Spacer()
                if player.isLoadingLyrics {
                    ProgressView().tint(AppTheme.textSecondary)
                    Text("載入歌詞…")
                } else {
                    Image(systemName: "quote.bubble")
                        .font(.system(size: 30))
                    Text("找不到這首歌的歌詞")
                }
                Spacer()
            }
            .font(.system(size: 14))
            .foregroundColor(AppTheme.textSecondary)
            .frame(maxWidth: .infinity)
        }
    }

    private var transport: some View {
        HStack(spacing: 34) {
            Button { player.playPrevious() } label: {
                Image(systemName: "backward.fill").font(.system(size: 22))
            }
            Button { player.togglePlayback() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 26))
                    .frame(width: 58, height: 58)
                    .background(Circle().fill(AppTheme.textPrimary))
                    .foregroundColor(.black)
            }
            Button { player.playNext() } label: {
                Image(systemName: "forward.fill").font(.system(size: 22))
            }
        }
        .foregroundColor(AppTheme.textPrimary)
        .padding(.top, 12)
        .padding(.bottom, 22)
    }
}
