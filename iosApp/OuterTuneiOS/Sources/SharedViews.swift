import SwiftUI

/// 顯示曲目專輯縮圖，若無 URL 則顯示占位圖示。
struct TrackArtworkView: View {
    let urlString: String?
    let dimension: CGFloat
    let cornerRadius: CGFloat

    var body: some View {
        Group {
            if let urlString,
               let url = URL(string: urlString),
               !urlString.isEmpty {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    artworkPlaceholder
                }
            } else {
                artworkPlaceholder
            }
        }
        .frame(width: dimension, height: dimension)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private var artworkPlaceholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color.secondary.opacity(0.18))
            Image(systemName: "music.note")
                .font(.system(size: max(dimension * 0.28, 14), weight: .semibold))
                .foregroundColor(.secondary)
        }
    }
}

struct AudioInfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .foregroundColor(.secondary)
            Spacer(minLength: 16)
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }
}

/// 供搜尋列 / URL 欄位套用 iOS 鍵盤行為。
extension View {
    @ViewBuilder
    func noAutoInputAdjustments() -> some View {
#if os(iOS)
        self
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled(true)
#else
        self
#endif
    }

    @ViewBuilder
    func urlKeyboardIfAvailable() -> some View {
#if os(iOS)
        self.keyboardType(.URL)
#else
        self
#endif
    }
}

/// 通用歌曲 row（專輯圖 + 標題 + 副標題 + 尾端區）。
struct TrackRowView<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let thumbnailURL: String?
    let onTap: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            TrackArtworkView(urlString: thumbnailURL, dimension: 52, cornerRadius: 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/// 區塊標題（iOS 風格大標 + strapline）。
struct SectionHeaderView: View {
    let title: String
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.title3)
                .fontWeight(.bold)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal)
    }
}
