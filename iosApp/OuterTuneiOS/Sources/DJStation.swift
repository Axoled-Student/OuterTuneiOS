import Foundation

/// The client half of the DJ loop.
///
/// The server does the thinking - it looks at the listening profile, picks a
/// theme, chooses songs for it, decides whether to say anything and speaks it.
/// This keeps the conversation going: it remembers the session, notices when
/// the current set is running out, asks for the next one, and reports back
/// what the listener skipped and what they sat through.
///
/// That last part is the loop closing. A station that never hears about the
/// skip button is just a playlist with a voice over it.
///
/// The player owns the queue; this owns the conversation. It never touches
/// playback directly - it hands sets to whoever asked for one and is told what
/// happened to them.
@MainActor
final class DJStation: ObservableObject {
    static let shared = DJStation()

    /// The theme of the set now playing, for the now-playing screen.
    @Published private(set) var theme: String?

    /// True while a set is being fetched. The first one takes several seconds
    /// and there is nothing to look at until it lands.
    @Published private(set) var isPreparing = false

    private(set) var isRunning = false

    private let resolver = StreamResolverService.shared
    private let dj = AIDJService.shared

    private var session: String?
    /// Descriptions of what happened since the last set was asked for, in the
    /// "Artist - Title" form the server plans against.
    private var skipped: [String] = []
    private var liked: [String] = []
    /// The last track of the set now playing. When this one starts, the next
    /// set is due.
    private var lastTrackOfSet: String?
    /// Guards against two overlapping requests for the same next set - the end
    /// of a set can be noticed twice when the listener skips into it.
    private var isFetching = false
    /// Bumped when the station stops, so a set that lands late cannot be
    /// appended to whatever is playing by then.
    private var generation = 0

    private init() {}

    /// Whatever the device is set to. The server folds a tag it has no voice
    /// for onto one it does, so anything here is safe.
    private var language: String {
        Locale.preferredLanguages.first ?? "en-US"
    }

    // MARK: Lifecycle

    /// The first set of a new station, or nil if the server could not build
    /// one. Nothing is remembered yet - call `begin` once it is playing.
    ///
    /// Fetching and committing are separate because starting playback replaces
    /// the queue, and replacing the queue ends whatever station was running.
    /// A station that recorded itself before the music started would be torn
    /// down by its own first song.
    func openingSet() async -> DJSet? {
        isPreparing = true
        dj.preparing(true)
        defer {
            isPreparing = false
            dj.preparing(false)
        }
        return await resolver.fetchDJSet(session: nil, language: language)
    }

    /// The opening set is playing. Remember it, and start listening.
    func begin(_ set: DJSet) {
        generation &+= 1
        isRunning = true
        isFetching = false
        session = set.session
        theme = set.theme.isEmpty ? nil : set.theme
        lastTrackOfSet = set.tracks.last?.stableId
        skipped.removeAll()
        liked.removeAll()
    }

    /// Playback has left the station.
    func stop() {
        generation &+= 1
        isRunning = false
        isPreparing = false
        session = nil
        theme = nil
        lastTrackOfSet = nil
        skipped.removeAll()
        liked.removeAll()
        dj.preparing(false)
    }

    // MARK: The loop

    /// A track started. Returns the next set when this one was the last of the
    /// current set, nil otherwise.
    ///
    /// Asking on the *start* of the final track rather than its end leaves a
    /// whole song of slack. The server has usually built the next set already,
    /// so the answer is back in well under a second - but the slack is what
    /// makes a slow one inaudible rather than a gap.
    func songStarted(_ track: AppTrack) async -> DJSet? {
        guard isRunning, track.stableId == lastTrackOfSet, !isFetching
        else { return nil }

        isFetching = true
        isPreparing = true
        dj.preparing(true)
        let mine = generation
        // Handed over now and cleared, so a set that fails does not report the
        // same skips again on the retry.
        let reportSkipped = skipped
        let reportLiked = liked
        skipped.removeAll()
        liked.removeAll()

        defer {
            isFetching = false
            isPreparing = false
            dj.preparing(false)
        }

        guard let set = await resolver.fetchDJSet(session: session,
                                                  language: language,
                                                  skipped: reportSkipped,
                                                  liked: reportLiked),
              generation == mine, isRunning
        else { return nil }

        session = set.session
        theme = set.theme.isEmpty ? nil : set.theme
        lastTrackOfSet = set.tracks.last?.stableId
        return set
    }

    /// A track finished or was left. This is the observation step of the loop.
    ///
    /// The threshold is deliberately generous. Reaching for the button eight
    /// seconds in is a verdict on the song; leaving it two minutes in is
    /// usually just leaving.
    func finished(_ track: AppTrack, listenedSeconds: Double, duration: Double) {
        guard isRunning else { return }
        let name = "\(track.artist) - \(track.title)"

        let heardMostOfIt = duration > 0 && listenedSeconds >= duration * 0.6
        if heardMostOfIt {
            if !liked.contains(name) { liked.append(name) }
        } else if listenedSeconds < 30 {
            if !skipped.contains(name) { skipped.append(name) }
        }
        // Between the two - a minute into a long song, then away - says
        // nothing either way, so it is not reported.
    }
}
