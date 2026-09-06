import CoreGraphics
import Foundation

#if os(iOS)
import UIKit
#endif

/// Rewrites YouTube artwork URLs to ask for the size actually being drawn.
///
/// InnerTube offers most rows nothing larger than 120x120 - measured against
/// the live search endpoint, 20 of 33 thumbnail sets topped out there. Taking
/// the largest on offer therefore meant a 3x display stretching 120px over a
/// 148pt tile: a four-fold upscale, and the reason covers looked soft
/// everywhere rather than only on cellular.
///
/// The size is not a property of the image, though. googleusercontent re-encodes
/// to whatever `=w<n>-h<n>` it is handed; asking the same cover for 60, 226,
/// 544, 1080 and 2000 pixels returned each size exactly, at 3KB, 14KB, 57KB,
/// 142KB and 450KB. So the right size is a decision this app gets to make, and
/// it is worth making per view rather than once at parse time.
enum ArtworkURL {
    /// Pixel sizes we are willing to ask for.
    ///
    /// Requests are quantised onto this ladder so a 52pt row and a 56pt row
    /// share one cached file instead of fetching two near-identical covers.
    static let ladder: [Int] = [120, 226, 320, 544, 720, 1080, 1440]

    /// Pixels per point on this device. `UIScreen.main` is deprecated and
    /// carries no meaning under multiple scenes, so this reads the trait
    /// collection instead and falls back to 2x if it reports nothing useful.
    @MainActor
    static var displayScale: CGFloat {
#if os(iOS)
        let scale = UITraitCollection.current.displayScale
        return scale > 0 ? scale : 2
#else
        return 2
#endif
    }

    /// The URL to draw a cover of `points` a side, sized for this screen and
    /// trimmed to what the current connection should be asked to carry.
    @MainActor
    static func sized(_ urlString: String?, forPoints points: CGFloat) -> String? {
        guard let urlString, !urlString.isEmpty else { return nil }
        let conditions = NetworkConditions.shared
        let wanted = Int((points * conditions.artworkScale).rounded(.up))
        return rewrite(urlString,
                       toPixels: step(for: min(wanted, conditions.artworkPixelCap)))
    }

    /// Smallest ladder rung that still covers `pixels`.
    static func step(for pixels: Int) -> Int {
        ladder.first { $0 >= pixels } ?? ladder[ladder.count - 1]
    }

    /// Pure rewriting, with no opinion about the screen or the network.
    /// Anything unrecognised is returned untouched rather than guessed at.
    static func rewrite(_ urlString: String, toPixels target: Int) -> String {
        guard target > 0 else { return urlString }
        if let resized = rewriteGooglePhoto(urlString, target: target) {
            return resized
        }
        if let resized = rewriteYtImg(urlString, target: target) {
            return resized
        }
        return urlString
    }

    // MARK: - googleusercontent / ggpht

    /// `...=w120-h120-l90-rj` -> `...=w544-h544-l90-rj`, trailing flags kept.
    ///
    /// The aspect ratio is preserved and the *shorter* side is what meets the
    /// target, because these are drawn with `scaledToFill` into a square:
    /// matching the long side would leave the short one short and soft.
    private static func rewriteGooglePhoto(_ urlString: String,
                                           target: Int) -> String? {
        guard let range = urlString.range(of: "=w[0-9]+-h[0-9]+",
                                          options: .regularExpression) else {
            return rewriteSizeToken(urlString, target: target)
        }

        let pair = urlString[range].dropFirst(2).components(separatedBy: "-h")
        guard pair.count == 2,
              let width = Int(pair[0]), let height = Int(pair[1]),
              width > 0, height > 0 else {
            return nil
        }

        let factor = Double(target) / Double(min(width, height))
        let newWidth = max(1, Int((Double(width) * factor).rounded()))
        let newHeight = max(1, Int((Double(height) * factor).rounded()))
        return urlString.replacingCharacters(
            in: range, with: "=w\(newWidth)-h\(newHeight)")
    }

