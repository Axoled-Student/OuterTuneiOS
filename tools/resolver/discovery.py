"""Home shelves and prompt-driven AI radio.

Both live server side for the same reason the queue does: the algorithm can
change without shipping a new build, and this machine already holds the Spotify
profile and a signed-in YouTube session.
"""
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request

import recommender as rec

HERE = os.path.dirname(os.path.abspath(__file__))
# tools/resolver/discovery.py -> repo root is three levels up.
AI_ENV = os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "ai.env")

_home_cache = {"payload": None, "at": 0}
_home_lock = threading.Lock()
HOME_TTL = 60 * 20

# Seed queries per language, used only when the listener's own profile has
# nothing in that script to build a shelf from.
FALLBACK_SEEDS = {
    "latin": ["top hits english", "pop hits 2026", "indie pop essentials"],
    "jp": ["j-pop hits", "vocaloid best", "anime opening hits"],
    "han": ["華語流行", "mandopop hits", "c-pop 熱門"],
    "kr": ["k-pop hits", "korean r&b"],
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


def _seeds_for_script(engine, script, wanted=3):
    """Taste tracks in a given writing system, best first."""
    taste = engine.taste
    rows = [t for t in taste.tracks
            if rec.script_of("%s %s" % (t["name"], t["artist"])) == script]
    rows.sort(key=lambda t: -t.get("weight", 0))
    seen, picked = set(), []
    for row in rows:
        key = rec.primary_artist(row["artist"])
        if key in seen:
            continue
        seen.add(key)
        picked.append("%s %s" % (row["artist"], row["name"]))
        if len(picked) >= wanted:
            break
    return picked


def _shelf_from_queries(engine, visitor, queries, script, per):
    """Resolve queries to seeds, then take their radios as shelf material."""
    seen_ids, seen_identities = set(), set()
    rows = []
    for query in queries:
        found = rec.search_song(query, visitor, engine.cookie)
        if not found:
            continue
        rows.append(found)
        for candidate in rec.radio(found["videoId"], visitor, engine.cookie,
                                   limit=12):
            if script and rec.track_script(candidate) != script:
                continue
            rows.append(candidate)
        if len(rows) >= per * 3:
            break

    if script:
        rows = [r for r in rows if rec.track_script(r) == script]
    # Keep one track per artist so a shelf is a browse surface, not a discography.
    per_artist, spread = set(), []
    for row in rows:
        key = rec.primary_artist(row.get("artist"))
        if key in per_artist:
            continue
        per_artist.add(key)
        spread.append(row)
    return [_track_row(r) for r in _dedupe(spread, seen_ids, seen_identities, per)]


def home(engine, per=12, force=False):
    """Language-split browse shelves plus a personalised one."""
    with _home_lock:
        cached = _home_cache["payload"]
        if cached and not force and time.time() - _home_cache["at"] < HOME_TTL:
            return cached

    engine.taste.refresh()
    visitor = engine.visitor()
    sections = []

    for key, title, script in SECTION_TITLES:
        try:
            if key == "madeForYou":
                queries = _seeds_for_script(engine, "latin", 1) \
                    + _seeds_for_script(engine, "jp", 1) \
                    + _seeds_for_script(engine, "han", 1)
                if not queries:
                    queries = FALLBACK_SEEDS["latin"][:2]
                items = _shelf_from_queries(engine, visitor, queries, None, per)
                subtitle = "來自你的 Spotify 聆聽紀錄"
            elif key == "discover":
                anchors = [a for a, _ in sorted(engine.taste.artists.items(),
                                                key=lambda kv: -kv[1])[:3]]
                names = []
                for anchor in anchors:
                    names += rec.deezer_similar_artists(anchor, limit=3)
                items = _shelf_from_queries(engine, visitor, names[:6], None, per)
                subtitle = "與你常聽的藝人相近"
            else:
                # Genuine popular-language seeds come first. Seeding purely from
                # the listener's own tracks made the "English" shelf romanised
                # J-pop, because script alone cannot tell "PPPP (feat. Hatsune
                # Miku)" from Western pop. Their own taste in that script is
                # still appended, so the shelf stays personal where it can be.
                queries = list(FALLBACK_SEEDS.get(script, []))
                personal = _seeds_for_script(engine, script, 2)
                queries += personal
                subtitle = "熱門與你的喜好" if personal else "熱門"
                items = _shelf_from_queries(engine, visitor, queries, script, per)
        except Exception:  # noqa: BLE001
            items = []

        if items:
            sections.append({"id": key, "title": title,
                             "subtitle": subtitle, "items": items})

    payload = {"sections": sections,
               "tasteArtists": len(engine.taste.artists),
               "generatedAt": int(time.time())}
    with _home_lock:
        _home_cache["payload"] = payload
        _home_cache["at"] = time.time()
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


def _ask_model(cfg, prompt, model="gemini-3.8-flash-high", timeout=90):
    body = {"model": model,
            "messages": [{"role": "user", "content": prompt}],
            "temperature": 0.7, "max_tokens": 2000}
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


def ai_radio(engine, prompt, limit=20, model=None):
    """Build a station from a free-text description.

    The model proposes songs; every proposal is then looked up on YouTube Music
    and only real matches survive. That keeps the useful part of an LLM - taste
    and theme - while making it impossible for an invented title to reach the
    queue as an unplayable row.
    """
    cfg = _ai_config()
    if not cfg:
        return {"error": "no AI endpoint configured (ai.env missing)",
                "prompt": prompt, "tracks": []}

    engine.taste.refresh()
    top_artists = [a for a, _ in sorted(engine.taste.artists.items(),
                                        key=lambda kv: -kv[1])[:12]]
    liked = ["%s - %s" % (t["artist"], t["name"])
             for t in engine.taste.tracks[:8]]

    ask = (
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
           "; ".join(liked) or "unknown", min(limit * 2, 40)))

    try:
        raw = _ask_model(cfg, ask, model or "gemini-3.8-flash-high")
    except Exception as e:  # noqa: BLE001
        return {"error": "model call failed: %s" % str(e)[:200],
                "prompt": prompt, "tracks": []}

    queries = _parse_list(raw)
    if not queries:
        return {"error": "model returned no usable songs", "prompt": prompt,
                "tracks": []}

    visitor = engine.visitor()
    resolved, seen_ids, seen_identities = [], set(), set()
    for query in queries:
        if len(resolved) >= limit:
            break
        found = rec.search_song(query, visitor, engine.cookie)
        if not found:
            continue
        key = rec.identity(found)
        if found["videoId"] in seen_ids or key in seen_identities:
            continue
        if engine.learned.is_rejected(key):
            continue
        seen_ids.add(found["videoId"])
        seen_identities.add(key)
        found["source"] = "airadio"
        resolved.append(found)

    return {
        "prompt": prompt,
        "requested": len(queries),
        "resolved": len(resolved),
        "tracks": [_track_row(t) for t in resolved],
    }
