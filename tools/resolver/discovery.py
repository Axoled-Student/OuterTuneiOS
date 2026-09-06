"""Home shelves and prompt-driven AI radio.

Both live server side for the same reason the queue does: the algorithm can
change without shipping a new build, and this machine already holds the Spotify
profile and a signed-in YouTube session.
"""
import concurrent.futures
import json
import os
import random
import re
import threading
import time
import uuid
import urllib.error
import urllib.request

import recommender as rec

HERE = os.path.dirname(os.path.abspath(__file__))
# tools/resolver/discovery.py -> repo root is three levels up.
AI_ENV = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "ai.env")

# Search results and radios for a given seed barely move, and the same seeds
# recur across refreshes, so memoising them removes most of the network work.
_lookup_cache = {}
_lookup_lock = threading.Lock()
LOOKUP_TTL = 60 * 60 * 6


def _memo(key, produce):
    now = time.time()
    with _lookup_lock:
        hit = _lookup_cache.get(key)
        if hit and hit[0] > now:
            return hit[1]
    value = produce()
    if value:
        with _lookup_lock:
            _lookup_cache[key] = (now + LOOKUP_TTL, value)
            if len(_lookup_cache) > 800:
                for stale in [k for k, v in _lookup_cache.items() if v[0] <= now][:200]:
                    _lookup_cache.pop(stale, None)
    return value


_home_cache = {"payload": None, "at": 0, "building": False}
# Survives a restart, so a fresh process still answers the first request
# instantly instead of making it wait for a cold build.
HOME_STATE = os.path.join(HERE, ".home_cache.json")


def _load_home_state():
    if _home_cache["payload"] is not None or not os.path.exists(HOME_STATE):
        return
    try:
        with open(HOME_STATE, encoding="utf-8") as fh:
            saved = json.load(fh)
        if saved.get("sections"):
            _home_cache["payload"] = saved
            # Treated as stale: served at once, rebuilt behind the request.
            _home_cache["at"] = 0
    except Exception:  # noqa: BLE001
        pass


def _save_home_state(payload):
    try:
        tmp = HOME_STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(payload, fh)
        os.replace(tmp, HOME_STATE)
    except Exception:  # noqa: BLE001
        pass
_home_lock = threading.Lock()
# Short enough that the page feels alive, long enough that a pull-to-refresh
# does not hammer YouTube. `refresh=1` bypasses it entirely.
HOME_TTL = 60 * 8

# Seed queries per language, used only when the listener's own profile has
# nothing in that script to build a shelf from.
# Seeds are named-artist queries on purpose. Mood queries ("acoustic chill",
# "lofi") resolve to compilation and ambient channels, which is how the English
# shelf once came back as Nature Sounds and Penguin Piano.
FALLBACK_SEEDS = {
    "latin": ["Taylor Swift", "The Weeknd", "Ed Sheeran", "Billie Eilish",
              "Bruno Mars", "Coldplay", "Dua Lipa", "Post Malone",
              "Glass Animals", "Imagine Dragons"],
    "jp": ["YOASOBI", "Official髭男dism", "Fujii Kaze", "Vaundy",
           "King Gnu", "Aimer", "DECO*27", "Yorushika"],
    "han": ["周杰倫", "林俊傑", "五月天", "鄧紫棋", "田馥甄",
            "李榮浩", "薛之謙", "告五人"],
    "kr": ["NewJeans", "IU", "BTS", "SEVENTEEN", "aespa", "BIGBANG"],
}

SECTION_TITLES = [
    ("madeForYou", "為你打造", None),
    ("latin", "English", "latin"),
    ("han", "中文", "han"),
    ("jp", "日本語", "jp"),
    ("kr", "한국어", "kr"),
    ("discover", "探索新音樂", None),
]


def _track_row(track):
    return {"videoId": track["videoId"], "title": track.get("title"),
            "artist": track.get("artist"), "thumbnail": track.get("thumbnail")}


def _dedupe(rows, seen_ids, seen_identities, limit):
    out = []
    for row in rows:
        vid = row.get("videoId")
        if not vid or vid in seen_ids:
            continue
        key = rec.identity(row)
        if key in seen_identities:
            continue
        seen_ids.add(vid)
        seen_identities.add(key)
        out.append(row)
        if len(out) >= limit:
            break
    return out


