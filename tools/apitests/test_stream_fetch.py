"""Does the stream URL actually deliver bytes?

Resolving a player response only proves YouTube *described* a format. The app
then fetches that googlevideo URL, and that second request is where HTTP 403
shows up. This suite reproduces the app's exact download request per client and
per itag so a 403 can be attributed to the client profile rather than guessed at.

    python tools/apitests/test_stream_fetch.py [videoId]
"""
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import innertube_client as it  # noqa: E402
from harness import Suite, load_env  # noqa: E402

DEFAULT_QUERY = "MIMI くうになる"
SEARCH_SONGS_PARAMS = "EgWKAQIIAWoKEAoQCRADEAQQBQ%3D%3D"


def probe_stream(url, user_agent):
    """Mirror AudioPlayerViewModel.downloadAndRemux: no cookies, identity
    encoding, ranged GET. Returns (status, bytes_read, note)."""
    request = urllib.request.Request(url)
    request.add_header("User-Agent", user_agent)
    request.add_header("Accept-Encoding", "identity")
    # The app asks for the whole object with an open range, yt-dlp style.
    request.add_header("Range", "bytes=0-65535")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            chunk = response.read(65536)
            return response.status, len(chunk), response.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e:
        body = e.read()[:120].decode(errors="replace").replace("\n", " ")
        return e.code, 0, body
    except Exception as e:  # noqa: BLE001
        return 0, 0, "EXC " + str(e)


def resolve_video_id(visitor, cookie):
    if len(sys.argv) > 1:
        return sys.argv[1], "(from argv)"
    status, body = it.call("search", {"query": DEFAULT_QUERY,
                                      "params": SEARCH_SONGS_PARAMS},
                           it.WEB_REMIX, cookie=cookie, visitor_data=visitor)
    if status != 200 or not isinstance(body, dict):
        return None, "search failed HTTP %s" % status
    for renderer in it.walk(body, "musicResponsiveListItemRenderer"):
        for item in it.walk(renderer, "playlistItemData"):
            if item.get("videoId"):
                return item["videoId"], DEFAULT_QUERY
    return None, "no videoId in search results"


def run():
    env = load_env()
    cookie = env.get("YTM_COOKIE") or None
    suite = Suite("Stream URL fetchability (reproduces in-app HTTP 403)")

    visitor = it.fetch_visitor_data()
    video_id, source = resolve_video_id(visitor, cookie)
    if not video_id:
        suite.skip("all stream fetches", source)
        return suite.report()
    print("  target videoId=%s  %s\n" % (video_id, source))

    # (client, use_cookie) pairs, in the order the app would consult them.
    plans = [(it.IOS, False), (it.ANDROID_VR, False)]
    if cookie:
        plans.insert(0, (it.WEB_REMIX, True))

    any_playable = False

    for client, use_cookie in plans:
        label = "%s%s" % (client.name, " (auth)" if use_cookie else " (anon)")
        with suite.test("stream fetch: %s" % label) as t:
            status, body = it.call(
                "player",
                {"videoId": video_id, "contentCheckOk": True, "racyCheckOk": True},
                client, cookie=(cookie if use_cookie else None), visitor_data=visitor)
            t.require(status == 200, "player HTTP %s" % status)

            playability = body.get("playabilityStatus") or {}
            if playability.get("status") != "OK":
                t.warn("playabilityStatus=%s %s" % (playability.get("status"),
                                                    playability.get("reason")))

            formats = it.audio_formats(body)
            streaming = body.get("streamingData") or {}
            hls = streaming.get("hlsManifestUrl")

            if hls:
                code, size, note = probe_stream(hls, client.ua)
                ok = code in (200, 206)
                t.note("HLS manifest        -> HTTP %-4s %s"
                       % (code, "%d bytes" % size if ok else note[:70]))
                if ok:
                    any_playable = True

            t.require(formats, "no audio formats offered")

            # Highest bitrate first, which is what a "high quality" preference wants.
            for fmt in sorted(formats, key=lambda f: -(f.get("bitrate") or 0)):
                url = fmt.get("url")
                itag = fmt.get("itag")
                bitrate = fmt.get("bitrate") or 0
                if not url:
                    t.warn("itag %-4s has no direct url (ciphered signatureCipher)"
                           % itag)
                    continue
                code, size, note = probe_stream(url, client.ua)
                ok = code in (200, 206)
                if ok:
                    any_playable = True
                t.note("itag %-4s %-7d bps -> HTTP %-4s %s"
                       % (itag, bitrate, code,
                          "%d bytes OK" % size if ok else note[:70]))

    with suite.test("at least one stream is actually downloadable") as t:
        t.require(any_playable,
                  "every stream URL was rejected - playback cannot succeed for "
                  "this video from this network/IP")

    return suite.report()


if __name__ == "__main__":
    sys.exit(run())
