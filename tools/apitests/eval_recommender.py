"""Offline evaluation of auto-queue policies against the real APIs.

The complaint this exists to settle is measurable, not a matter of opinion:
the queue repeats the same artists, replays the same songs across successive
extensions, and drifts away from what the listener actually likes.

So build the candidate pool for real (YouTube Music radio + Deezer similarity +
the Spotify taste profile), run competing ranking policies over the *same* pool,
simulate several consecutive queue extensions, and print the numbers.

    python tools/apitests/eval_recommender.py            # all seeds
    python tools/apitests/eval_recommender.py --seeds 3  # quicker

Metrics, and what good looks like:
  seed_artist_share   picks by the seed's own artist          lower, <=0.20
  max_artist_share    largest share held by any one artist    lower, <=0.20
  unique_artists      distinct artists / picks                higher, >=0.70
  dup_identity        same recording picked twice             0.0
  repeat_across_runs  re-picked over 5 extensions             0.0
  taste_affinity      picks whose artist is in the profile    ~0.35-0.65
  discovery           picks by artists new to the profile     ~0.35-0.65
"""
import argparse
import os
import random
import re
import sys
import unicodedata
import urllib.error
import urllib.parse
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import innertube_client as it  # noqa: E402
import spotify_client as sp  # noqa: E402
from harness import load_env  # noqa: E402

SEARCH_SONGS_PARAMS = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"

# ---------------------------------------------------------------- identity


_PAREN = re.compile(r"[\(\[][^)\]]*[\)\]]")
_NOISE = re.compile(
    r"\b(official|music|lyric|lyrics|video|audio|mv|m/v|hd|hq|full|ver|version|"
    r"remaster(ed)?|live|cover|feat|ft|featuring|topic|color[ae]d|sub|subtitled|"
    r"instrumental|off vocal|karaoke)\b", re.I)
_PUNCT = re.compile(r"[^\w\s]", re.U)
_SPACE = re.compile(r"\s+")


def normalize(text):
    """Collapse a title/artist to a comparable identity."""
    if not text:
        return ""
    text = unicodedata.normalize("NFKC", str(text)).lower()
    text = _PAREN.sub(" ", text)
    text = text.replace("-", " ")
    text = _NOISE.sub(" ", text)
    text = _PUNCT.sub(" ", text)
    return _SPACE.sub(" ", text).strip()


def primary_artist(name):
    """First credited artist, so 'A feat. B' and 'A' collapse together."""
    n = normalize(name)
    for sep in (" feat ", " ft ", " featuring ", " with ", " x ", " & ", ","):
        if sep in n:
            n = n.split(sep)[0]
    return n.strip()


def identity(track):
    return "%s::%s" % (primary_artist(track.get("artist")),
                       normalize(track.get("title")))


# ---------------------------------------------------------------- sources


def text_runs(node):
    return [t for t in it.walk(node or {}, "text") if isinstance(t, str)]


def ytm_radio(video_id, visitor, cookie=None, limit=50):
    status, body = it.call(
        "next", {"videoId": video_id, "playlistId": "RDAMVM" + video_id,
                 "isAudioOnly": True, "params": "wAEB"},
        it.WEB_REMIX, cookie=cookie, visitor_data=visitor)
    if status != 200 or not isinstance(body, dict):
        return []
    out, seen = [], set()
    for index, r in enumerate(it.walk(body, "playlistPanelVideoRenderer")):
        vid = r.get("videoId")
        if not vid or vid in seen:
            continue
        titles = text_runs(r.get("title"))
        bylines = text_runs(r.get("longBylineText"))
        if not titles:
            continue
        seen.add(vid)
        out.append({"videoId": vid, "title": titles[0],
                    "artist": bylines[0] if bylines else "Unknown",
                    "source": "radio", "rank": index})
        if len(out) >= limit:
            break
    return out