def _history_seeds(engine, script, wanted=3, rotate=0):
    """Seeds from what was actually played *in this app*.

    First-hand evidence, unlike the Spotify profile, which describes listening
    that happened somewhere else.
    """
    try:
        rows = engine.learned.liked_tracks(limit=60)
    except Exception:  # noqa: BLE001
        return []

    picked, seen = [], set()
    for row in rows:
        label = ("%s %s" % (row.get("artist", ""), row.get("title", ""))).strip()
        if not label:
            continue
        if script and rec.script_of(label) != script:
            continue
        key = rec.primary_artist(row.get("artist") or row.get("title"))
        if key in seen:
            continue
        seen.add(key)
        picked.append(label)

    if not picked:
        return []
    start = rotate % len(picked)
    return (picked[start:] + picked[:start])[:wanted]


def _seeds_for_script(engine, script, wanted=3, rotate=0):
    """Taste tracks in a given writing system.

    `rotate` walks a window through the candidates so successive refreshes seed
    from different favourites; keeping the top N fixed was why the shelves came
    back identical every time.
    """
    taste = engine.taste
    rows = [t for t in taste.tracks
            if rec.script_of("%s %s" % (t["name"], t["artist"])) == script]
    rows.sort(key=lambda t: -t.get("weight", 0))

    seen, unique = set(), []
    for row in rows:
        key = rec.primary_artist(row["artist"])
        if key in seen:
            continue
        seen.add(key)
        unique.append("%s %s" % (row["artist"], row["name"]))

    if not unique:
        return []
    # Draw from the strongest couple of dozen, offset by the rotation.
    pool = unique[:24]
    start = rotate % len(pool)
    ordered = pool[start:] + pool[:start]
    return ordered[:wanted]


def _shelf_from_queries(engine, visitor, queries, script, per, per_artist_cap=2):
    """Resolve queries to seeds, then take their radios as shelf material."""
    seen_ids, seen_identities = set(), set()

    # Collect each seed's contribution separately, then interleave. Draining one
    # seed at a time let a single weak query fill the whole shelf.
    def build(query):
        found = _memo("s:" + query,
                      lambda: rec.search_song(query, visitor, engine.cookie))
        if not found:
            return []
        rows = _memo("r:" + found["videoId"],
                     lambda: rec.radio(found["videoId"], visitor,
                                       engine.cookie, limit=20)) or []
        bucket = [found] + list(rows)
        if script:
            bucket = [r for r in bucket if rec.track_script(r) == script]
        return bucket

    # Each seed is two independent round-trips; running them sequentially was
    # what made a cold home page take the better part of a minute.
    selected = queries[:6]
    buckets = []
    if selected:
        with concurrent.futures.ThreadPoolExecutor(
                max_workers=min(6, len(selected))) as pool:
            for bucket in pool.map(build, selected):
                if bucket:
                    buckets.append(bucket)

    rows = []
    depth = 0
    while buckets and len(rows) < per * 4:
        progressed = False
        for bucket in buckets:
            if depth < len(bucket):
                rows.append(bucket[depth])
                progressed = True
        if not progressed:
            break
        depth += 1

    # A couple per artist keeps a shelf browsable without turning it into one
    # artist's discography. One was too strict and left shelves half empty.
    counts, spread = {}, []
    for row in rows:
        key = rec.primary_artist(row.get("artist"))
        if counts.get(key, 0) >= per_artist_cap:
            continue
        counts[key] = counts.get(key, 0) + 1
        spread.append(row)
    return [_track_row(r) for r in _dedupe(spread, seen_ids, seen_identities, per)]


def warm(engine, per=20):
    """Build the page in the background so the first open is instant."""
    def run():
        try:
            home(engine, per=per, force=True, _internal=True)
        except Exception:  # noqa: BLE001
            pass
    threading.Thread(target=run, daemon=True).start()


_auto_thread = None


