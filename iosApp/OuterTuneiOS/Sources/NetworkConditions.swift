import Foundation
import Network

/// Whether the current network path is one where bytes are worth conserving.
///
/// Prefetching a track is not, in itself, extra traffic: it moves bytes that
/// playback would have fetched anyway to a moment when the listener is not
/// waiting on them. It only costs data when the listener skips past the track
/// that was fetched, so the lookahead shrinks as the connection gets more
/// expensive rather than being switched off outright.
@MainActor
final class NetworkConditions: ObservableObject {
    static let shared = NetworkConditions()

    /// Cellular, or tethered to something that is. iOS reports both as expensive.
    @Published private(set) var isExpensive = false

    /// Low Data Mode, either for this network or system-wide.
    @Published private(set) var isConstrained = false

    private let monitor = NWPathMonitor()

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let expensive = path.isExpensive
            let constrained = path.isConstrained
            Task { @MainActor in
                self?.isExpensive = expensive
                self?.isConstrained = constrained
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.outertune.network-conditions"))
    }

    /// How many upcoming tracks to pull onto the device ahead of time.
    var prefetchDepth: Int {
        if isConstrained { return 0 }
        return isExpensive ? 1 : 2
    }

    /// On an expensive path, wait until the listener has actually settled into
    /// a track before fetching the next one. A skipped track is the only case
    /// where a prefetch turns into wasted data, and skips happen early.
    var prefetchAfterSeconds: Double {
        isExpensive ? 25 : 0
    }

    /// How far AVPlayer may buffer ahead of the playhead, in seconds.
    ///
    /// Zero means "use AVPlayer's own judgement", which is right on Wi-Fi. On
    /// cellular an unbounded read-ahead means a track abandoned after ten
    /// seconds may already have been paid for in full.
    var forwardBufferSeconds: Double {
        if isConstrained { return 45 }
        return isExpensive ? 90 : 0
    }

    /// Human-readable label for the settings screen.
    var summary: String {
        if isConstrained { return "低數據模式" }
        return isExpensive ? "行動網路" : "Wi-Fi"
    }
}
