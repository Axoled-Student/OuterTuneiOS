"""Server-side auto-queue generation.

Runs the recommendation algorithm on the machine that already holds the
Spotify tokens and the YouTube session, so it can be changed without rebuilding
and reinstalling the app. The iOS client just asks for a queue and plays it.

The policy here is the one measured in tools/apitests/eval_recommender.py over
6 seeds x 5 successive extensions against the live APIs:

    metric                raw radio order   this policy
    picks delivered             40/50            50/50
    seed-artist share            0.09             0.03
    max artist share             0.12             0.06
    unique artists               0.87             0.90
    duplicate recordings         0.00             0.00
    repeats across batches       0.00             0.00
    Spotify taste match          0.17             0.29
"""
import json
import os
import re
import threading
import time
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
APITESTS = os.path.join(os.path.dirname(HERE), "apitests")

UA_WEB = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) "
          "Gecko/20100101 Firefox/128.0")
WEB_REMIX = {"clientName": "WEB_REMIX", "clientVersion": "1.20250310.01.00",
             "clientId": "67"}
SEARCH_SONGS_PARAMS = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

# ---------------------------------------------------------------- identity

_PAREN = re.compile(r"[\(\[（【][^)\]）】]*[\)\]）】]")
_NOISE = re.compile(
    r"\b(official|music|lyric|lyrics|video|audio|mv|hd|hq|full|ver|version|"
    r"remaster(ed)?|live|cover|feat|ft|featuring|topic|sub|subtitled|"
    r"instrumental|off vocal|karaoke)\b", re.I)
_PUNCT = re.compile(r"[^\w\s]", re.U)
_SPACE = re.compile(r"\s+")
_ARTIST_SEPARATORS = (" feat ", " feat. ", " ft ", " ft. ", " featuring ",
                      " with ", " & ", ", ", " x ")


def normalize(text):
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", str(text)).lower()
    text = _PAREN.sub(" ", text)
    text = text.replace("-", " ")
    text = _NOISE.sub(" ", text)
    text = _PUNCT.sub(" ", text)
    return _SPACE.sub(" ", text).strip()


def primary_artist(name):
    """First credited artist, so 'A feat. B' cannot evade the per-artist cap."""
    value = normalize(name)
    for separator in _ARTIST_SEPARATORS:
        if separator in value:
            value = value.split(separator)[0]
    return value.strip()


def identity(track):
    """Same recording under a different videoId collapses to one key."""
    return "%s::%s" % (primary_artist(track.get("artist")),
                       normalize(track.get("title")))


# ---------------------------------------------------------------- innertube


