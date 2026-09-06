import AVFoundation
import Foundation

/// The voice between songs on an AI station.
///
/// The server writes the sentence and speaks it; this only decides *when* a
/// handover is worth having, fetches it early enough that nobody waits, and
/// plays it over the opening of the track it introduces with the music ducked
/// underneath. Ducking rather than pausing is deliberate: a gap of silence is
/// exactly where iOS suspends a backgrounded app, and it is also how a real
/// station sounds.
///
/// Everything here degrades to silence. A server that cannot reach the model,
/// a line that arrives after its song has already gone, a device with no
/// resolver configured - each means no DJ for that handover, never a stall in
/// playback.
@MainActor
final class AIDJService: ObservableObject {
    static let shared = AIDJService()

    /// Off by default. A voice talking over your music is not something to
    /// discover by accident.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled {
                stop()
                discardPrepared()
            }
        }
    }

    /// What the DJ is saying right now, for the now-playing screen. Cleared
    /// when the line finishes.
    @Published private(set) var spokenLine: String?

    /// Set by the player so the DJ can lower the music while it talks.
    var duck: ((Float) -> Void)?

    /// One line, then this many songs of quiet. Spotify's DJ speaks in bursts
    /// rather than before every track, and so does this.
    private static let songsBetweenLines = 3
    private static let enabledKey = "ios.aidj.enabled.v1"
    private static let duckedVolume: Float = 0.18

    private let resolver = StreamResolverService.shared
    private var prepared: [String: PreparedLine] = [:]
    private var inFlight: Set<String> = []
    private var speaker: AVAudioPlayer?
    private var unduckTask: Task<Void, Never>?

    /// Bumped whenever a station starts or ends, so a line fetched for the old
    /// one cannot be spoken over the new one.
    private var generation = 0
    private var songsSinceLine = 0
    private var hasSpokenThisStation = false
    private var stationTheme: String?
    private var isOnStation = false
    private var currentTrackId: String?

    private struct PreparedLine {
        let text: String
        let file: URL?
        let generation: Int
    }

    private init() {
        self.isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
    }

    /// The language the DJ speaks: whatever the device is set to. The server
    /// folds a tag it has no voice for onto one it does, so anything is safe.
    private var language: String {
        Locale.preferredLanguages.first ?? "en-US"
    }

    // MARK: Station lifecycle

    /// A new station has started on `opening`. Forget the last one and go and
    /// fetch the welcome.
    ///
    /// The opening line is the one exception to fetching a track ahead: there
    /// is no track ahead of the first. It is asked for while song one is
    /// already playing and spoken a few seconds in, which is what a station
    /// signing on sounds like anyway.
    func stationBegan(theme: String?, opening: AppTrack?) {
        generation &+= 1
        songsSinceLine = 0
        hasSpokenThisStation = false
        stationTheme = theme
        isOnStation = true
        currentTrackId = opening?.stableId
        discardPrepared()
        stop()
        if let opening {
            prepare(upcoming: opening, previous: nil)
        }
    }

    /// The station named itself after playback began, which is the normal case
    /// for a promptless one.
    func stationNamed(_ theme: String?) {
        guard isOnStation, let theme, !theme.isEmpty else { return }
        stationTheme = theme
    }

    /// Playback left the station - an ordinary queue, or nothing at all.
    func stationEnded() {
        generation &+= 1
        isOnStation = false
        stationTheme = nil
        currentTrackId = nil
        discardPrepared()
        stop()
    }

    // MARK: Per-track hooks

    /// Fetch a line for `upcoming` while something else is still playing.
    ///
    /// Called one track ahead on purpose: the round trip runs to the better
    /// part of ten seconds, and a line that arrives late is a line that never
    /// gets used.
    func prepare(upcoming: AppTrack, previous: AppTrack?) {
        guard isEnabled, isOnStation, resolver.isConfigured, isDue else { return }

        let key = upcoming.stableId
        // One at a time. A line that misses its own song still gets spoken a
        // few seconds late, and without this the next song's line would
        // already be queued behind it - two handovers back to back.
        guard prepared[key] == nil, inFlight.isEmpty else { return }
        inFlight.insert(key)

        let mine = generation
        let isFirst = !hasSpokenThisStation
        let theme = stationTheme
        Task { [weak self] in
            guard let self else { return }
            let line = await self.resolver.fetchDJLine(theme: theme,
                                                       previous: previous,
                                                       upcoming: upcoming,
                                                       language: self.language,
                                                       isFirst: isFirst)
            self.inFlight.remove(key)
            guard self.generation == mine, let line else { return }

            var file: URL?
            if let remote = line.audio {
                file = await Self.download(remote)
            }
            guard self.generation == mine else {
                Self.discard(file)
                return
            }
            self.prepared[key] = PreparedLine(text: line.text, file: file,
                                              generation: mine)
            // The opening line is asked for while its own song is already
            // playing, so it arrives a few seconds late and is spoken here
            // rather than at the start. Later lines are already waiting by
            // the time their song begins.
            self.deliver(for: key)
        }
    }

    /// `track` has just started. Speak over it if its line is ready.
    func songStarted(_ track: AppTrack) {
        currentTrackId = track.stableId
        songsSinceLine += 1
        deliver(for: track.stableId)
    }

    /// The listener skipped, paused, or the queue was replaced. Stop talking.
    func stop() {
        unduckTask?.cancel()
        unduckTask = nil
        if speaker != nil {
            speaker?.stop()
            speaker = nil
            duck?(1.0)
        }
        spokenLine = nil
    }

    // MARK: Internals

    /// The opening track always gets an introduction; after that the DJ waits
    /// out a few songs so a line stays an event rather than an interruption.
    private var isDue: Bool {
        !hasSpokenThisStation || songsSinceLine >= Self.songsBetweenLines
    }

    /// Play the line held for `key`, if it is for the song now playing and
    /// nothing else is being said.
    private func deliver(for key: String) {
        guard isEnabled, isOnStation, speaker == nil, currentTrackId == key,
              let line = prepared.removeValue(forKey: key),
              line.generation == generation
        else { return }

        songsSinceLine = 0
        hasSpokenThisStation = true
        spokenLine = line.text

        guard let file = line.file else {
            // Written but not spoken - the voice service was unreachable.
            // Showing the line is still better than nothing, and it has
            // already been counted so the cadence does not bunch up.
            let shown = line.text
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 6_000_000_000)
                guard let self, self.spokenLine == shown else { return }
                self.spokenLine = nil
            }
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: file)
            player.prepareToPlay()
            speaker = player
            duck?(Self.duckedVolume)
            player.play()

            // No delegate callback: AVAudioPlayerDelegate arrives off the main
            // actor, and the duration is known here anyway.
            let seconds = max(player.duration, 1) + 0.35
            unduckTask?.cancel()
            unduckTask = Task { [weak self] in
                try? await Task.sleep(
                    nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                self.speaker = nil
                self.spokenLine = nil
                self.unduckTask = nil
                self.duck?(1.0)
                Self.discard(file)
            }
        } catch {
            spokenLine = nil
            Self.discard(file)
            duck?(1.0)
        }
    }

    private func discardPrepared() {
        for line in prepared.values {
            Self.discard(line.file)
        }
        prepared.removeAll()
    }

    private nonisolated static func download(_ remote: URL) async -> URL? {
        do {
            let (data, response) = try await URLSession.shared.data(from: remote)
            guard (200 ..< 300).contains(
                    (response as? HTTPURLResponse)?.statusCode ?? 0),
                  !data.isEmpty
            else { return nil }
            // AVAudioPlayer sniffs the container and gets it wrong often
            // enough that the extension is worth setting.
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("djline-\(UUID().uuidString).mp3")
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            return nil
        }
    }

    private nonisolated static func discard(_ file: URL?) {
        guard let file else { return }
        try? FileManager.default.removeItem(at: file)
    }
}