    /// Channel avatars use a single `=s<n>` edge instead of a width/height pair.
    ///
    /// This form is capped server-side: asking for 1080 returns 1000x1000,
    /// where the `=w`/`=h` form honours sizes up to at least 2000. Nothing to
    /// work around - a 1000px avatar is past anything the app draws - but it
    /// is why the size delivered here can come back smaller than requested.
    private static func rewriteSizeToken(_ urlString: String,
                                         target: Int) -> String? {
        guard let range = urlString.range(of: "=s[0-9]+",
                                          options: .regularExpression) else {
            return nil
        }
        return urlString.replacingCharacters(in: range, with: "=s\(target)")
    }

    // MARK: - i.ytimg

    /// i.ytimg publishes a fixed set of named sizes rather than arbitrary ones.
    ///
    /// Only `hqdefault` is there for every video: across 25 ids sampled from
    /// live search, hqdefault was present 25/25 while sddefault and
    /// maxresdefault were each missing one. Hence `fallback(for:)`.
    private static let ytImgHost = "i.ytimg.com/vi"

    private static let ytImgNames = [
        "default",          // 120x90
        "mqdefault",        // 320x180
        "hqdefault",        // 480x360 - always present
        "sddefault",        // 640x480
        "hq720",            // 1280x720, the form signed URLs tend to use
        "maxresdefault",    // 1280x720
    ]

    private static func rewriteYtImg(_ urlString: String,
                                     target: Int) -> String? {
        guard urlString.contains(ytImgHost) else { return nil }
        let wanted: String
        switch target {
        case ..<200: wanted = "mqdefault"
        case ..<420: wanted = "hqdefault"
        case ..<700: wanted = "sddefault"
        default: wanted = "maxresdefault"
        }
        return replacingYtImgName(urlString, with: wanted)
    }

    /// `hqdefault` is the guaranteed rung; nothing below it needs a fallback.
    private static let guaranteedIndex = 2

    /// The variant to try when a larger one turned out not to be published.
    ///
    /// Drops straight to `hqdefault` rather than walking down a rung at a time:
    /// it is the one size always present, so a single retry settles it.
    static func fallback(for urlString: String) -> String? {
        guard urlString.contains(ytImgHost),
              let current = ytImgName(in: urlString),
              let index = ytImgNames.firstIndex(of: current),
              index > guaranteedIndex else {
            return nil
        }
        return replacingYtImgName(urlString, with: "hqdefault")
    }

    /// The path, without any query. InnerTube hands out signed `?sqp=...`
    /// thumbnail URLs whose signature covers the size that was asked for, so
    /// the query cannot survive a rename - and does not need to, since the
    /// unsigned form of these files is publicly served.
    private static func ytImgPath(_ urlString: String) -> Substring {
        if let question = urlString.firstIndex(of: "?") {
            return urlString[..<question]
        }
        return urlString[...]
    }

    private static func ytImgName(in urlString: String) -> String? {
        let path = ytImgPath(urlString)
        guard let slash = path.lastIndex(of: "/") else { return nil }
        let file = path[path.index(after: slash)...]
        let name = file.split(separator: ".").first.map(String.init)
        return name.flatMap { ytImgNames.contains($0) ? $0 : nil }
    }

    /// Keeps the directory and extension: `/vi_webp/` serves `.webp` only, and
    /// asking it for a `.jpg` is a 404.
    private static func replacingYtImgName(_ urlString: String,
                                           with name: String) -> String? {
        let path = ytImgPath(urlString)
        guard let current = ytImgName(in: urlString), current != name,
              let slash = path.lastIndex(of: "/") else {
            return nil
        }
        let file = path[path.index(after: slash)...]
        let ext = file.firstIndex(of: ".").map { String(file[$0...]) } ?? ".jpg"
        return String(path[...slash]) + name + ext
    }
}
