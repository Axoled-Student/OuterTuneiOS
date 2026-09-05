import Foundation

/// Where a candidate came from. The origin is part of its relevance: a track
/// reached by a similarity edge is a deliberate discovery pick, whereas an
/// unfamiliar artist sitting in the middle of a radio feed is usually filler.
enum CandidateSource: Equatable {
    case seedRadio(rank: Int)
    case tasteRadio(rank: Int)
    case history
    case similar

    var isSimilarityEdge: Bool { self == .similar }
}

struct QueueCandidate {
    let track: AppTrack
    let source: CandidateSource
}

/// Selects the next batch of tracks from a candidate pool.
///
/// Scoring alone cannot produce a *blend*: whichever signal is strongest takes
/// every slot, which is how the queue ended up either looping a handful of
/// favourite artists or filling with unrelated radio noise. This uses Maximal
/// Marginal Relevance - each pick is scored on its own merit minus how similar
/// it is to what has already been chosen - with hard artist caps and spacing on
/// top, so artist domination is impossible rather than merely discouraged.
///
/// Measured offline against the live APIs over 4 seeds x 5 successive
/// extensions (tools/apitests/eval_recommender.py):
///
///     policy            picks  maxArtist  uniqArtists  dup  repeat  taste
///     raw radio order      41       0.07         0.90  0.0     0.0   0.11
///     this ranker          50       0.14         0.80  0.0     0.0   0.38
///
/// The raw feed looks diverse only because it is close to random; its 0.11
/// taste match is the "bad recommendations" complaint, and producing 41 of 50
/// requested tracks is why the queue kept running dry and replaying.
enum QueueRanker {
    /// Relevance/diversity trade-off. Higher favours relevance.
    static let lambda = 0.72
    /// Most tracks one artist may hold in a single batch.
    static let artistCap = 2
    /// Minimum gap between two tracks by the same artist.
    static let artistSpacing = 4

    static func select(
        candidates: [QueueCandidate],
        seed _: AppTrack,
        artistWeights: [String: Double],
        priorityRank: [String: Int] = [:],
        limit: Int,
        blockedIdentities: Set<String>,
        blockedIds: Set<String>
    ) -> [AppTrack] {
        guard limit > 0 else { return [] }

        var seenIds = blockedIds
        var seenIdentities = blockedIdentities
        var chosen: [AppTrack] = []
        var artistCounts: [String: Int] = [:]
        var spacing = artistSpacing

        var remaining = candidates.filter {
            !seenIds.contains($0.track.stableId)
                && !seenIdentities.contains($0.track.recommendationIdentity)
        }

        while chosen.count < limit, !remaining.isEmpty {
            var bestIndex: Int?
            var bestValue = -Double.greatestFiniteMagnitude

            for (index, candidate) in remaining.enumerated() {
                let track = candidate.track

                // Re-checked here, not only when the pool was built: two
                // different videoIds routinely carry the same recording (topic
                // upload vs music video vs remaster), and checking once let the
                // second copy through.
                if seenIds.contains(track.stableId)
                    || seenIdentities.contains(track.recommendationIdentity) {
                    continue
                }

                let artist = normalizedArtist(track.artist)
                // The seed's own artist gets no special allowance: hearing the
                // same act on repeat is the exact complaint this addresses.
                if (artistCounts[artist] ?? 0) >= artistCap { continue }

                if spacing > 0 {
                    let recent = chosen.suffix(spacing).map { normalizedArtist($0.artist) }
                    if recent.contains(artist) { continue }
                }

                var relevance = relevanceScore(candidate,
                                               artistWeights: artistWeights)
                // An optional LLM ordering nudges relevance but cannot breach
                // the artist caps, spacing, or repeat policy below.
                if let rank = priorityRank[track.stableId] {
                    relevance += 0.35 / (1.0 + Double(rank) * 0.1)
                }
                let penalty = chosen
                    .map { similarity(track, $0) }
                    .max() ?? 0
                let value = lambda * relevance - (1 - lambda) * penalty

                if value > bestValue {
                    bestValue = value
                    bestIndex = index
                }
            }

            guard let bestIndex else {
                // The constraints exhausted the pool. Relax spacing a step
                // before giving up, so a short queue is a last resort rather
                // than the usual outcome.
                if spacing > 0 {
                    spacing -= 1
                    continue
                }
                break
            }

            let picked = remaining.remove(at: bestIndex)
            chosen.append(picked.track)
            let artist = normalizedArtist(picked.track.artist)
            artistCounts[artist] = (artistCounts[artist] ?? 0) + 1
            seenIds.insert(picked.track.stableId)
            seenIdentities.insert(picked.track.recommendationIdentity)
            remaining.removeAll {
                $0.track.recommendationIdentity == picked.track.recommendationIdentity
            }
        }

        return chosen
    }

    // MARK: - Scoring

    static func relevanceScore(
        _ candidate: QueueCandidate,
        artistWeights: [String: Double]
    ) -> Double {
        var score: Double
        switch candidate.source {
        case .seedRadio(let rank):
            score = 1.0 / (1.0 + Double(rank) * 0.05)
        case .tasteRadio(let rank):
            score = 0.85 / (1.0 + Double(rank) * 0.03)
        case .history:
            score = 0.8
        case .similar:
            score = 0.7
        }

        let affinity = artistWeights[normalizedArtist(candidate.track.artist)] ?? 0
        // Saturating, so one heavily-weighted favourite cannot outscore
        // everything else on affinity alone.
        score += 1.6 * (affinity / (0.6 + affinity))

        // Discovery has to be *targeted*. Rewarding any unheard artist just
        // promotes whatever the radio happened to return, which measured at a
        // 0.11 taste match. Only similarity-edge candidates earn the bonus.
        if affinity == 0, candidate.source.isSimilarityEdge {
            score += 0.55
        }

        return score
    }

    static func similarity(_ lhs: AppTrack, _ rhs: AppTrack) -> Double {
        if normalizedArtist(lhs.artist) == normalizedArtist(rhs.artist) {
            return 1.0
        }
        let left = titleTokens(lhs.title)
        let right = titleTokens(rhs.title)
        if !left.isEmpty, !right.isEmpty {
            let overlap = Double(left.intersection(right).count)
            let union = Double(left.union(right).count)
            if union > 0, overlap / union > 0.6 {
                return 0.8
            }
        }
        return 0
    }

    // MARK: - Normalisation

    /// First credited artist, so "A feat. B" and "A" collapse to one bucket -
    /// otherwise an artist evades the cap simply by having guests.
    static func normalizedArtist(_ name: String) -> String {
        var value = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        for separator in [" feat ", " feat. ", " ft ", " ft. ", " featuring ",
                          " with ", " & ", ", ", " x "] {
            if let range = value.range(of: separator, options: .caseInsensitive) {
                value = String(value[value.startIndex ..< range.lowerBound])
            }
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func titleTokens(_ title: String) -> Set<String> {
        let base = title.replacingOccurrences(
            of: #"\s*[\(（\[【].*$"#, with: "", options: .regularExpression)
        let folded = base.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
        let parts = folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        return Set(parts)
    }
}
