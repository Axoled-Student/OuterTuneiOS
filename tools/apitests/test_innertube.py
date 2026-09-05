"""Real (network) API tests for the InnerTube endpoints the iOS app depends on.

    python tools/apitests/test_innertube.py

Authenticated tests are skipped unless YTM_COOKIE is set; see .env.example.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import innertube_client as it  # noqa: E402
from harness import Suite, load_env  # noqa: E402

VIDEO_ID = "dQw4w9WgXcQ"  # stable, always-available reference track

# itags a YouTube Music Premium session is offered that a free session is not.
PREMIUM_ITAGS = {141, 774}  # 141 = 256kbps AAC, 774 = ~256kbps opus

SEARCH_SONGS_PARAMS = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
SEARCH_VIDEOS_PARAMS = "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"


def describe_formats(formats):
    rows = []
    for f in sorted(formats, key=lambda x: -(x.get("bitrate") or 0)):
        rows.append("  itag={:<5} {:<34} bitrate={:<8} avg={:<8} {}".format(
            f.get("itag"), (f.get("mimeType") or "")[:34],
            f.get("bitrate") or 0, f.get("averageBitrate") or 0,
            f.get("audioQuality") or ""))
    return "\n".join(rows)


def run():
    env = load_env()
    cookie = env.get("YTM_COOKIE") or None
    data_sync_id = env.get("YTM_DATA_SYNC_ID") or None
    suite = Suite("InnerTube / YouTube Music")

    visitor = None
    with suite.test("fetch visitorData from music.youtube.com") as t:
        visitor = it.fetch_visitor_data()
        t.require(visitor, "visitorData not found in page HTML")
        t.note("visitorData=%s..." % visitor[:32])

    anon_best = {}
    for client in (it.IOS, it.ANDROID_VR):
        with suite.test("player[%s] anonymous -> playable audio" % client.name) as t:
            status_code, body = it.call(
                "player",
                {"videoId": VIDEO_ID, "contentCheckOk": True, "racyCheckOk": True},
                client, visitor_data=visitor)
            t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:160]))
            playability = body.get("playabilityStatus") or {}
            t.require(playability.get("status") == "OK",
                      "playabilityStatus=%s %s" % (playability.get("status"),
                                                   playability.get("reason")))
            formats = it.audio_formats(body)
            t.require(formats, "no audio formats returned")
            best = max((f.get("bitrate") or 0) for f in formats)
            anon_best[client.name] = best
            itags = sorted({f.get("itag") for f in formats})
            has_hls = bool((body.get("streamingData") or {}).get("hlsManifestUrl"))
            t.note("%d audio formats, hls=%s, itags=%s" % (len(formats), has_hls, itags))
            t.note("max bitrate = %d bps" % best)
            t.note(describe_formats(formats))
            t.require(not (PREMIUM_ITAGS & set(itags)),
                      "unexpected: premium itag offered without login")

    with suite.test("search songs returns results") as t:
        status_code, body = it.call(
            "search", {"query": "daft punk one more time", "params": SEARCH_SONGS_PARAMS},
            it.WEB_REMIX, visitor_data=visitor)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:160]))
        items = it.walk(body, "musicResponsiveListItemRenderer")
        t.require(len(items) >= 5, "only %d results" % len(items))
        types = {kind for item in items for kind in it.walk(item, "musicVideoType")
                 if isinstance(kind, str)}
        t.require("MUSIC_VIDEO_TYPE_ATV" in types,
                  "song filter did not return official audio rows: %s" % sorted(types))
        t.note("%d song rows, types=%s" % (len(items), sorted(types)))

    with suite.test("search music videos returns video results") as t:
        status_code, body = it.call(
            "search", {"query": "daft punk one more time", "params": SEARCH_VIDEOS_PARAMS},
            it.WEB_REMIX, visitor_data=visitor)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:160]))
        items = it.walk(body, "musicResponsiveListItemRenderer")
        t.require(len(items) >= 5, "only %d results" % len(items))
        types = {kind for item in items for kind in it.walk(item, "musicVideoType")
                 if isinstance(kind, str)}
        t.require(types & {"MUSIC_VIDEO_TYPE_OMV", "MUSIC_VIDEO_TYPE_UGC"},
                  "video filter did not return video rows: %s" % sorted(types))
        t.note("%d music-video rows, types=%s" % (len(items), sorted(types)))

    with suite.test("YouTube Music search suggestions return renderers") as t:
        status_code, body = it.call(
            "music/get_search_suggestions", {"input": "Sunny"},
            it.WEB_REMIX, visitor_data=visitor)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:160]))
        suggestions = it.walk(body, "searchSuggestionRenderer")
        t.require(len(suggestions) >= 3, "only %d suggestions" % len(suggestions))
        t.note("%d YouTube Music suggestions" % len(suggestions))

    with suite.test("browse FEmusic_home (anonymous) returns shelves") as t:
        status_code, body = it.call("browse", {"browseId": "FEmusic_home"},
                                    it.WEB_REMIX, visitor_data=visitor)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:160]))
        shelves = it.walk(body, "musicCarouselShelfRenderer")
        t.require(shelves, "no carousel shelves")
        t.note("%d shelves (anonymous feeds are intentionally sparse)" % len(shelves))

    with suite.test("next (RDAMVM radio) yields an auto-queue") as t:
        status_code, body = it.call(
            "next", {"videoId": VIDEO_ID, "playlistId": "RDAMVM" + VIDEO_ID,
                     "isAudioOnly": True, "params": "wAEB"},
            it.WEB_REMIX, visitor_data=visitor)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:160]))
        items = it.walk(body, "playlistPanelVideoRenderer")
        t.require(len(items) >= 20, "only %d radio tracks" % len(items))
        artwork_rows = sum(
            bool((item.get("thumbnail") or {}).get("thumbnails")) for item in items)
        byline_rows = sum(
            bool(((item.get("longBylineText") or {}).get("runs"))) for item in items)
        t.require(artwork_rows >= min(20, len(items)),
                  "only %d/%d radio rows have direct thumbnails" % (artwork_rows, len(items)))
        t.require(byline_rows >= min(20, len(items)),
                  "only %d/%d radio rows have artist bylines" % (byline_rows, len(items)))
        continuation = (it.walk(body, "nextRadioContinuationData")
                        or it.walk(body, "nextContinuationData"))
        t.note("%d radio tracks, artwork=%d, bylines=%d, continuation=%s"
               % (len(items), artwork_rows, byline_rows, bool(continuation)))

    if not cookie:
        suite.skip("account menu", "needs YTM_COOKIE")
        suite.skip("authenticated premium bitrate", "needs YTM_COOKIE")
        suite.skip("personalised home feed", "needs YTM_COOKIE")
        suite.skip("library playlists", "needs YTM_COOKIE")
        suite.skip("open a library playlist", "needs YTM_COOKIE")
        return suite.report()

    with suite.test("account menu returns the signed-in identity") as t:
        status_code, body = it.call("account/account_menu", {}, it.WEB_REMIX,
                                    cookie=cookie, visitor_data=visitor,
                                    data_sync_id=data_sync_id)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:200]))
        names = it.walk(body, "accountName")
        t.require(names, "no accountName - the cookie is probably invalid or expired")
        label = it.walk(names[0], "text")
        t.note("signed in as: %s" % (label[0] if label else "?"))

    # Only WEB_REMIX is exercised as a hard requirement: it is the client the
    # app promotes to first position when signed in, and the only one
    # observed to be offered itag 141 / 774. TVHTML5 is probed separately
    # below for information only - it needs a signature-timestamp/PoToken
    # handshake this suite does not perform, and the app never uses it.
    for client in (it.WEB_REMIX,):
        with suite.test("player[%s] authenticated -> premium bitrate" % client.name) as t:
            status_code, body = it.call(
                "player", {"videoId": VIDEO_ID, "contentCheckOk": True,
                           "racyCheckOk": True},
                client, cookie=cookie, visitor_data=visitor, data_sync_id=data_sync_id)
            t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:200]))
            playability = body.get("playabilityStatus") or {}
            t.require(playability.get("status") == "OK",
                      "playabilityStatus=%s %s" % (playability.get("status"),
                                                   playability.get("reason")))
            formats = it.audio_formats(body)
            t.require(formats, "no audio formats returned")
            itags = sorted({f.get("itag") for f in formats})
            best = max((f.get("bitrate") or 0) for f in formats)
            t.note("itags=%s" % itags)
            t.note("max bitrate = %d bps (anonymous IOS was %d bps)"
                   % (best, anon_best.get("IOS", 0)))
            t.note(describe_formats(formats))
            unlocked = PREMIUM_ITAGS & set(itags)
            if unlocked:
                t.note("PREMIUM formats unlocked: %s" % sorted(unlocked))
            else:
                t.warn("no premium itag (141/774) - the account may not have Premium, "
                       "or this client cannot request it")

    with suite.test("TVHTML5 authenticated (informational)") as t:
        status_code, body = it.call(
            "player", {"videoId": VIDEO_ID, "contentCheckOk": True, "racyCheckOk": True},
            it.TVHTML5, cookie=cookie, visitor_data=visitor, data_sync_id=data_sync_id)
        playability = (body.get("playabilityStatus") or {}) if isinstance(body, dict) else {}
        formats = it.audio_formats(body) if isinstance(body, dict) else []
        if formats:
            t.note("itags=%s" % sorted({f.get("itag") for f in formats}))
        else:
            t.warn("TVHTML5 returned no formats (status=%s %s); expected without a "
                   "signature timestamp / PoToken. The app does not use this client."
                   % (playability.get("status"), playability.get("reason")))

    with suite.test("personalised home feed") as t:
        status_code, body = it.call("browse", {"browseId": "FEmusic_home"}, it.WEB_REMIX,
                                    cookie=cookie, visitor_data=visitor,
                                    data_sync_id=data_sync_id)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:200]))
        shelves = it.walk(body, "musicCarouselShelfRenderer")
        t.require(shelves, "no shelves")
        t.note("%d shelves while signed in" % len(shelves))

    with suite.test("library playlists") as t:
        status_code, body = it.call("browse", {"browseId": "FEmusic_liked_playlists"},
                                    it.WEB_REMIX, cookie=cookie, visitor_data=visitor,
                                    data_sync_id=data_sync_id)
        t.require(status_code == 200, "HTTP %s: %s" % (status_code, str(body)[:200]))
        items = it.walk(body, "musicTwoRowItemRenderer")
        t.require(items, "no library playlist entries")
        t.note("%d library playlist entries" % len(items))

    with suite.test("open a library playlist and obtain playable rows") as t:
        browse_ids = []
        for endpoint in it.walk(body, "browseEndpoint"):
            browse_id = endpoint.get("browseId") if isinstance(endpoint, dict) else None
            if (browse_id and browse_id not in browse_ids
                    and (browse_id.startswith("VL") or browse_id.startswith("MPREb"))):
                browse_ids.append(browse_id)

        t.require(browse_ids, "library response contained no playlist browseId")
        playable_rows = []
        continuation = False
        for browse_id in browse_ids[:6]:
            status_code, playlist_body = it.call(
                "browse", {"browseId": browse_id}, it.WEB_REMIX,
                cookie=cookie, visitor_data=visitor, data_sync_id=data_sync_id)
            if status_code != 200:
                continue
            rows = it.walk(playlist_body, "musicResponsiveListItemRenderer")
            playable_rows = [row for row in rows
                             if it.walk(row, "videoId")]
            continuation = bool(it.walk(playlist_body, "continuationItemRenderer"))
            if playable_rows:
                break

        t.require(playable_rows, "playlist cards opened but returned no playable video rows")
        t.note("%d playable rows, continuation=%s"
               % (len(playable_rows), continuation))

    return suite.report()


if __name__ == "__main__":
    sys.exit(run())
