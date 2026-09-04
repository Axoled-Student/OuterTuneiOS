import Foundation

#if os(iOS)
import UIKit
#endif

/// Holds a UIKit background-task assertion for as long as playback needs the
/// process to stay alive.
///
/// The `audio` background mode only keeps the app running while audio is
/// *actually* rendering. Advancing to the next track means resolving streams
/// and downloading them, and during that window nothing is playing - which is
/// exactly when iOS is free to suspend the process. That is what made playback
/// die in the background after the first track. Every gap between "the old item
/// stopped" and "the new item started" is wrapped in one of these assertions.
///
/// Nested requests are reference counted, so overlapping work (a prefetch that
/// straddles a track change) keeps a single assertion alive rather than ending
/// it early.
@MainActor
final class BackgroundActivityGuard {
    static let shared = BackgroundActivityGuard()

#if os(iOS)
    private var identifier: UIBackgroundTaskIdentifier = .invalid
#endif
    private var depth = 0

    func begin(_ name: String) {
        depth += 1
#if os(iOS)
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            // The system is reclaiming the assertion; release it so we are not
            // killed outright.
            self?.expire()
        }
#endif
    }

    func end() {
        depth = max(0, depth - 1)
        guard depth == 0 else { return }
        expire()
    }

    private func expire() {
#if os(iOS)
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
#endif
        depth = 0
    }
}

/// Runs `body` while holding a background assertion.
@MainActor
func withBackgroundActivity<T>(
    _ name: String,
    _ body: () async throws -> T
) async rethrows -> T {
    BackgroundActivityGuard.shared.begin(name)
    defer { BackgroundActivityGuard.shared.end() }
    return try await body()
}

/// How the queue behaves when a track finishes.
enum RepeatMode: String, Codable, CaseIterable, Identifiable {
    case off
    case all
    case one

    var id: String { rawValue }

    var next: RepeatMode {
        switch self {
        case .off: return .all
        case .all: return .one
        case .one: return .off
        }
    }

    var systemImageName: String {
        switch self {
        case .off, .all: return "repeat"
        case .one: return "repeat.1"
        }
    }

    var isEnabled: Bool { self != .off }
}

/// A track that has already been resolved and downloaded to a local file,
/// ready to hand straight to AVPlayer with no network round-trip.
struct PreparedPlayback {
    let trackStableId: String
    let localURL: URL
    let stream: AudioStreamOption

    /// Prepared files live in the temporary directory and may be reaped by the
    /// system between the prefetch and the track change.
    var isStillAvailable: Bool {
        FileManager.default.fileExists(atPath: localURL.path)
    }
}
