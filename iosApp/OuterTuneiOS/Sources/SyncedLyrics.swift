import SwiftUI

/// One timed line of an LRC transcript.
struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
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
struct SyncedLyricsView: View {
    let lines: [LyricLine]
    let currentTime: Double
    var onSeek: ((Double) -> Void)?

    private var activeIndex: Int? {
        SyncedLyrics.activeIndex(in: lines, at: currentTime)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(Array(lines.enumerated()), id: \.element.id) { offset, line in
                        Text(line.text)
                            .font(.system(size: 17, weight: offset == activeIndex
                                          ? .bold : .semibold))
                            .foregroundColor(offset == activeIndex
                                             ? AppTheme.textPrimary
                                             : AppTheme.textSecondary.opacity(0.55))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                            .onTapGesture { onSeek?(line.time) }
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
}
