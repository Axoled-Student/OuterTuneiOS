"""End-to-end test of the auto-queue recommendation pipeline.

Runs the real thing against live services:

    Spotify taste profile  ->  candidate generation  ->  LLM re-rank

The point of the re-rank step is that the model may only *choose from* the
candidate list. Every candidate carries a real YouTube Music videoId, so the
model can reorder and filter but can never invent a track that does not exist.
This test asserts exactly that.

    python tools/apitests/test_recommender.py
"""
import json
import os
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import innertube_client as it  # noqa: E402
import spotify_client as sp  # noqa: E402
from harness import Suite, load_env  # noqa: E402

BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")
SEARCH_SONGS_PARAMS = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
VARIANT_MARKERS = (
    "cover", "coveredby", "karaoke", "instrumental", "acoustic",
    "spedup", "slowed", "nightcore", "remix", "tvsize", "テレビサイズ",
    "翻唱", "伴奏", "純音樂", "纯音乐", "カバー", "歌ってみた",
)


def load_ai_config():
    """Read ai.env from the repository root (endpoint + key)."""
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    path = os.path.join(root, "ai.env")
    if not os.path.exists(path):
        return None
    cfg = {}
    with open(path, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    if "endpoint" in cfg and "key" in cfg:
        cfg["endpoint"] = cfg["endpoint"].rstrip("/")
        return cfg
    return None


def http_json(url, payload=None, headers=None, timeout=90):
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method="POST" if data else "GET")
    req.add_header("User-Agent", BROWSER_UA)
    req.add_header("Accept", "application/json")
    if data:
        req.add_header("Content-Type", "application/json")
    for k, v in (headers or {}).items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            body = r.read().decode(errors="replace")
            return r.status, (json.loads(body) if body.strip().startswith(("{", "[")) else body)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode(errors="replace")[:400]
    except Exception as e:  # noqa: BLE001
        return 0, "EXC " + str(e)


def deezer_related_artists(name, limit=12):
    st, body = http_json("https://api.deezer.com/search/artist?q=" + urllib.parse.quote(name))
    if st != 200 or not isinstance(body, dict) or not body.get("data"):
        return []
    artist_id = body["data"][0]["id"]
    st, body = http_json("https://api.deezer.com/artist/%s/related" % artist_id)
    if st != 200 or not isinstance(body, dict):
        return []
    return [a["name"] for a in body.get("data", [])][:limit]


def ytm_radio(video_id, visitor, limit=80):
    out = []
    continuation = None
    for _ in range(3):
        payload = ({"continuation": continuation} if continuation else
                   {"videoId": video_id, "playlistId": "RDAMVM" + video_id,
                    "isAudioOnly": True, "params": "wAEB"})
        st, body = it.call("next", payload, it.WEB_REMIX, visitor_data=visitor)
        if st != 200 or not isinstance(body, dict):
            break
        for r in it.walk(body, "playlistPanelVideoRenderer"):
            vid = r.get("videoId")
            titles = it.walk(r.get("title", {}), "text")
            if vid and titles:
                out.append({"videoId": vid, "title": titles[0],
                            "artist": artist_from_renderer(r),
                            "thumbnail": radio_thumbnail(r),
                            "musicVideoType": first_string(it.walk(r, "musicVideoType"))})
        if len(out) >= limit:
            break
        continuations = it.walk(body, "nextRadioContinuationData")
        continuation = (continuations[0].get("continuation")
                        if continuations else None)
        if not continuation:
            break
    # de-dupe, preserving order
    seen, uniq = set(), []
    for row in out:
        if row["videoId"] not in seen:
            seen.add(row["videoId"])
            uniq.append(row)
    return uniq[:limit]


def ytm_search_track(query, visitor):
    st, body = it.call("search", {"query": query,
                                  "params": SEARCH_SONGS_PARAMS},
                       it.WEB_REMIX, visitor_data=visitor)
    if st != 200 or not isinstance(body, dict):
        return None
    for r in it.walk(body, "musicResponsiveListItemRenderer"):
        for pid in it.walk(r, "playlistItemData"):
            if pid.get("videoId"):
                # walk() also yields the dicts that *contain* a "text" key, so
                # filter to actual strings before using them as a title/artist.
                texts = [t for t in it.walk(r, "text") if isinstance(t, str)]
                return {"videoId": pid["videoId"],
                        "title": texts[0] if texts else query,
                        "artist": artist_from_search_renderer(r),
                        "thumbnail": search_thumbnail(r, pid["videoId"]),
                        "musicVideoType": first_string(it.walk(r, "musicVideoType"))}
    return None


