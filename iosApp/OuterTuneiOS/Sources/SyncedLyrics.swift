import SwiftUI

/// One timed line of an LRC transcript, with its translation when there is one.
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
    var translation: String?
}

/// Everything the player knows about the current track's words.
struct LyricsSnapshot: Equatable {
    var lines: [LyricLine] = []
    /// Transcripts that arrived without timestamps, shown as a block.
    var plain: String = ""
    var plainTranslated: String?
    /// What the words are written in, as the server detected it.
    var language: String?
    var source: String?
    var translated: Bool = false
    /// The server is running the translation now; ask again shortly.
    var translating: Bool = false

    var isEmpty: Bool { lines.isEmpty && plain.isEmpty }
    var isSynced: Bool { !lines.isEmpty }
}

/// Parses the LRC that lrclib returns.
///
/// The payload was already time-tagged; it was simply being printed verbatim,
/// so the timestamps showed up as literal `[00:12.34]` text and nothing
/// followed along with playback.
enum SyncedLyrics {
    static func parse(_ raw: String) -> [LyricLine] {
        guard !raw.isEmpty else { return [] }

        var lines: [LyricLine] = []
        var index = 0

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            var stamps: [Double] = []
            var cursor = line.startIndex

            // A line may carry several stamps: [00:12.34][01:02.00] shared text.
            while cursor < line.endIndex, line[cursor] == "[" {
                guard let close = line[cursor...].firstIndex(of: "]") else { break }
                let body = line[line.index(after: cursor) ..< close]
                if let seconds = parseTimestamp(String(body)) {
                    stamps.append(seconds)
                    cursor = line.index(after: close)
                } else {
                    // Metadata such as [ar: ...]; skip the tag, keep scanning.
                    cursor = line.index(after: close)
                }
            }

            let text = line[cursor...].trimmingCharacters(in: .whitespaces)
            guard !stamps.isEmpty, !text.isEmpty else { continue }

            for stamp in stamps {
                lines.append(LyricLine(id: index, time: stamp, text: text))
                index += 1
            }
        }

        return lines.sorted { $0.time < $1.time }
    }

    /// `mm:ss.xx`, `mm:ss`, or `hh:mm:ss.xx`.
    private static func parseTimestamp(_ value: String) -> Double? {
        let parts = value.split(separator: ":")
        guard parts.count >= 2 else { return nil }

        let secondsPart = parts[parts.count - 1]
        guard let seconds = Double(secondsPart) else { return nil }

        var total = seconds
        var multiplier = 60.0
        for part in parts.dropLast().reversed() {
            guard let unit = Double(part) else { return nil }
            total += unit * multiplier
            multiplier *= 60
        }
        return total
    }

    /// Index of the line that should be highlighted at `time`.
    static func activeIndex(in lines: [LyricLine], at time: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        var result: Int?
        for (offset, line) in lines.enumerated() {
            if line.time <= time + 0.15 {
                result = offset
            } else {
                break
            }
        }
        return result
    }
}

/// Scrolling, highlighted transcript.
///
/// Used at two sizes: the card inside the player, and the full-screen view.
/// Only the metrics differ, so they share this rather than drifting apart.
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let currentTime: Double
    var metrics: Metrics = .card
    var showsTranslation: Bool = true
    var onSeek: ((Double) -> Void)?

    struct Metrics {
        var size: CGFloat
        var spacing: CGFloat
        var translationSize: CGFloat
        /// How dim a line that is not being sung right now looks.
        var restingOpacity: Double
        var alignment: HorizontalAlignment = .leading
        var textAlignment: TextAlignment = .leading

        static let card = Metrics(size: 17, spacing: 14, translationSize: 13,
                                  restingOpacity: 0.55)
        /// Full screen: large enough to read at arm's length, and the resting
        /// lines fade further back so the current one carries the eye.
        static let fullScreen = Metrics(size: 27, spacing: 22,
                                        translationSize: 16,
                                        restingOpacity: 0.32)
    }

    private var activeIndex: Int? {
        SyncedLyrics.activeIndex(in: lines, at: currentTime)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: metrics.alignment, spacing: metrics.spacing) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { offset, line in
                        row(at: offset, line: line)
                    }
                }
                .padding(.vertical, 8)
            }
            .onChange(of: activeIndex) { index in
                guard let index, lines.indices.contains(index) else { return }
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo(lines[index].id, anchor: .center)
                }
            }
        }
    }

    @ViewBuilder
    private func row(at offset: Int, line: LyricLine) -> some View {
        let isActive = offset == activeIndex
        VStack(alignment: metrics.alignment, spacing: 4) {
            Text(line.text)
                .font(.system(size: metrics.size,
                              weight: isActive ? .bold : .semibold))
                .foregroundColor(isActive
                                 ? AppTheme.textPrimary
                                 : AppTheme.textSecondary.opacity(metrics.restingOpacity))

            if showsTranslation, let translation = line.translation,
               !translation.isEmpty {
                Text(translation)
                    .font(.system(size: metrics.translationSize,
                                  weight: .medium))
                    .foregroundColor(AppTheme.textPrimary
                        .opacity(isActive ? 0.72 : metrics.restingOpacity * 0.8))
            }
        }
        .multilineTextAlignment(metrics.textAlignment)
        .frame(maxWidth: .infinity, alignment: metrics.alignment == .center
               ? .center : .leading)
        .id(line.id)
        .contentShape(Rectangle())
        .onTapGesture { onSeek?(line.time) }
        .animation(.easeInOut(duration: 0.25), value: isActive)
    }
}