def ytm_search_one(query, visitor, cookie=None):
    status, body = it.call("search", {"query": query, "params": SEARCH_SONGS_PARAMS},
                           it.WEB_REMIX, cookie=cookie, visitor_data=visitor)
    if status != 200 or not isinstance(body, dict):
        return None
    for r in it.walk(body, "musicResponsiveListItemRenderer"):
        for pid in it.walk(r, "playlistItemData"):
            if pid.get("videoId"):
                runs = [t for t in it.walk(r, "text") if isinstance(t, str)]
                runs = [t for t in runs if t.strip() and t.strip() != "•"]
                return {"videoId": pid["videoId"],
                        "title": runs[0] if runs else query,
                        "artist": runs[1] if len(runs) > 1 else "Unknown"}
    return None


def deezer_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "OuterTuneiOS/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=15) as r:
            import json
            return json.loads(r.read().decode())
    except Exception:  # noqa: BLE001
        return None


def deezer_similar_artists(name, limit=8):
    q = urllib.parse.quote(name)
    found = deezer_json("https://api.deezer.com/search/artist?q=" + q)
    if not found or not found.get("data"):
        return []
    artist_id = found["data"][0]["id"]
    rel = deezer_json("https://api.deezer.com/artist/%s/related" % artist_id)
    if not rel:
        return []
    return [a["name"] for a in rel.get("data", [])][:limit]


# ---------------------------------------------------------------- taste


def load_taste(env):
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
        return None

    taste = {"artists": {}, "tracks": [], "artist_names": []}

    def add_artists(items, base):
        for i, a in enumerate(items):
            key = primary_artist(a["name"])
            w = base * (1.0 / (1.0 + i * 0.08))
            taste["artists"][key] = taste["artists"].get(key, 0) + w
            taste["artist_names"].append(a["name"])

    for rng, base in (("short_term", 1.0), ("medium_term", 0.65), ("long_term", 0.4)):
        st, body = sp.get("/me/top/artists", token, {"limit": 40, "time_range": rng})
        if st == 200:
            add_artists(body.get("items", []), base)

    for rng, base in (("short_term", 1.0), ("medium_term", 0.6)):
        st, body = sp.get("/me/top/tracks", token, {"limit": 40, "time_range": rng})
        if st == 200:
            for i, t in enumerate(body.get("items", [])):
                taste["tracks"].append({"name": t["name"],
                                        "artist": t["artists"][0]["name"],
                                        "weight": base * (1.0 / (1.0 + i * 0.08))})
                key = primary_artist(t["artists"][0]["name"])
                taste["artists"][key] = taste["artists"].get(key, 0) + base * 0.5

    st, body = sp.get("/me/player/recently-played", token, {"limit": 40})
    if st == 200:
        for i, row in enumerate(body.get("items", [])):
            t = row.get("track") or {}
            if t.get("name"):
                taste["tracks"].append({"name": t["name"],
                                        "artist": t["artists"][0]["name"],
                                        "weight": 0.8 * (1.0 / (1.0 + i * 0.08))})
    return taste


# ---------------------------------------------------------------- policies


def policy_radio_order(pool, seed, taste, limit, blocked):
    """Today's behaviour: trust YouTube's radio ordering."""
    out = []
    seen = set(blocked)
    for c in sorted(pool, key=lambda c: (c.get("rank", 999))):
        ident = identity(c)
        if c["videoId"] in seen or ident in seen:
            continue
        seen.add(c["videoId"]); seen.add(ident)
        out.append(c)
        if len(out) >= limit:
            break
    return out


def _relevance(c, seed, taste):
    """How much this track deserves to be in the queue at all."""
    # Source relevance: radio position, decayed.
    rank = c.get("rank", 40)
    score = 1.0 / (1.0 + rank * 0.05)
    if c.get("source") == "taste":
        score = 0.85
    elif c.get("source") == "similar":
        score = 0.7

    artist_key = primary_artist(c.get("artist"))
    affinity = taste["artists"].get(artist_key, 0.0) if taste else 0.0
    # Familiar artists are good, but saturate so one favourite cannot dominate.
    score += 1.6 * (affinity / (0.6 + affinity))
    # Discovery has to be *targeted*. Rewarding any unheard artist just promotes
    # whatever filler the radio happened to return, which is what made the queue
    # feel random. Only candidates reached through a similarity edge from the
    # seed or from a taste artist earn the bonus.
    if taste and affinity == 0.0 and c.get("source") == "similar":
        score += 0.55
    return score


