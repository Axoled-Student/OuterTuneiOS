"""Capability probe for the Spotify Web API.

Spotify permanently deprecated several recommendation endpoints on 2024-11-27
for apps created after that date. Rather than guess what a given account/app
can reach, this suite probes each endpoint and prints a capability matrix that
the recommendation engine's design follows.

    python tools/apitests/spotify_login.py   # once, to obtain a token
    python tools/apitests/test_spotify.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spotify_client as sp  # noqa: E402
from harness import Suite, load_env  # noqa: E402

# Endpoints Spotify removed for apps registered after 2024-11-27.
DEPRECATED_SINCE_2024_11 = {
    "/recommendations",
    "/audio-features",
    "/audio-analysis",
    "/artists/{id}/related-artists",
    "/browse/featured-playlists",
}


def resolve_token(env):
    token = env.get("SPOTIFY_ACCESS_TOKEN")
    if token:
        return token
    stored = sp.load_tokens()
    if not stored:
        return None
    client_id = env.get("SPOTIFY_CLIENT_ID")
    if stored.get("refresh_token") and client_id:
        try:
            refreshed = sp.refresh_token(client_id, stored["refresh_token"])
            stored.update(refreshed)
            sp.save_tokens(stored)
        except Exception as e:  # noqa: BLE001
            print("token refresh failed (%s); using stored access token" % e)
    return stored.get("access_token")


def run():
    env = load_env()
    token = resolve_token(env)
    suite = Suite("Spotify Web API capability probe")

    if not token:
        suite.skip("all Spotify tests",
                   "no token - run: python tools/apitests/spotify_login.py")
        return suite.report()

    seed_artist = None
    seed_track = None
    capabilities = {}

    def probe(label, path, params=None, expect_key=None, records=True):
        """Probe one endpoint and record whether it is usable."""
        with suite.test(label) as t:
            status, body = sp.get(path, token, params)
            if status == 200:
                if records:
                    capabilities[label] = "available"
                if expect_key:
                    t.require(expect_key in body,
                              "200 but %r missing from response" % expect_key)
                t.note("HTTP 200")
                return body
            if status in (403, 404):
                if records:
                    capabilities[label] = "DEPRECATED/blocked (HTTP %d)" % status
                message = body.get("error", {}).get("message", "") if isinstance(body, dict) else str(body)[:120]
                t.warn("HTTP %d - %s" % (status, message or "no message"))
                t.warn("this endpoint is unavailable to this app; the engine "
                       "must not depend on it")
                return None
            if records:
                capabilities[label] = "error HTTP %s" % status
            t.require(False, "HTTP %s: %s" % (status, str(body)[:200]))
            return None

    # --- identity ----------------------------------------------------------
    with suite.test("GET /me (token is valid)") as t:
        status, body = sp.get("/me", token)
        t.require(status == 200, "HTTP %s: %s" % (status, str(body)[:200]))
        t.note("account: %s (%s, product=%s, country=%s)" % (
            body.get("display_name"), body.get("id"),
            body.get("product"), body.get("country")))

    # --- taste-profile sources (expected to remain available) --------------
    top_artists = probe("GET /me/top/artists", "/me/top/artists",
                        {"limit": 20, "time_range": "medium_term"}, "items")
    if top_artists and top_artists.get("items"):
        seed_artist = top_artists["items"][0]["id"]
        names = [a["name"] for a in top_artists["items"][:5]]
        genres = sorted({g for a in top_artists["items"] for g in a.get("genres", [])})
        print("       top artists: %s" % ", ".join(names))
        print("       genres seen: %s" % ", ".join(genres[:12]))

    top_tracks = probe("GET /me/top/tracks", "/me/top/tracks",
                       {"limit": 20, "time_range": "medium_term"}, "items")
    if top_tracks and top_tracks.get("items"):
        seed_track = top_tracks["items"][0]["id"]
        print("       top tracks: %s" % ", ".join(
            "%s - %s" % (t["name"], t["artists"][0]["name"])
            for t in top_tracks["items"][:5]))

    probe("GET /me/player/recently-played", "/me/player/recently-played",
          {"limit": 20}, "items")
    probe("GET /me/tracks (saved)", "/me/tracks", {"limit": 20}, "items")
    probe("GET /me/following (artists)", "/me/following",
          {"type": "artist", "limit": 20})
    probe("GET /me/playlists", "/me/playlists", {"limit": 20}, "items")
    probe("GET /search", "/search",
          {"q": "daft punk", "type": "track,artist", "limit": 5})

    if seed_artist:
        probe("GET /artists/{id}/top-tracks", "/artists/%s/top-tracks" % seed_artist,
              {"market": "US"})

    # --- endpoints deprecated in Nov 2024 ----------------------------------
    if seed_track:
        probe("GET /recommendations  [deprecated 2024-11-27]", "/recommendations",
              {"seed_tracks": seed_track, "limit": 10})
        probe("GET /audio-features   [deprecated 2024-11-27]",
              "/audio-features/%s" % seed_track)
    if seed_artist:
        probe("GET /artists/{id}/related-artists  [deprecated 2024-11-27]",
              "/artists/%s/related-artists" % seed_artist)
    probe("GET /browse/featured-playlists  [deprecated 2024-11-27]",
          "/browse/featured-playlists", {"limit": 5})

    # --- capability matrix --------------------------------------------------
    print("\n%s\nCAPABILITY MATRIX (drives SpotifyRecommendationEngine)\n%s"
          % ("-" * 72, "-" * 72))
    for label, state in capabilities.items():
        print("  %-52s %s" % (label, state))

    legacy = capabilities.get("GET /recommendations  [deprecated 2024-11-27]")
    print("\n  => %s" % (
        "This app still has /recommendations: the engine will use the real "
        "Spotify algorithm directly."
        if legacy == "available" else
        "This app CANNOT use /recommendations. The engine will build a taste "
        "profile from top/recent/saved/followed data and expand it through the "
        "YouTube Music radio engine."))
    print("-" * 72)

    return suite.report()


if __name__ == "__main__":
    sys.exit(run())