def first_string(values):
    return next((value for value in values if isinstance(value, str)), None)


def artist_from_runs(node):
    runs = node.get("runs", []) if isinstance(node, dict) else []
    artists = []
    for run in runs:
        browse = (run.get("navigationEndpoint", {}).get("browseEndpoint", {}))
        config = (browse.get("browseEndpointContextSupportedConfigs", {})
                  .get("browseEndpointContextMusicConfig", {}))
        if config.get("pageType") == "MUSIC_PAGE_TYPE_ARTIST" or \
                str(browse.get("browseId", "")).startswith("UC"):
            value = str(run.get("text", "")).strip()
            if value and value not in artists:
                artists.append(value)
    if artists:
        return " & ".join(artists)
    return next((str(run.get("text", "")).strip() for run in runs
                 if str(run.get("text", "")).strip() not in ("", "•", "·")),
                "Unknown")


def artist_from_renderer(renderer):
    for key in ("longBylineText", "shortBylineText"):
        artist = artist_from_runs(renderer.get(key, {}))
        if artist != "Unknown":
            return artist
    return "Unknown"


def artist_from_search_renderer(renderer):
    columns = renderer.get("flexColumns", [])
    if len(columns) > 1:
        node = (columns[1].get("musicResponsiveListItemFlexColumnRenderer", {})
                .get("text", {}))
        return artist_from_runs(node)
    return artist_from_renderer(renderer)


def radio_thumbnail(renderer):
    thumbs = (renderer.get("thumbnail") or {}).get("thumbnails") or []
    return thumbs[-1].get("url") if thumbs else None


def search_thumbnail(renderer, video_id):
    thumbs = it.walk(renderer.get("thumbnail", {}), "thumbnails")
    for group in thumbs:
        if isinstance(group, list) and group:
            return group[-1].get("url")
    return "https://i.ytimg.com/vi/%s/hqdefault.jpg" % video_id


def normalized(value):
    folded = unicodedata.normalize("NFKD", value).casefold()
    return "".join(ch for ch in folded if ch.isalnum())


def normalized_title(value):
    return normalized(re.sub(r"\s*[\(（\[【].*$", "", value))


def track_key(track):
    return "%s|%s" % (normalized(track["artist"]), normalized_title(track["title"]))


def is_variant(track):
    title = normalized(track["title"])
    return any(normalized(marker) in title for marker in VARIANT_MARKERS)


def recommendation_language(value):
    for char in value:
        code = ord(char)
        if 0x3040 <= code <= 0x30FF:
            return "japanese"
        if 0xAC00 <= code <= 0xD7AF:
            return "korean"
    if any(0x3400 <= ord(char) <= 0x4DBF or 0x4E00 <= ord(char) <= 0x9FFF
           for char in value):
        return "chinese"
    return "other"


def preferred_language(seed, candidates):
    seed_language = recommendation_language(seed["title"])
    if seed_language == "chinese":
        return "chinese"
    sample = [recommendation_language(row["title"]) for row in candidates[:30]]
    chinese = sample.count("chinese")
    explicit = len([kind for kind in sample if kind != "other"])
    if chinese >= 5 and chinese * 2 >= max(explicit, 1):
        return "chinese"
    return seed_language