def _similarity(a, b):
    if primary_artist(a.get("artist")) == primary_artist(b.get("artist")):
        return 1.0
    ta, tb = set(normalize(a.get("title")).split()), set(normalize(b.get("title")).split())
    if ta and tb:
        jac = len(ta & tb) / float(len(ta | tb))
        if jac > 0.6:
            return 0.8
    if a.get("source") == b.get("source") == "radio":
        return 0.15
    return 0.0


def policy_mmr(pool, seed, taste, limit, blocked, session_artists=None,
               lam=0.72, artist_cap=2, spacing=4, session_artist_cap=3):
    """Relevance/diversity trade-off with hard artist caps and spacing.

    Maximal Marginal Relevance is the standard fix for "the list is all one
    thing": each pick is scored on its own merit minus how similar it is to
    what has already been picked. The caps make artist domination impossible
    rather than merely unlikely.
    """
    seen = set(blocked)
    # Counts carried across batches. Without this an artist simply takes
    # its per-batch allowance again on every extension, which is how the
    # seed artist ended up holding a third of a long session.
    session_artists = session_artists if session_artists is not None else {}
    chosen, artist_counts = [], {}

    scored = []
    for c in pool:
        ident = identity(c)
        if c["videoId"] in seen or ident in seen:
            continue
        scored.append((c, _relevance(c, seed, taste)))

    while scored and len(chosen) < limit:
        best, best_val = None, None
        for c, rel in scored:
            # Re-check identity here, not only while building the list: two
            # different videoIds routinely carry the same recording (topic
            # upload vs MV vs remaster), and the second copy slipped through.
            if identity(c) in seen:
                continue
            artist_key = primary_artist(c.get("artist"))
            if artist_counts.get(artist_key, 0) >= artist_cap:
                continue
            if session_artists.get(artist_key, 0) >= session_artist_cap:
                continue
            # Artist spacing: never stack the same artist back to back.
            recent = [primary_artist(x.get("artist")) for x in chosen[-spacing:]]
            if artist_key in recent:
                continue
            penalty = max((_similarity(c, x) for x in chosen), default=0.0)
            val = lam * rel - (1.0 - lam) * penalty
            if best_val is None or val > best_val:
                best, best_val = c, val
        if best is None:
            # Constraints exhausted the pool; relax spacing before giving up.
            if spacing > 0:
                spacing -= 1
                continue
            break
        chosen.append(best)
        key = primary_artist(best.get("artist"))
        artist_counts[key] = artist_counts.get(key, 0) + 1
        session_artists[key] = session_artists.get(key, 0) + 1
        seen.add(best["videoId"]); seen.add(identity(best))
        chosen_identity = identity(best)
        scored = [(c, r) for c, r in scored
                  if c["videoId"] != best["videoId"] and identity(c) != chosen_identity]

    return chosen


