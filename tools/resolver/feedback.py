"""Learns from what actually gets played and what gets skipped.

Explicit ratings are rare; skips are abundant and honest. A track dropped in the
first few seconds is a rejection, one played to the end is an endorsement, and
the same signal aggregated over an artist says whether to keep offering them at
all.

Stored on disk so the model survives a restart, and applied as a multiplier on
candidate relevance rather than a hard filter, so one bad night does not
permanently bury an artist.
"""
import json
import os
import threading
import time

STORE = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".feedback.json")

# A skip inside this many seconds counts as a rejection rather than a mis-tap.
SKIP_SECONDS = 20
# Fraction of a track that has to play before it counts as a completion.
COMPLETE_RATIO = 0.8


class FeedbackStore:
    def __init__(self, path=STORE):
        self.path = path
        self._lock = threading.Lock()
        self.tracks = {}
        self.artists = {}
        self._load()

    # ---------------------------------------------------------------- io

    def _load(self):
        if not os.path.exists(self.path):
            return
        try:
            with open(self.path, encoding="utf-8") as fh:
                data = json.load(fh)
            self.tracks = data.get("tracks", {})
            self.artists = data.get("artists", {})
        except Exception:  # noqa: BLE001
            self.tracks, self.artists = {}, {}

    def _save(self):
        try:
            tmp = self.path + ".tmp"
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump({"tracks": self.tracks, "artists": self.artists}, fh)
            os.replace(tmp, self.path)
        except Exception:  # noqa: BLE001
            pass

    # ------------------------------------------------------------ record

    def record(self, track_key, artist_key, played_seconds, duration,
               explicit=None, title=None, artist=None):
        """Register one playback outcome.

        `explicit` is "like"/"dislike" when the user says so directly; otherwise
        the outcome is inferred from how much of the track played.
        """
        played = max(float(played_seconds or 0), 0.0)
        total = float(duration or 0)
        ratio = (played / total) if total > 0 else 0.0

        if explicit == "dislike":
            outcome = "skip"
        elif explicit == "like":
            outcome = "complete"
        elif total > 0 and ratio >= COMPLETE_RATIO:
            outcome = "complete"
        elif played <= SKIP_SECONDS:
            outcome = "skip"
        else:
            outcome = "partial"

        with self._lock:
            for store, key in ((self.tracks, track_key), (self.artists, artist_key)):
                if not key:
                    continue
                row = store.setdefault(key, {"skips": 0, "completes": 0,
                                             "partials": 0, "seen": 0,
                                             "updated": 0})
                # Keep the human-readable name so home shelves can be seeded
                # from what was actually played, not just counted.
                if store is self.tracks and title:
                    row["title"] = title
                    row["artist"] = artist or ""
                row["seen"] += 1
                row["updated"] = int(time.time())
                if outcome == "skip":
                    row["skips"] += 1
                elif outcome == "complete":
                    row["completes"] += 1
                else:
                    row["partials"] += 1
            self._save()
        return outcome

    # ------------------------------------------------------------- score

    @staticmethod
    def _bias(row):
        """Signed preference in roughly [-1, 1] from one row of counts."""
        if not row:
            return 0.0
        skips = row.get("skips", 0)
        completes = row.get("completes", 0)
        partials = row.get("partials", 0)
        total = skips + completes + partials
        if total <= 0:
            return 0.0
        raw = (completes - skips) / float(total)
        # Confidence grows with evidence: a single skip should nudge, not damn.
        confidence = min(total / 4.0, 1.0)
        return raw * confidence

    def multiplier(self, track_key, artist_key):
        """Relevance multiplier for a candidate.

        Track evidence dominates; the artist's record only shades it, so one
        disliked song does not remove an otherwise-loved artist.
        """
        with self._lock:
            track_bias = self._bias(self.tracks.get(track_key))
            artist_bias = self._bias(self.artists.get(artist_key))
        combined = 0.75 * track_bias + 0.25 * artist_bias
        # Map [-1, 1] onto [0.35, 1.5]: a rejected track can still resurface if
        # everything else about it is a strong match, but it starts far behind.
        if combined >= 0:
            return 1.0 + 0.5 * combined
        return 1.0 + 0.65 * combined

    def is_rejected(self, track_key):
        """Repeatedly skipped and never finished - stop offering it."""
        with self._lock:
            row = self.tracks.get(track_key)
        if not row:
            return False
        return row.get("skips", 0) >= 3 and row.get("completes", 0) == 0

    def liked_tracks(self, limit=40):
        """Tracks the listener actually finished, most recent first.

        This is first-hand evidence from this app, as opposed to the Spotify
        profile, which reflects listening that happened somewhere else.
        """
        with self._lock:
            rows = [dict(row, key=key) for key, row in self.tracks.items()
                    if row.get("title") and row.get("completes", 0) > 0
                    and row.get("completes", 0) >= row.get("skips", 0)]
        rows.sort(key=lambda r: -r.get("updated", 0))
        return [{"title": r["title"], "artist": r.get("artist", ""),
                 "completes": r.get("completes", 0)} for r in rows[:limit]]

    def summary(self):
        with self._lock:
            tracks = len(self.tracks)
            artists = len(self.artists)
            skips = sum(r.get("skips", 0) for r in self.tracks.values())
            completes = sum(r.get("completes", 0) for r in self.tracks.values())
            worst = sorted(self.artists.items(), key=lambda kv: self._bias(kv[1]))[:5]
            best = sorted(self.artists.items(),
                          key=lambda kv: -self._bias(kv[1]))[:5]
        return {
            "tracks": tracks, "artists": artists,
            "skips": skips, "completes": completes,
            "leastLiked": [{"artist": a, "bias": round(self._bias(r), 3)}
                           for a, r in worst if self._bias(r) < 0],
            "mostLiked": [{"artist": a, "bias": round(self._bias(r), 3)}
                          for a, r in best if self._bias(r) > 0],
        }
