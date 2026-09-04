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
import sys
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import innertube_client as it  # noqa: E402
import spotify_client as sp  # noqa: E402
from harness import Suite, load_env  # noqa: E402

BROWSER_UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36")


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


def ytm_radio(video_id, visitor, limit=40):
    st, body = it.call("next", {"videoId": video_id, "playlistId": "RDAMVM" + video_id,
                                "isAudioOnly": True, "params": "wAEB"},
                       it.WEB_REMIX, visitor_data=visitor)
    if st != 200 or not isinstance(body, dict):
        return []
    out = []
    for r in it.walk(body, "playlistPanelVideoRenderer"):
        vid = r.get("videoId")
        titles = it.walk(r.get("title", {}), "text")
        subs = it.walk(r.get("longBylineText", {}), "text")
        if vid and titles:
            out.append({"videoId": vid, "title": titles[0],
                        "artist": subs[0] if subs else "Unknown"})
    # de-dupe, preserving order
    seen, uniq = set(), []
    for row in out:
        if row["videoId"] not in seen:
            seen.add(row["videoId"])
            uniq.append(row)
    return uniq[:limit]


def ytm_search_track(query, visitor):
    st, body = it.call("search", {"query": query,
                                  "params": "EgWKAQIIAWoKEAoQCRADEAQQBQ%3D%3D"},
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
                        "artist": texts[2] if len(texts) > 2 else "Unknown"}
    return None


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
    top_artists, top_tracks = [], []
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
            status, body = sp.get("/me/top/artists", token,
                                  {"limit": 20, "time_range": "medium_term"})
            t.require(status == 200, "top artists HTTP %s" % status)
            top_artists = [a["name"] for a in body.get("items", [])]
            status, body = sp.get("/me/top/tracks", token,
                                  {"limit": 20, "time_range": "medium_term"})
            t.require(status == 200, "top tracks HTTP %s" % status)
            top_tracks = [(x["name"], x["artists"][0]["name"]) for x in body.get("items", [])]
            t.require(top_artists or top_tracks, "profile is empty")
            t.note("top artists: %s" % ", ".join(top_artists[:6]))
            t.note("top tracks: %s" % ", ".join("%s - %s" % (n, a)
                                                for n, a in top_tracks[:4]))

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

    # --- 4. LLM re-rank ----------------------------------------------------
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