def policy_quota(pool, seed, taste, limit, blocked,
                 pattern=("radio", "familiar", "radio", "discovery",
                          "radio", "familiar", "radio", "discovery",
                          "familiar", "radio"),
                 artist_cap=2, spacing=4):
    """Stratified interleave - the shape of a Spotify radio.

    Scoring alone cannot guarantee a *blend*: whichever signal is strongest
    takes every slot, which is why the queue came out either all-seed-artist or
    all-unknowns. Assigning each position a bucket up front fixes the mix, and
    relevance only decides who wins within a bucket.

      familiar   an artist already in the taste profile
      discovery  unheard, but reached by a similarity edge (not random filler)
      radio      whatever YouTube considers closest to the seed
    """
    seed_artist = primary_artist(seed.get("artist"))
    seen = set(blocked)

    buckets = {"familiar": [], "discovery": [], "radio": []}
    for c in pool:
        if c["videoId"] in seen or identity(c) in seen:
            continue
        affinity = taste["artists"].get(primary_artist(c.get("artist")), 0.0) if taste else 0.0
        if affinity > 0:
            buckets["familiar"].append(c)
        elif c.get("source") == "similar":
            buckets["discovery"].append(c)
        else:
            buckets["radio"].append(c)
    for name in buckets:
        buckets[name].sort(key=lambda c: -_relevance(c, seed, taste))

    chosen, artist_counts = [], {}

    def take(bucket_name):
        for c in buckets[bucket_name]:
            if c["videoId"] in seen or identity(c) in seen:
                continue
            key = primary_artist(c.get("artist"))
            if artist_counts.get(key, 0) >= artist_cap:
                continue
            if key in [primary_artist(x.get("artist")) for x in chosen[-spacing:]]:
                continue
            return c
        return None

    position = 0
    while len(chosen) < limit:
        wanted = pattern[position % len(pattern)]
        position += 1
        # Fall back through the other buckets rather than emitting a short queue.
        pick = None
        for name in (wanted, "radio", "familiar", "discovery"):
            pick = take(name)
            if pick:
                break
        if pick is None:
            break
        chosen.append(pick)
        key = primary_artist(pick.get("artist"))
        artist_counts[key] = artist_counts.get(key, 0) + 1
        seen.add(pick["videoId"])
        seen.add(identity(pick))

    return chosen


# ---------------------------------------------------------------- metrics


def measure(runs, seed, taste):
    """runs: list of lists of picks, one per successive queue extension."""
    flat = [t for run in runs for t in run]
    if not flat:
        return None

    seed_artist = primary_artist(seed.get("artist"))
    artists = [primary_artist(t.get("artist")) for t in flat]
    counts = {}
    for a in artists:
        counts[a] = counts.get(a, 0) + 1

    idents = [identity(t) for t in flat]
    dup = len(idents) - len(set(idents))

    vids = [t["videoId"] for t in flat]
    repeats = len(vids) - len(set(vids))

    known = sum(1 for a in artists if taste and taste["artists"].get(a, 0) > 0)

    return {
        "picks": len(flat),
        "seed_artist_share": counts.get(seed_artist, 0) / float(len(flat)),
        "max_artist_share": max(counts.values()) / float(len(flat)),
        "unique_artists": len(counts) / float(len(flat)),
        "dup_identity": dup / float(len(flat)),
        "repeat_across_runs": repeats / float(len(flat)),
        "taste_affinity": known / float(len(flat)),
        "discovery": 1.0 - known / float(len(flat)),
    }


def fmt(m):
    return ("picks=%3d  seedArtist=%.2f  maxArtist=%.2f  uniqArtists=%.2f  "
            "dup=%.2f  repeat=%.2f  taste=%.2f  discover=%.2f"
            % (m["picks"], m["seed_artist_share"], m["max_artist_share"],
               m["unique_artists"], m["dup_identity"], m["repeat_across_runs"],
               m["taste_affinity"], m["discovery"]))


# ---------------------------------------------------------------- driver