def select_like_app(seed, radio, spotify_references, top_artists,
                    top_tracks, recent_titles, want=20,
                    recently_suggested=()):
    """Mirror the app's deterministic familiarity/repeat policy for live QA."""
    candidates = []
    seen_ids, seen_titles = set(), set()
    blocked_titles = {normalized_title(seed["title"])} | {
        normalized_title(title) for title in recent_titles
    } | {
        normalized_title(title) for title in recently_suggested
    }
    if len(radio) >= max(want, 12):
        source = radio
    else:
        source = radio + spotify_references
    language = preferred_language(seed, source)
    if language == "chinese":
        source = [row for row in source
                  if recommendation_language(row["title"]) == "chinese"]
    for index, track in enumerate(source):
        identity = normalized_title(track["title"])
        if (not identity or identity in blocked_titles or
                track["videoId"] in seen_ids or identity in seen_titles):
            continue
        seen_ids.add(track["videoId"])
        seen_titles.add(identity)
        row = dict(track)
        row["sourceIndex"] = index
        candidates.append(row)

    known_artists = {normalized(name) for name in top_artists}
    known_artists.update(normalized(artist) for _, artist in top_tracks)
    known_track_keys = {
        "%s|%s" % (normalized(artist), normalized_title(title))
        for title, artist in top_tracks
    }
    has_taste = bool(known_artists or known_track_keys)
    seed_artist = normalized(seed["artist"])
    artist_rank = {normalized(name): index for index, name in enumerate(top_artists)}

    scored = []
    for row in candidates:
        artist = normalized(row["artist"])
        exact_known = track_key(row) in known_track_keys
        familiar = (not has_taste or artist == seed_artist
                    or artist in known_artists or exact_known)
        if is_variant(row) and not exact_known:
            continue
        source_score = 4.0 / (1.0 + row["sourceIndex"] * 0.08)
        rank = artist_rank.get(artist)
        taste_score = (2.4 / (1.0 + rank * 0.08)) if rank is not None else 0
        score = source_score + taste_score + (3.0 if exact_known else 0)
        score += 2.5 if artist == seed_artist else 0
        score -= 2.5 if not familiar else 0
        scored.append((score, familiar, row))
    scored.sort(key=lambda entry: -entry[0])

    familiar = [entry for entry in scored if entry[1]]
    discovery = [entry for entry in scored if not entry[1]]
    result, artist_counts = [], {}

    def append_best(rows, maximum):
        while rows and len(result) < maximum:
            previous = normalized(result[-1]["artist"]) if result else None
            chosen = next((i for i, entry in enumerate(rows)
                           if artist_counts.get(normalized(entry[2]["artist"]), 0) <
                           (5 if normalized(entry[2]["artist"]) == seed_artist else 3)
                           and normalized(entry[2]["artist"]) != previous), None)
            if chosen is None:
                chosen = next((i for i, entry in enumerate(rows)
                               if artist_counts.get(normalized(entry[2]["artist"]), 0) <
                               (5 if normalized(entry[2]["artist"]) == seed_artist else 3)),
                              None)
            if chosen is None:
                break
            _, _, row = rows.pop(chosen)
            artist = normalized(row["artist"])
            artist_counts[artist] = artist_counts.get(artist, 0) + 1
            result.append(row)

    target = min(want, 12)
    reserved_discovery = min(3, target // 4) if has_taste else 0
    append_best(familiar, target - reserved_discovery)
    if len(result) < target:
        allowance = (min(max(2, target - len(result)), 4)
                     if has_taste else target)
        append_best(discovery, min(target, len(result) + allowance))
    return result, known_artists, known_track_keys


def rerank_with_llm(cfg, model, profile_summary, now_playing, candidates, want=10):
    """Ask the model to choose `want` videoIds from `candidates`, in order."""
    listing = "\n".join(
        "%d. [%s] %s - %s" % (i, c["videoId"], c["artist"], c["title"])
        for i, c in enumerate(candidates, 1))

    prompt = (
        "You are the recommendation engine for a music player.\n\n"
        "The listener's taste profile (from their Spotify account):\n%s\n\n"
        "Now playing: %s\n\n"
        "Candidate tracks (each line is `N. [videoId] artist - title`):\n%s\n\n"
        "Choose the %d best tracks to play next, ordered best-first.\n"
        "Rules:\n"
        "- You MUST only choose videoIds that appear in the candidate list above.\n"
        "- Do not invent tracks. Do not repeat the now-playing track.\n"
        "- Favour flow: keep energy and genre coherent with what is playing,\n"
        "  while matching the listener's taste profile.\n"
        "Respond with ONLY a JSON array of videoId strings, no prose.\n"
        % (profile_summary, now_playing, listing, want))

    st, body = http_json(
        cfg["endpoint"] + "/v1/chat/completions",
        {"model": model,
         "messages": [{"role": "user", "content": prompt}],
         "temperature": 0.4, "max_tokens": 2000},
        headers={"Authorization": "Bearer " + cfg["key"]})
    if st != 200 or not isinstance(body, dict):
        return None, "HTTP %s %s" % (st, str(body)[:200])

    text = body["choices"][0]["message"]["content"].strip()
    # Models sometimes wrap JSON in a fenced block.
    if "```" in text:
        text = text.split("```")[1]
        if text.startswith("json"):
            text = text[4:]
    start, end = text.find("["), text.rfind("]")
    if start == -1 or end == -1:
        return None, "no JSON array in reply: " + text[:200]
    try:
        return json.loads(text[start:end + 1]), body.get("usage")
    except ValueError as e:
        return None, "bad JSON (%s): %s" % (e, text[:200])


def run():
    env = load_env()
    suite = Suite("Auto-queue recommendation pipeline")

    visitor = it.fetch_visitor_data()
    cfg = load_ai_config()
    model = env.get("AI_MODEL", "gemini-3.8-flash-high")

    # --- 1. Spotify taste profile -----------------------------------------
    top_artists, top_tracks, recent_titles = [], [], []
    tokens = sp.load_tokens()
    token = env.get("SPOTIFY_ACCESS_TOKEN")
    if not token and tokens:
        client_id = env.get("SPOTIFY_CLIENT_ID")
        if tokens.get("refresh_token") and client_id:
            try:
                tokens.update(sp.refresh_token(client_id, tokens["refresh_token"]))
                sp.save_tokens(tokens)
            except Exception:  # noqa: BLE001
                pass
        token = tokens.get("access_token")

    if not token:
        suite.skip("Spotify taste profile", "no token")
    else:
        with suite.test("Spotify taste profile is usable as seed material") as t:
            for time_range in ("short_term", "medium_term"):
                status, body = sp.get("/me/top/artists", token,
                                      {"limit": 30, "time_range": time_range})
                t.require(status == 200, "top artists HTTP %s" % status)
                for artist in body.get("items", []):
                    if artist["name"] not in top_artists:
                        top_artists.append(artist["name"])

                status, body = sp.get("/me/top/tracks", token,
                                      {"limit": 40, "time_range": time_range})
                t.require(status == 200, "top tracks HTTP %s" % status)
                for track in body.get("items", []):
                    pair = (track["name"], track["artists"][0]["name"])
                    if pair not in top_tracks:
                        top_tracks.append(pair)

            status, body = sp.get("/me/player/recently-played", token, {"limit": 40})
            t.require(status == 200, "recent history HTTP %s" % status)
            recent_titles = [item["track"]["name"] for item in body.get("items", [])]

            status, body = sp.get("/me/tracks", token, {"limit": 40})
            t.require(status == 200, "saved tracks HTTP %s" % status)
            for item in body.get("items", []):
                track = item.get("track") or {}
                if track.get("artists"):
                    pair = (track["name"], track["artists"][0]["name"])
                    if pair not in top_tracks:
                        top_tracks.append(pair)

            t.require(top_artists or top_tracks, "profile is empty")
            t.note("top artists: %s" % ", ".join(top_artists[:6]))
            t.note("top tracks: %s" % ", ".join("%s - %s" % (n, a)
                                                for n, a in top_tracks[:4]))
            t.note("%d recent tracks are hard repeat blocks" % len(recent_titles))

    # --- 2. seed resolution ------------------------------------------------
    seed = None
    with suite.test("resolve a Spotify seed track onto YouTube Music") as t:
        if top_tracks:
            name, artist = top_tracks[0]
            seed = ytm_search_track("%s %s" % (artist, name), visitor)
        if seed is None:
            seed = ytm_search_track("DECO*27 vampire", visitor)
        t.require(seed, "could not resolve any seed track on YouTube Music")
        t.note("seed: %s - %s (%s)" % (seed["artist"], seed["title"], seed["videoId"]))

    # --- 3. candidate generation ------------------------------------------
    candidates = []
    with suite.test("generate candidates from YouTube Music radio") as t:
        radio = ytm_radio(seed["videoId"], visitor)
        t.require(len(radio) >= 10, "only %d radio candidates" % len(radio))
        candidates.extend(radio)
        t.note("%d radio candidates" % len(radio))

    with suite.test("Deezer contributes similar-artist candidates") as t:
        anchor = top_artists[0] if top_artists else seed["artist"]
        related = deezer_related_artists(anchor, limit=6)
        t.note("anchor artist: %s" % anchor)
        t.note("Deezer similar: %s" % (", ".join(related) if related else "(none)"))
        added = 0
        for name in related[:4]:
            found = ytm_search_track(name, visitor)
            if found and all(c["videoId"] != found["videoId"] for c in candidates):
                candidates.append(found)
                added += 1
        t.note("added %d cross-source candidates (total %d)" % (added, len(candidates)))

    spotify_references = []
    spotify_artist_aliases = []
    if top_tracks:
        with suite.test("resolve non-recent Spotify favourites as familiar candidates") as t:
            recent_set = {normalized_title(title) for title in recent_titles}
            for name, artist in top_tracks:
                if normalized_title(name) in recent_set:
                    continue
                found = ytm_search_track("%s %s" % (artist, name), visitor)
                if found and all(normalized_title(row["title"]) !=
                                 normalized_title(found["title"])
                                 for row in spotify_references):
                    spotify_references.append(found)
                if len(spotify_references) >= 16:
                    break
            t.require(len(spotify_references) >= 8,
                      "only %d non-recent familiar candidates resolved"
                      % len(spotify_references))
            t.note("%d Spotify-history tracks resolved on YouTube Music"
                   % len(spotify_references))
            candidates.extend(spotify_references)
    else:
        suite.skip("resolve non-recent Spotify favourites", "no Spotify profile")

    if top_artists:
        with suite.test("resolve Spotify artist aliases used by YouTube Music") as t:
            for artist in top_artists[:16]:
                found = ytm_search_track(artist, visitor)
                if found and found["artist"] not in spotify_artist_aliases:
                    spotify_artist_aliases.append(found["artist"])
            t.require(len(spotify_artist_aliases) >= 8,
                      "only %d artist aliases resolved" % len(spotify_artist_aliases))
            t.note("%d native-name artist aliases resolved" % len(spotify_artist_aliases))
    else:
        suite.skip("resolve Spotify artist aliases", "no Spotify profile")

    # --- 4. quality policy -------------------------------------------------
    def audit_policy(test, scenario_seed, scenario_radio):
        queue, known_artists, known_tracks = select_like_app(
            scenario_seed, scenario_radio, spotify_references,
            top_artists + spotify_artist_aliases,
            top_tracks, recent_titles, want=20)
        test.require(len(queue) >= 8, "queue is too short: %d" % len(queue))

        identities = [normalized_title(row["title"]) for row in queue]
        test.require(len(identities) == len(set(identities)),
                     "duplicate song titles survived selection")
        test.require(normalized_title(scenario_seed["title"]) not in identities,
                     "seed song was recommended again")
        recent_set = {normalized_title(title) for title in recent_titles}
        test.require(not (set(identities) & recent_set),
                     "recent Spotify songs were recommended again")

        artist_counts = {}
        unfamiliar = []
        seed_artist = normalized(scenario_seed["artist"])
        for row in queue:
            artist = normalized(row["artist"])
            artist_counts[artist] = artist_counts.get(artist, 0) + 1
            if not (artist == seed_artist or artist in known_artists
                    or track_key(row) in known_tracks):
                unfamiliar.append(row)
            test.require(row.get("thumbnail"),
                         "missing thumbnail for %s" % row["title"])
            test.require("•" not in row["artist"],
                         "metadata leaked into artist: %s" % row["artist"])
            test.require(not is_variant(row) or track_key(row) in known_tracks,
                         "unfamiliar alternate upload survived: %s" % row["title"])

        for artist, count in artist_counts.items():
            allowed = 5 if artist == seed_artist else 3
            test.require(count <= allowed,
                         "one artist occupies too many queue slots")
        if top_artists or top_tracks:
            familiar_count = len(queue) - len(unfamiliar)
            discovery_limit = min(max(2, familiar_count), 4)
            test.require(len(unfamiliar) <= discovery_limit,
                         "%d/%d tracks are unfamiliar" % (len(unfamiliar), len(queue)))
            first = queue[0]
            test.require(normalized(first["artist"]) in known_artists
                         or normalized(first["artist"]) == seed_artist
                         or track_key(first) in known_tracks,
                         "queue opens with an unfamiliar artist")

        test.note("selected %d tracks; familiar=%d, discovery=%d, max/artist=%d"
                  % (len(queue), len(queue) - len(unfamiliar), len(unfamiliar),
                     max(artist_counts.values())))
        for index, row in enumerate(queue[:10], 1):
            label = "known" if row not in unfamiliar else "discovery"
            test.note("  %2d. [%s] %s - %s"
                      % (index, label, row["artist"], row["title"]))
        return queue

    first_queue = []
    with suite.test("queue policy fits the real Spotify seed without repeats") as t:
        first_queue = audit_policy(t, seed, radio)

    with suite.test("same seed rotates to a non-overlapping second queue") as t:
        second_queue, _, _ = select_like_app(
            seed, radio, spotify_references,
            top_artists + spotify_artist_aliases, top_tracks, recent_titles,
            want=20, recently_suggested=[row["title"] for row in first_queue])
        first_titles = {normalized_title(row["title"]) for row in first_queue}
        second_titles = {normalized_title(row["title"]) for row in second_queue}
        t.require(len(second_queue) >= 6,
                  "rotated queue is too short: %d" % len(second_queue))
        t.require(not (first_titles & second_titles),
                  "same songs returned after the cooldown")
        t.note("first=%d, second=%d, overlap=0"
               % (len(first_queue), len(second_queue)))

    for label, query in (("Jay Chou screenshot seed", "周杰倫 晴天"),
                         ("anime screenshot seed", "椎名真昼 小さな恋のうた")):
        with suite.test("queue policy: " + label) as t:
            scenario_seed = ytm_search_track(query, visitor)
            t.require(scenario_seed, "could not resolve seed: " + query)
            scenario_radio = ytm_radio(scenario_seed["videoId"], visitor)
            t.require(len(scenario_radio) >= 20,
                      "only %d radio candidates" % len(scenario_radio))
            scenario_queue = audit_policy(t, scenario_seed, scenario_radio)
            if label.startswith("Jay Chou"):
                t.require(all(recommendation_language(row["title"]) == "chinese"
                              for row in scenario_queue),
                          "Chinese seed produced a non-Chinese queue item")

    # --- 5. LLM safety probe ----------------------------------------------
    if not cfg:
        suite.skip("LLM re-rank", "ai.env not found")
        return suite.report()

    with suite.test("LLM re-ranks and only picks real candidates") as t:
        profile_summary = (
            "Top artists: %s\nTop tracks: %s"
            % (", ".join(top_artists[:12]) or "(unknown)",
               ", ".join("%s - %s" % (n, a) for n, a in top_tracks[:8]) or "(unknown)"))
        now_playing = "%s - %s" % (seed["artist"], seed["title"])

        picks, usage = rerank_with_llm(cfg, model, profile_summary, now_playing,
                                       candidates, want=10)
        t.require(picks is not None, "re-rank failed: %s" % usage)
        t.require(isinstance(picks, list) and picks, "model returned no picks")

        valid_ids = {c["videoId"] for c in candidates}
        by_id = {c["videoId"]: c for c in candidates}
        hallucinated = [p for p in picks if p not in valid_ids]

        t.note("model returned %d picks, usage=%s" % (len(picks), usage))
        for i, pid in enumerate(picks[:10], 1):
            row = by_id.get(pid)
            t.note("  %2d. %s" % (i, "%s - %s" % (row["artist"], row["title"])
                                  if row else "!! NOT IN CANDIDATES: " + str(pid)))

        # The whole safety property of this design.
        t.require(not hallucinated,
                  "model invented %d ids not in the candidate list: %s"
                  % (len(hallucinated), hallucinated[:5]))
        t.require(len(set(picks)) == len(picks), "model returned duplicate ids")
        t.require(seed["videoId"] not in picks, "model re-picked the now-playing track")

    return suite.report()


if __name__ == "__main__":
    sys.exit(run())
