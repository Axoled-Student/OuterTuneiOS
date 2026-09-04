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

SEARCH_SONGS_PARAMS = "EgWKAQIIAWoKEAoQCRADEAQQBQ%3D%3D"


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
        t.note("%d song rows" % len(items))

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
        continuation = (it.walk(body, "nextRadioContinuationData")
                        or it.walk(body, "nextContinuationData"))
        t.note("%d radio tracks, continuation=%s" % (len(items), bool(continuation)))

    if not cookie:
        suite.skip("account menu", "needs YTM_COOKIE")
        suite.skip("authenticated premium bitrate", "needs YTM_COOKIE")
        suite.skip("personalised home feed", "needs YTM_COOKIE")
        suite.skip("library playlists", "needs YTM_COOKIE")
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

    for client in (it.WEB_REMIX, it.TVHTML5):
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
        t.note("%d library playlist entries" % len(items))

    return suite.report()


if __name__ == "__main__":
    sys.exit(run())