def build_pool(seed, taste, visitor, cookie, multi_seed=True):
    """Candidate pool. `multi_seed` widens it beyond the seed's own radio."""
    pool = []
    pool.extend(ytm_radio(seed["videoId"], visitor, cookie, limit=50))

    if multi_seed and taste:
        # Radio seeded from taste tracks. Rotating which ones are used stops
        # successive extensions converging on the same handful of songs.
        extra = [t for t in taste["tracks"][:24]
                 if primary_artist(t["artist"]) != primary_artist(seed["artist"])]
        random.shuffle(extra)
        for t in extra[:3]:
            found = ytm_search_one("%s %s" % (t["artist"], t["name"]), visitor, cookie)
            if found:
                for row in ytm_radio(found["videoId"], visitor, cookie, limit=20):
                    row["source"] = "taste"
                    pool.append(row)

        # Targeted discovery: artists adjacent to the seed *and* to the
        # listener's own top artists, so "new" still means "near what you like".
        anchors = [seed["artist"]]
        anchors += [a for a, _ in sorted(taste["artists"].items(),
                                         key=lambda kv: -kv[1])[:3]]
        for anchor in anchors:
            for name in deezer_similar_artists(anchor, limit=3):
                found = ytm_search_one(name, visitor, cookie)
                if found:
                    found["source"] = "similar"
                    found["rank"] = 50
                    pool.append(found)

    # de-dupe the pool itself by videoId
    seen, uniq = set(), []
    for c in pool:
        if c["videoId"] in seen:
            continue
        seen.add(c["videoId"])
        uniq.append(c)
    return uniq


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--seeds", type=int, default=5)
    parser.add_argument("--runs", type=int, default=5, help="successive extensions")
    parser.add_argument("--limit", type=int, default=10, help="tracks per extension")
    args = parser.parse_args()

    random.seed(7)
    env = load_env()
    cookie = env.get("YTM_COOKIE") or None
    visitor = it.fetch_visitor_data()
    taste = load_taste(env)

    if taste:
        top = sorted(taste["artists"].items(), key=lambda kv: -kv[1])[:10]
        print("Spotify taste: %d artists, %d tracks" %
              (len(taste["artists"]), len(taste["tracks"])))
        print("  top: %s" % ", ".join(a for a, _ in top))
    else:
        print("No Spotify token - taste metrics will be empty")
    print()

    # A deliberately mixed seed set: the listener's own favourites plus
    # something outside their profile, so the policy is not tuned to one genre.
    wanted = []
    if taste:
        for t in taste["tracks"][:4]:
            wanted.append("%s %s" % (t["artist"], t["name"]))
    wanted += ["YOASOBI アイドル", "Daft Punk One More Time", "Taylor Swift Cruel Summer"]
    wanted = wanted[:args.seeds]

    results = {"radio": [], "mmr": [], "quota": []}

    for query in wanted:
        seed = ytm_search_one(query, visitor, cookie)
        if not seed:
            print("!! could not resolve seed: %s" % query)
            continue
        print("=" * 78)
        print("SEED  %s - %s" % (seed["artist"], seed["title"]))
        print("=" * 78)

        narrow_pool = build_pool(seed, taste, visitor, cookie, multi_seed=False)
        wide_pool = build_pool(seed, taste, visitor, cookie, multi_seed=True)
        print("  pools: seed-radio=%d  multi-source=%d"
              % (len(narrow_pool), len(wide_pool)))

        for name, policy, pool in (("radio", policy_radio_order, narrow_pool),
                                   ("mmr", policy_mmr, wide_pool),
                                   ("quota", policy_quota, wide_pool)):
            blocked = {seed["videoId"], identity(seed)}
            session_artists = {}
            runs = []
            for _ in range(args.runs):
                if policy is policy_mmr:
                    picks = policy(pool, seed, taste, args.limit, blocked,
                                   session_artists=session_artists)
                else:
                    picks = policy(pool, seed, taste, args.limit, blocked)
                if not picks:
                    break
                runs.append(picks)
                # A real session would not re-offer what it just queued.
                for p in picks:
                    blocked.add(p["videoId"])
                    blocked.add(identity(p))
            m = measure(runs, seed, taste)
            if m:
                results[name].append(m)
                print("  %-6s %s" % (name, fmt(m)))
                if name == "quota":
                    print("         first 8: %s" % "; ".join(
                        "%s - %s" % (p["artist"][:18], p["title"][:26])
                        for p in (runs[0][:8] if runs else [])))
        print()

    print("=" * 78)
    print("AVERAGES")
    print("=" * 78)
    for name in ("radio", "mmr", "quota"):
        rows = results[name]
        if not rows:
            continue
        avg = {k: sum(r[k] for r in rows) / len(rows) for k in rows[0]}
        print("  %-6s %s" % (name, fmt(avg)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
