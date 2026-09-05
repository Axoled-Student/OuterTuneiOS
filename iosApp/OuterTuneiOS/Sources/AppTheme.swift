import SwiftUI

/// Visual language for the app: a dark, art-forward layout in the style of the
/// large streaming clients.
///
/// Kept in one place so screens stay consistent, and so the palette can be
/// adjusted without hunting through views. Everything here is iOS 15 safe.
enum AppTheme {
    static let background = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let surface = Color(red: 0.11, green: 0.11, blue: 0.12)
    static let surfaceRaised = Color(red: 0.16, green: 0.16, blue: 0.17)
    static let accent = Color(red: 0.12, green: 0.78, blue: 0.47)
    static let accentSecondary = Color(red: 0.36, green: 0.42, blue: 0.95)
    static let textPrimary = Color.white
    static let textSecondary = Color(white: 0.68)

    static let tileCorner: CGFloat = 8
    static let cardCorner: CGFloat = 12

    /// Time-appropriate greeting, matching the "Good evening" header pattern.
    static var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5 ..< 12: return "早安"
        case 12 ..< 18: return "午安"
        default: return "晚安"
        }
    }

    /// A stable colour per title, so shelves and tiles look varied without
    /// needing artwork to have loaded yet.
    static func tint(for seed: String) -> Color {
        var hash = 5381
        for byte in seed.utf8 {
            hash = ((hash << 5) &+ hash) &+ Int(byte)
        }
        let hue = Double(abs(hash) % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.62)
    }
}

/// Section heading with the large, tight-tracking look used by music apps.
struct ShelfHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(AppTheme.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 16)
    }
}

/// Compact two-per-row entry used for the grid at the top of the home screen.
struct QuickTile: View {
    let title: String
    let artworkURL: String?
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                TrackArtworkView(urlString: artworkURL, dimension: 52,
                                 cornerRadius: 0)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8)
                Spacer(minLength: 0)
            }
            .frame(height: 52)
            .background(AppTheme.surfaceRaised)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

/// Large square tile for a horizontal shelf.
struct ShelfTile: View {
    let title: String
    let subtitle: String?
    let artworkURL: String?
    var rounded: Bool = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                TrackArtworkView(urlString: artworkURL,
                                 dimension: 148,
                                 cornerRadius: rounded ? 74 : AppTheme.tileCorner)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 148, height: 210, alignment: .topLeading)
        }
        .buttonStyle(.plain)
    }
}

/// The hero card that starts an automatic station in one tap.
struct DJCard: View {
    let isBuilding: Bool
    let subtitle: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(LinearGradient(
                            colors: [AppTheme.accent, AppTheme.accentSecondary],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 62, height: 62)
                    Image(systemName: isBuilding ? "waveform" : "sparkles")
                        .font(.system(size: 26, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("AI 電台")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundColor(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundColor(AppTheme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                if isBuilding {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(AppTheme.textPrimary)
                } else {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 34))
                        .foregroundColor(AppTheme.accent)
                }
            }
            .padding(12)
            .background(AppTheme.surfaceRaised)
            .cornerRadius(AppTheme.cardCorner)
        }
        .buttonStyle(.plain)
        .disabled(isBuilding)
    }
}