def start_auto_refresh(engine, per=20, interval=None):
    """Keep the home page rebuilt on a timer.

    A cold build is around eight seconds of parallel network calls. Doing that
    on demand means somebody waits for it, so the server rebuilds on its own
    schedule and every request is served from something already finished.
    """
    global _auto_thread
    if _auto_thread and _auto_thread.is_alive():
        return
    period = interval or HOME_TTL

    def loop():
        # Build once immediately, then on the period.
        while True:
            try:
                home(engine, per=per, force=True, _internal=True)
            except Exception:  # noqa: BLE001
                pass
            time.sleep(period)

    _auto_thread = threading.Thread(target=loop, daemon=True)
    _auto_thread.start()


def home(engine, per=20, force=False, rotate=None, _internal=False):
    """Language-split browse shelves plus a personalised one.

    Serves whatever is cached immediately and refreshes behind it: rebuilding
    takes tens of seconds of network round-trips, and making the page wait for
    that is the difference between instant and unusable.
    """
    with _home_lock:
        _load_home_state()
        cached = _home_cache["payload"]
        fresh = cached and time.time() - _home_cache["at"] < HOME_TTL
        building = _home_cache.get("building")

        # Anything already built is served immediately - including on an
        # explicit refresh, which only needs to *start* the rebuild. A cold
        # build is around eight seconds and no request should sit through one
        # when a usable page exists; the client collects the new one shortly
        # after. Only a genuinely empty cache blocks.
        if cached is not None and not _internal:
            if (not fresh or force) and not building:
                _home_cache["building"] = True

                def rebuild():
                    try:
                        home(engine, per=per, force=True, rotate=rotate,
                             _internal=True)
                    finally:
                        with _home_lock:
                            _home_cache["building"] = False

                threading.Thread(target=rebuild, daemon=True).start()
            return cached

    engine.taste.refresh()
    visitor = engine.visitor()
    # Advances every cache period, so a refresh genuinely changes the page
    # rather than rebuilding the same shelves from the same seeds.
    if rotate is None:
        rotate = int(time.time() // HOME_TTL)
    shuffler = random.Random(rotate)
    built = {}

    for key, title, script in SECTION_TITLES:
        try:
            if key == "madeForYou":
                # What this app has actually played comes first; the Spotify
                # profile fills in when there is not enough local history yet.
                queries = _history_seeds(engine, None, 3, rotate)
                queries += (_seeds_for_script(engine, "latin", 1, rotate)
                            + _seeds_for_script(engine, "jp", 2, rotate)
                            + _seeds_for_script(engine, "han", 1, rotate))
                shuffler.shuffle(queries)
                if not queries:
                    queries = FALLBACK_SEEDS["latin"][:2]
                items = _shelf_from_queries(engine, visitor, queries, None, per)
                subtitle = "來自你的聆聽紀錄"
            elif key == "discover":
                top = [a for a, _ in sorted(engine.taste.artists.items(),
                                            key=lambda kv: -kv[1])[:12]]
                anchors = top[rotate % max(len(top), 1):][:3] or top[:3]
                names = []
                for anchor in anchors:
                    names += rec.deezer_similar_artists(anchor, limit=4)
                shuffler.shuffle(names)
                items = _shelf_from_queries(engine, visitor, names[:6], None, per)
                subtitle = "與你常聽的藝人相近"
            else:
                # Genuine popular-language seeds come first. Seeding purely from
                # the listener's own tracks made the "English" shelf romanised
                # J-pop, because script alone cannot tell "PPPP (feat. Hatsune
                # Miku)" from Western pop. Their own taste in that script is
                # still appended, so the shelf stays personal where it can be.
                queries = list(FALLBACK_SEEDS.get(script, []))
                shuffler.shuffle(queries)
                personal = _history_seeds(engine, script, 2, rotate)
                if len(personal) < 2:
                    personal = personal + _seeds_for_script(engine, script, 2, rotate)
                # Language seeds must lead. With personal seeds first the
                # shelf filled from them before the language seeds were ever
                # reached, which turned "English" into romanised Vocaloid.
                queries = queries + personal
                subtitle = "熱門與你的喜好" if personal else "熱門"
                items = _shelf_from_queries(engine, visitor, queries, script, per)
        except Exception:  # noqa: BLE001
            items = []

        if items:
            built[key] = {"id": key, "title": title,
                          "subtitle": subtitle, "items": items}

    sections = [built[key] for key, _, _ in SECTION_TITLES if key in built]
    payload = {"sections": sections,
               "tasteArtists": len(engine.taste.artists),
               "rotation": rotate,
               "generatedAt": int(time.time())}
    with _home_lock:
        _home_cache["payload"] = payload
        _home_cache["at"] = time.time()
        _home_cache["building"] = False
    _save_home_state(payload)
    return payload


# ---------------------------------------------------------------- AI radio


def _ai_config():
    if not os.path.exists(AI_ENV):
        return None
    cfg = {}
    with open(AI_ENV, encoding="utf-8-sig") as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                cfg[k.strip()] = v.strip().strip('"').strip("'")
    if "endpoint" in cfg and "key" in cfg:
        cfg["endpoint"] = cfg["endpoint"].rstrip("/")
        return cfg
    return None


def _ask_model(cfg, prompt, model="gemini-3.8-flash-high", timeout=90,
               max_tokens=2000, temperature=0.7):
    body = {"model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": temperature, "max_tokens": max_tokens}
    request = urllib.request.Request(cfg["endpoint"] + "/v1/chat/completions",
                                     data=json.dumps(body).encode(),
                                     method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + cfg["key"])
    request.add_header("User-Agent",
                       "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                       "AppleWebKit/537.36 (KHTML, like Gecko) "
                       "Chrome/131.0.0.0 Safari/537.36")
    with urllib.request.urlopen(request, timeout=timeout) as response:
        data = json.loads(response.read().decode())
    return data["choices"][0]["message"]["content"]


def _parse_list(text):
    body = text.strip()
    if "```" in body:
        part = body.split("```")[1]
        body = part[4:] if part.startswith("json") else part
    start, end = body.find("["), body.rfind("]")
    if start == -1 or end == -1:
        return []
    try:
        rows = json.loads(body[start:end + 1])
    except ValueError:
        return []
    out = []
    for row in rows:
        if isinstance(row, str):
            out.append(row)
        elif isinstance(row, dict):
            artist = row.get("artist") or ""
            title = row.get("title") or row.get("track") or ""
            if title:
                out.append(("%s %s" % (artist, title)).strip())
    return out


def auto_theme(engine, cfg, model=None):
    """Invent a station for the listener when they have not described one.

    Spotify's DJ needs no input: you press it and it plays. Asking the model to
    choose the theme first keeps that one-tap behaviour while still producing
    something specific enough to search for.
    """
    top_artists = [a for a, _ in sorted(engine.taste.artists.items(),
                                        key=lambda kv: -kv[1])[:12]]
    recent = ["%s - %s" % (t["artist"], t["name"])
              for t in engine.taste.tracks[:10]]
    hour = time.localtime().tm_hour
    part = ("late night" if hour >= 22 or hour < 5 else
            "morning" if hour < 11 else
            "afternoon" if hour < 17 else "evening")

    ask = ("A listener just pressed play on an automatic radio, without saying "
           "what they want. It is %s for them.\n"
           "Their favourite artists: %s\n"
           "Recently enjoyed: %s\n\n"
           "Describe, in one short sentence, the station you would put on for "
           "them right now. Be specific about mood and genre. Reply with the "
           "sentence only."
           % (part, ", ".join(top_artists) or "unknown",
              "; ".join(recent) or "unknown"))
    try:
        theme = _ask_model(cfg, ask, model or "gemini-3.8-flash-high",
                           timeout=60).strip()
    except Exception:  # noqa: BLE001
        return "a mix of what this listener usually enjoys"
    theme = theme.strip().strip('"').split("\n")[0]
    return theme[:200] or "a mix of what this listener usually enjoys"


# A station is built in two waves so playback can start while the rest is
# still being found. Measured on this machine: asking for 40 songs takes the
# model ~11s and resolving them one at a time another ~9s, so the old
# single-shot path left the listener staring at a spinner for twenty seconds.
# A six-song ask answers in ~4.4s and resolves in ~0.5s when the lookups run
# together, so the first tracks play at about five seconds and the station
# keeps growing underneath them - which is how Spotify's stations feel.
SPRINT = 6
_stations = {}
_stations_guard = threading.Lock()
STATION_TTL = 60 * 45

_radio_pool = concurrent.futures.ThreadPoolExecutor(
    max_workers=3, thread_name_prefix="airadio")
# Separate from the pool above: the whole point is that a station's lookups
# run together, which they cannot do if they are queued behind the jobs that
# spawned them.
_radio_search_pool = concurrent.futures.ThreadPoolExecutor(
    max_workers=8, thread_name_prefix="airadiosearch")


def _radio_prompt(prompt, engine, count):
    top_artists = [a for a, _ in sorted(engine.taste.artists.items(),
                                        key=lambda kv: -kv[1])[:12]]
    liked = ["%s - %s" % (t["artist"], t["name"])
             for t in engine.taste.tracks[:8]]
    return (
        "You are building a music radio station.\n\n"
        "Request: %s\n\n"
        "The listener's usual taste, for context only - the request above wins "
        "if the two conflict:\n"
        "  favourite artists: %s\n"
        "  recently enjoyed: %s\n\n"
        "List %d real, existing songs that fit the request. Vary the artists: "
        "at most two songs by any one artist. Prefer well-known recordings that "
        "are actually on YouTube Music.\n"
        "Respond with ONLY a JSON array of objects, each {\"artist\": ..., "
        "\"title\": ...}, and no other text."
        % (prompt, ", ".join(top_artists) or "unknown",
           "; ".join(liked) or "unknown", count))


def _sprint_ask(prompt, engine, auto):
    """The opening call: just enough songs to press play on.

    Deliberately does not ask the model to name the station. Inventing a theme
    is the slowest thing this endpoint does - about ten seconds, measured, for
    one line of text - and nobody is reading the name during the silence before
    the first note. The slow wave names it, and the client picks that up.
    """
    if not auto:
        return _radio_prompt(prompt, engine, SPRINT)

    top_artists = [a for a, _ in sorted(engine.taste.artists.items(),
                                        key=lambda kv: -kv[1])[:12]]
    liked = ["%s - %s" % (t["artist"], t["name"])
             for t in engine.taste.tracks[:12]]
    # Worded flatly on purpose. Asking the model to *reason* about staying
    # fresh - "reach for songs next to their taste" - doubled this call, from
    # 6.2s to 13.2s measured. A plain list of what not to play buys the same
    # freshness at half the wait, and the wait is all the listener sees.
    return (
        "A listener's favourite artists: %s.\n"
        "They already play these a lot: %s.\n"
        "Name %d real, existing songs they would enjoy right now. Do not name "
        "any song in that second list. At most one song per artist.\n"
        "Respond with ONLY a JSON array of objects, each {\"artist\": ..., "
        "\"title\": ...}, and no other text."
        % (", ".join(top_artists) or "unknown",
           "; ".join(liked) or "unknown", SPRINT))


def _resolve_together(engine, queries):
    """Look every proposal up on YouTube Music at once, keeping the order.

    The model's ordering is the station's ordering, so results are zipped back
    onto the queries rather than collected as they happen to finish.
    """
    if not queries:
        return []
    visitor = engine.visitor()
    futures = [_radio_search_pool.submit(rec.search_song, query, visitor,
                                         engine.cookie)
               for query in queries]
    out = []
    for future in futures:
        try:
            out.append(future.result(timeout=25))
        except Exception:  # noqa: BLE001
            out.append(None)
    return out


# Each wave is told "at most two songs by any one artist" and each obeys it,
# but the two obey it separately, so their union did not. The cap has to be
# held by the station.
PER_ARTIST = 2


def _admit(engine, state, found):
    """Add resolved songs to a station, skipping repeats and past rejections."""
    added = 0
    with state["lock"]:
        for track in found:
            if not track or len(state["tracks"]) >= state["limit"]:
                continue
            key = rec.identity(track)
            if track["videoId"] in state["seen_ids"] or key in state["seen_keys"]:
                continue
            if engine.learned.is_rejected(key):
                continue
            # "It keeps playing the songs I already like too much." The
            # opening prompt says not to, and the model mostly listens, but
            # mostly is not enough when the listener notices every time.
            if key in state["avoid"]:
                continue
            artist = (track.get("artist") or "").strip().casefold()
            if artist and state["artists"].get(artist, 0) >= PER_ARTIST:
                continue
            state["seen_ids"].add(track["videoId"])
            state["seen_keys"].add(key)
            state["artists"][artist] = state["artists"].get(artist, 0) + 1
            track["source"] = "airadio"
            state["tracks"].append(_track_row(track))
            added += 1
    return added


def _fill_station(engine, state, cfg, model):
    """The long tail, built behind the tracks that are already playing.

    In auto mode this also names the station, since it is the wave that can
    afford to think about it.
    """
    try:
        if state["auto"]:
            state["prompt"] = auto_theme(engine, cfg, model)
        raw = _ask_model(cfg, _radio_prompt(state["prompt"], engine,
                                            min(state["limit"] * 2, 40)),
                         model or "gemini-3.8-flash-high")
        queries = _parse_list(raw)
        if not queries:
            state["error"] = state["error"] or "model returned no usable songs"
        else:
            _admit(engine, state, _resolve_together(engine, queries))
    except Exception as e:  # noqa: BLE001
        state["error"] = state["error"] or ("model call failed: %s"
                                            % str(e)[:200])
    finally:
        state["pending"] = False


def _station_view(state, after=0):
    with state["lock"]:
        rows = list(state["tracks"])
    return {"station": state["id"], "prompt": state["prompt"],
            "auto": state["auto"], "total": len(rows),
            "tracks": rows[max(0, after):],
            "pending": bool(state["pending"]),
            "error": state["error"], "resolved": len(rows)}


def _expire_stations(now):
    with _stations_guard:
        for key in [k for k, v in _stations.items()
                    if now - v["created"] > STATION_TTL]:
            _stations.pop(key, None)


def ai_radio(engine, prompt, limit=20, model=None, station=None, after=0):
    """Build a station from a free-text description, first tracks first.

    The model proposes songs; every proposal is then looked up on YouTube Music
    and only real matches survive. That keeps the useful part of an LLM - taste
    and theme - while making it impossible for an invented title to reach the
    queue as an unplayable row.

    Passing `station` returns what that station has found since, so the client
    can start on the opening handful and append the rest as it arrives.
    """
    now = time.time()
    _expire_stations(now)

    if station:
        with _stations_guard:
            state = _stations.get(station)
        if not state:
            return {"error": "unknown station", "station": station,
                    "tracks": [], "pending": False, "total": 0}
        return _station_view(state, after)

    cfg = _ai_config()
    if not cfg:
        return {"error": "no AI endpoint configured (ai.env missing)",
                "prompt": prompt, "tracks": [], "pending": False, "total": 0}

    engine.taste.refresh()

    # No prompt means "just play something": the opening call invents the
    # theme as well, and the long wave then builds around the same idea.
    auto = not (prompt or "").strip()

    # An automatic station is meant to widen the listener's taste, so their
    # own heaviest rotation is held out of it. A station they asked for by
    # name is not: "play me some MIMI" should play MIMI.
    avoid = set()
    if auto:
        avoid = {rec.identity({"artist": row["artist"], "title": row["name"]})
                 for row in engine.taste.tracks[:40]}

    state = {"id": uuid.uuid4().hex[:12], "prompt": prompt, "auto": auto,
             "limit": limit, "tracks": [], "seen_ids": set(), "seen_keys": set(),
             "artists": {}, "avoid": avoid,
             "pending": True, "error": None, "created": now,
             "lock": threading.Lock()}
    with _stations_guard:
        _stations[state["id"]] = state

    # Both waves start at once and do not slow each other down (measured: a
    # six-song ask still answers in ~4s alongside a forty-song one).
    tail = _radio_pool.submit(_fill_station, engine, state, cfg, model)

    try:
        raw = _ask_model(cfg, _sprint_ask(prompt, engine, auto),
                         model or "gemini-3.8-flash-high",
                         max_tokens=260, timeout=40)
        _admit(engine, state, _resolve_together(engine, _parse_list(raw)))
    except Exception as e:  # noqa: BLE001
        # A failed opening is not a failed station: fall back to the long wave
        # rather than handing back nothing.
        state["error"] = "quick pass failed: %s" % str(e)[:120]
        try:
            tail.result(timeout=90)
        except Exception:  # noqa: BLE001
            pass

    view = _station_view(state)
    if not view["tracks"] and not view["pending"]:
        view["error"] = view["error"] or "model returned no usable songs"
    return view