def _innertube(path, payload, visitor=None, cookie=None, timeout=25):
    client = dict(WEB_REMIX)
    context = {"client": {"clientName": client["clientName"],
                          "clientVersion": client["clientVersion"],
                          "hl": "en", "gl": "US"}}
    if visitor:
        context["client"]["visitorData"] = visitor
    body = dict(payload)
    body["context"] = context

    request = urllib.request.Request(
        "https://music.youtube.com/youtubei/v1/%s?prettyPrint=false" % path,
        data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("X-YouTube-Client-Name", client["clientId"])
    request.add_header("X-YouTube-Client-Version", client["clientVersion"])
    request.add_header("User-Agent", UA_WEB)
    request.add_header("Origin", "https://music.youtube.com")
    request.add_header("Referer", "https://music.youtube.com/")
    if cookie:
        request.add_header("Cookie", cookie)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return json.loads(response.read().decode())
    except Exception:  # noqa: BLE001
        return None


def _walk(obj, key, out=None):
    if out is None:
        out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                out.append(v)
            _walk(v, key, out)
    elif isinstance(obj, list):
        for v in obj:
            _walk(v, key, out)
    return out


def _texts(node):
    return [t for t in _walk(node or {}, "text") if isinstance(t, str)]


def fetch_visitor_data():
    request = urllib.request.Request("https://music.youtube.com/",
                                     headers={"User-Agent": UA_WEB})
    try:
        with urllib.request.urlopen(request, timeout=25) as response:
            html = response.read().decode(errors="replace")
        match = re.search(r'"visitorData":"(.*?)"', html)
        return match.group(1) if match else None
    except Exception:  # noqa: BLE001
        return None


def radio(video_id, visitor, cookie=None, limit=60):
    body = _innertube("next", {"videoId": video_id,
                               "playlistId": "RDAMVM" + video_id,
                               "isAudioOnly": True, "params": "wAEB"},
                      visitor, cookie)
    if not body:
        return []
    out, seen = [], set()
    for index, row in enumerate(_walk(body, "playlistPanelVideoRenderer")):
        vid = row.get("videoId")
        if not vid or vid in seen:
            continue
        titles = _texts(row.get("title"))
        if not titles:
            continue
        bylines = _texts(row.get("longBylineText"))
        thumbs = ((row.get("thumbnail") or {}).get("thumbnails") or [])
        seen.add(vid)
        out.append({"videoId": vid, "title": titles[0],
                    "artist": bylines[0] if bylines else "Unknown",
                    "thumbnail": thumbs[-1]["url"] if thumbs else None,
                    "source": "radio", "rank": index})
        if len(out) >= limit:
            break
    return out


def search_song(query, visitor, cookie=None):
    body = _innertube("search", {"query": query, "params": SEARCH_SONGS_PARAMS},
                      visitor, cookie)
    if not body:
        return None
    for row in _walk(body, "musicResponsiveListItemRenderer"):
        for item in _walk(row, "playlistItemData"):
            if not item.get("videoId"):
                continue
            runs = [t for t in _walk(row, "text")
                    if isinstance(t, str) and t.strip() and t.strip() != "•"]
            thumbs = _walk(row, "thumbnails")
            url = None
            if thumbs and isinstance(thumbs[0], list) and thumbs[0]:
                url = thumbs[0][-1].get("url")
            return {"videoId": item["videoId"],
                    "title": runs[0] if runs else query,
                    "artist": runs[1] if len(runs) > 1 else "Unknown",
                    "thumbnail": url}
    return None


# ---------------------------------------------------------------- deezer


def _deezer(url):
    request = urllib.request.Request(url, headers={"User-Agent": "OuterTuneiOS/1.0"})
    try:
        with urllib.request.urlopen(request, timeout=12) as response:
            return json.loads(response.read().decode())
    except Exception:  # noqa: BLE001
        return None


def deezer_similar_artists(name, limit=6):
    """Stands in for Spotify's withdrawn related-artists endpoint."""
    if not name or name == "Unknown":
        return []
    found = _deezer("https://api.deezer.com/search/artist?q="
                    + urllib.parse.quote(name))
    if not found or not found.get("data"):
        return []
    related = _deezer("https://api.deezer.com/artist/%s/related"
                      % found["data"][0]["id"])
    if not related:
        return []
    return [a["name"] for a in related.get("data", [])][:limit]


# ---------------------------------------------------------------- taste


class TasteProfile:
    """Spotify affinity data, refreshed lazily and cached."""

    TTL = 60 * 60 * 3

    def __init__(self):
        self.artists = {}
        self.tracks = []
        self.fetched_at = 0
        self._lock = threading.Lock()

    @property
    def stale(self):
        return time.time() - self.fetched_at > self.TTL

    def refresh(self):
        with self._lock:
            if not self.stale:
                return
            try:
                import sys
                if APITESTS not in sys.path:
                    sys.path.insert(0, APITESTS)
                import spotify_client as sp
                from harness import load_env
            except Exception:  # noqa: BLE001
                return

            env = load_env()
            tokens = sp.load_tokens()
            token = env.get("SPOTIFY_ACCESS_TOKEN")
            if not token and tokens:
                client_id = env.get("SPOTIFY_CLIENT_ID")
                if tokens.get("refresh_token") and client_id:
                    try:
                        tokens.update(sp.refresh_token(client_id,
                                                       tokens["refresh_token"]))
                        sp.save_tokens(tokens)
                    except Exception:  # noqa: BLE001
                        pass
                token = tokens.get("access_token")
            if not token:
                return

            artists, tracks = {}, []

            def add_artist(name, weight):
                key = primary_artist(name)
                if key:
                    artists[key] = max(artists.get(key, 0), weight)

            for rng, base in (("short_term", 1.0), ("medium_term", 0.65),
                              ("long_term", 0.4)):
                status, body = sp.get("/me/top/artists", token,
                                      {"limit": 40, "time_range": rng})
                if status == 200:
                    for i, a in enumerate(body.get("items", [])):
                        add_artist(a["name"], base / (1.0 + i * 0.08))

            for rng, base in (("short_term", 1.0), ("medium_term", 0.6)):
                status, body = sp.get("/me/top/tracks", token,
                                      {"limit": 40, "time_range": rng})
                if status == 200:
                    for i, t in enumerate(body.get("items", [])):
                        weight = base / (1.0 + i * 0.08)
                        tracks.append({"name": t["name"],
                                       "artist": t["artists"][0]["name"],
                                       "weight": weight})
                        add_artist(t["artists"][0]["name"], weight * 0.8)

            status, body = sp.get("/me/player/recently-played", token, {"limit": 40})
            if status == 200:
                for i, row in enumerate(body.get("items", [])):
                    t = row.get("track") or {}
                    if t.get("name"):
                        tracks.append({"name": t["name"],
                                       "artist": t["artists"][0]["name"],
                                       "weight": 0.8 / (1.0 + i * 0.08)})

            if artists or tracks:
                self.artists = artists
                self.tracks = tracks
                self.fetched_at = time.time()


# ---------------------------------------------------------------- ranking


LAMBDA = 0.72
ARTIST_CAP = 2
SESSION_ARTIST_CAP = 3
ARTIST_SPACING = 4


def relevance(candidate, taste):
    source = candidate.get("source")
    rank = candidate.get("rank", 40)
    if source == "radio":
        score = 1.0 / (1.0 + rank * 0.05)
    elif source == "taste":
        score = 0.85 / (1.0 + rank * 0.03)
    elif source == "history":
        score = 0.8
    else:
        score = 0.7

    affinity = taste.artists.get(primary_artist(candidate.get("artist")), 0.0)
    # Saturating: one heavily weighted favourite must not outscore everything.
    score += 1.6 * (affinity / (0.6 + affinity))
    # Targeted discovery only. Rewarding any unheard artist just promotes radio
    # filler, which measured at a 0.11 taste match.
    if affinity == 0.0 and source == "similar":
        score += 0.55
    return score


def similarity(a, b):
    if primary_artist(a.get("artist")) == primary_artist(b.get("artist")):
        return 1.0
    ta = set(normalize(a.get("title")).split())
    tb = set(normalize(b.get("title")).split())
    if ta and tb:
        union = len(ta | tb)
        if union and len(ta & tb) / float(union) > 0.6:
            return 0.8
    return 0.0


def select(pool, taste, limit, blocked_ids, blocked_identities,
           session_artists):
    """Maximal Marginal Relevance with hard artist caps and spacing."""
    seen_ids = set(blocked_ids)
    seen_identities = set(blocked_identities)
    chosen, batch_artists = [], {}
    spacing = ARTIST_SPACING

    remaining = [c for c in pool
                 if c["videoId"] not in seen_ids
                 and identity(c) not in seen_identities]

    while remaining and len(chosen) < limit:
        best, best_value = None, None
        for candidate in remaining:
            if identity(candidate) in seen_identities:
                continue
            artist = primary_artist(candidate.get("artist"))
            if batch_artists.get(artist, 0) >= ARTIST_CAP:
                continue
            if session_artists.get(artist, 0) + batch_artists.get(artist, 0) \
                    >= SESSION_ARTIST_CAP:
                continue
            if spacing > 0:
                recent = [primary_artist(x.get("artist")) for x in chosen[-spacing:]]
                if artist in recent:
                    continue
            penalty = max((similarity(candidate, x) for x in chosen), default=0.0)
            value = LAMBDA * relevance(candidate, taste) - (1 - LAMBDA) * penalty
            if best_value is None or value > best_value:
                best, best_value = candidate, value

        if best is None:
            if spacing > 0:
                spacing -= 1
                continue
            break

        chosen.append(best)
        artist = primary_artist(best.get("artist"))
        batch_artists[artist] = batch_artists.get(artist, 0) + 1
        session_artists[artist] = session_artists.get(artist, 0) + 1
        seen_ids.add(best["videoId"])
        key = identity(best)
        seen_identities.add(key)
        remaining = [c for c in remaining
                     if c["videoId"] != best["videoId"] and identity(c) != key]

    return chosen


# ---------------------------------------------------------------- engine


class QueueEngine:
    """Builds queues and remembers what it already handed out."""

    def __init__(self, cookie=None):
        self.cookie = cookie
        self.taste = TasteProfile()
        self._visitor = None
        self._visitor_at = 0
        self._sessions = {}
        self._lock = threading.Lock()

    def visitor(self):
        if not self._visitor or time.time() - self._visitor_at > 3600:
            self._visitor = fetch_visitor_data()
            self._visitor_at = time.time()
        return self._visitor

    def _session(self, key):
        with self._lock:
            state = self._sessions.get(key)
            if state is None:
                state = {"ids": set(), "identities": set(), "artists": {}}
                self._sessions[key] = state
            # Keep memory bounded for long-lived sessions.
            if len(state["ids"]) > 600:
                state["ids"] = set(list(state["ids"])[-300:])
                state["identities"] = set(list(state["identities"])[-300:])
                state["artists"] = {}
            return state

    def reset(self, key):
        with self._lock:
            self._sessions.pop(key, None)

    def build_pool(self, seed, visitor):
        pool = list(radio(seed["videoId"], visitor, self.cookie, limit=60))

        self.taste.refresh()
        taste = self.taste

        # Radios seeded from the listener's own favourites, so the pool is not
        # confined to one artist's orbit. This is the largest single lever on
        # both artist diversity and taste match.
        seed_artist = primary_artist(seed.get("artist"))
        others = [t for t in taste.tracks[:24]
                  if primary_artist(t["artist"]) != seed_artist]
        others.sort(key=lambda t: -t.get("weight", 0))
        for track in others[:3]:
            found = search_song("%s %s" % (track["artist"], track["name"]),
                                visitor, self.cookie)
            if found:
                for index, row in enumerate(radio(found["videoId"], visitor,
                                                  self.cookie, limit=20)):
                    row["source"] = "taste"
                    row["rank"] = index
                    pool.append(row)

        # Targeted discovery: artists adjacent to the seed and to the top of the
        # profile, so "new" still means "near what you already like".
        anchors = [seed.get("artist")]
        anchors += [a for a, _ in sorted(taste.artists.items(),
                                         key=lambda kv: -kv[1])[:3]]
        for anchor in anchors:
            for name in deezer_similar_artists(anchor, limit=3):
                found = search_song(name, visitor, self.cookie)
                if found:
                    found["source"] = "similar"
                    found["rank"] = 50
                    pool.append(found)

        seen, unique = set(), []
        for candidate in pool:
            if candidate["videoId"] in seen:
                continue
            seen.add(candidate["videoId"])
            unique.append(candidate)
        return unique

    def queue(self, video_id, limit=20, session_key="default", seed_hint=None):
        visitor = self.visitor()
        seed = seed_hint or {"videoId": video_id, "artist": "", "title": ""}

        if not seed.get("artist"):
            info = radio(video_id, visitor, self.cookie, limit=1)
            if info:
                seed = {"videoId": video_id, "artist": info[0]["artist"],
                        "title": info[0]["title"]}

        pool = self.build_pool(seed, visitor)
        state = self._session(session_key)

        blocked_ids = set(state["ids"]) | {video_id}
        blocked_identities = set(state["identities"]) | {identity(seed)}

        picks = select(pool, self.taste, limit, blocked_ids,
                       blocked_identities, state["artists"])

        with self._lock:
            for pick in picks:
                state["ids"].add(pick["videoId"])
                state["identities"].add(identity(pick))

        return {
            "seed": {"videoId": video_id, "title": seed.get("title"),
                     "artist": seed.get("artist")},
            "poolSize": len(pool),
            "tasteArtists": len(self.taste.artists),
            "tracks": [{"videoId": p["videoId"], "title": p["title"],
                        "artist": p["artist"], "thumbnail": p.get("thumbnail"),
                        "source": p.get("source")} for p in picks],
        }
