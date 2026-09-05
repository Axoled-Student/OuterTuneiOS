import SwiftUI

#if os(iOS)
import UIKit
#endif

/// Derives a background colour from cover art.
///
/// The full-screen player takes its colour from the artwork, which is what
/// makes each track feel like its own space rather than a generic dark sheet.
/// Averaging a 1x1 downscale is enough: it is effectively free, and the result
/// is then pushed toward a deep, readable tone so white text always holds up.
@MainActor
final class ArtworkPalette: ObservableObject {
    static let shared = ArtworkPalette()

    @Published private(set) var colors: [String: Color] = [:]

    private var inFlight: Set<String> = []

    /// Shares URLCache with the artwork views, so the bytes are usually already
    /// on disk by the time a colour is wanted.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache.shared
        return URLSession(configuration: configuration)
    }()

    private init() {}

    /// Colour for a piece of artwork, loading it in the background if needed.
    func color(for urlString: String?) -> Color {
        guard let urlString, !urlString.isEmpty else { return AppTheme.surface }
        if let cached = colors[urlString] { return cached }
        load(urlString)
        return AppTheme.surface
    }

    private func load(_ urlString: String) {
#if os(iOS)
        guard !inFlight.contains(urlString), let url = URL(string: urlString) else {
            return
        }
        inFlight.insert(urlString)

        Task { [weak self] in
            defer { Task { @MainActor in self?.inFlight.remove(urlString) } }

            guard let session = await self?.session,
                  let data = try? await session.data(from: url).0,
                  let image = UIImage(data: data),
                  let average = Self.averageColor(of: image) else {
                return
            }
            await MainActor.run {
                self?.colors[urlString] = Color(average)
            }
        }
#endif
    }

#if os(iOS)
    /// Average colour, darkened and desaturated just enough that white text
    /// and controls stay legible on top of it.
    private static func averageColor(of image: UIImage) -> UIColor? {
        guard let cgImage = image.cgImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
            bytesPerRow: 4, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))

        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        UIColor(red: CGFloat(pixel[0]) / 255.0,
                green: CGFloat(pixel[1]) / 255.0,
                blue: CGFloat(pixel[2]) / 255.0,
                alpha: 1)
            .getHue(&hue, saturation: &saturation,
                    brightness: &brightness, alpha: &alpha)

        return UIColor(hue: hue,
                       saturation: min(saturation * 1.15, 0.72),
                       brightness: min(max(brightness * 0.55, 0.16), 0.42),
                       alpha: 1)
    }
#endif
}

/// The vertical wash behind the full-screen player: artwork colour at the top
/// fading into the app background.
struct ArtworkGradient: View {
    let artworkURL: String?
    @ObservedObject private var palette = ArtworkPalette.shared

    var body: some View {
        let top = palette.color(for: artworkURL)
        LinearGradient(
            stops: [
                .init(color: top, location: 0.0),
                .init(color: top.opacity(0.55), location: 0.35),
                .init(color: AppTheme.background, location: 0.85),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .animation(.easeInOut(duration: 0.45), value: top)
        .ignoresSafeArea()
    }
}
