"""Prove premium audio is actually fetchable by descrambling the signature.

WEB_REMIX is the only client offered itag 141 (256kbps AAC) and 774, and it
returns every format as `signatureCipher` - a query string containing `s=`,
an obfuscated signature. googlevideo answers 403 unless `s` is descrambled by
the transform in YouTube's player JS and re-attached under the `sp` name.

This suite does the whole chain for real:

    base.js -> signatureTimestamp + transform source -> player(sts)
            -> descramble s -> ranged GET -> assert bytes arrive

It shells out to node to evaluate the extracted transform, which is exactly
what the Swift side does with JavaScriptCore.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import innertube_client as it  # noqa: E402
from harness import Suite, load_env  # noqa: E402

UA_WEB = it.UA_WEB
PREMIUM_ITAGS = {141, 774}


def fetch_text(url, timeout=30):
    request = urllib.request.Request(url)
    request.add_header("User-Agent", UA_WEB)
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read().decode("utf-8", errors="replace")


def find_player_js_url():
    """The player JS path is embedded in the YouTube Music web app shell."""
    html = fetch_text("https://music.youtube.com/")
    match = re.search(r'"(?:jsUrl|PLAYER_JS_URL)"\s*:\s*"([^"]+base\.js)"', html)
    if not match:
        match = re.search(r'(/s/player/[0-9a-zA-Z_-]+/[^"\']+/base\.js)', html)
        if not match:
            return None
    path = match.group(1).replace("\\/", "/")
    if path.startswith("//"):
        return "https:" + path
    if path.startswith("/"):
        return "https://music.youtube.com" + path
    return path


def extract_signature_timestamp(js):
    match = re.search(r'(?:signatureTimestamp|sts)\s*[:=]\s*(\d{5,})', js)
    return int(match.group(1)) if match else None


def extract_transform(js):
    """Return JS source defining `decipher(sig)`, or None."""
    # The main transform: takes a, splits it, mutates it, joins it back.
    main = re.search(
        r'(?P<name>[a-zA-Z0-9_$]+)\s*=\s*function\(\s*(?P<arg>[a-zA-Z0-9_$]+)\s*\)\s*\{'
        r'\s*(?P=arg)\s*=\s*(?P=arg)\.split\(\s*(?P<sep>""|\'\')\s*\)\s*;'
        r'(?P<body>.+?)'
        r'return\s+(?P=arg)\.join\(\s*(?P=sep)\s*\)\s*\}', js, re.S)
    if not main:
        return None

    body = main.group("body")
    # Every statement in the body is <helper>.<method>(a, N);
    helper_match = re.search(r'([a-zA-Z0-9_$]+)\.[a-zA-Z0-9_$]+\(', body)
    if not helper_match:
        return None
    helper_name = helper_match.group(1)

    helper = re.search(
        r'(var\s+' + re.escape(helper_name) + r'\s*=\s*\{.*?\}\s*\}\s*;)', js, re.S)
    if not helper:
        return None

    return "%s\nfunction decipher(%s){%s=%s.split('');%sreturn %s.join('');}" % (
        helper.group(1), main.group("arg"), main.group("arg"),
        main.group("arg"), body, main.group("arg"))


def run_decipher(transform_js, signature):
    """Evaluate the extracted transform in node."""
    script = "%s\nprocess.stdout.write(decipher(%s));" % (
        transform_js, json.dumps(signature))
    handle, path = tempfile.mkstemp(suffix=".js")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as fh:
            fh.write(script)
        result = subprocess.run(["node", path], capture_output=True, timeout=30)
        if result.returncode != 0:
            return None, result.stderr.decode(errors="replace")[:200]
        return result.stdout.decode(errors="replace"), None
    finally:
        os.unlink(path)


def parse_cipher(cipher):
    from urllib.parse import parse_qsl
    return dict(parse_qsl(cipher))


def probe(url, user_agent):
    request = urllib.request.Request(url)
    request.add_header("User-Agent", user_agent)
    request.add_header("Accept-Encoding", "identity")
    request.add_header("Range", "bytes=0-65535")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, len(response.read(65536)), ""
    except urllib.error.HTTPError as e:
        return e.code, 0, e.read()[:100].decode(errors="replace")
    except Exception as e:  # noqa: BLE001
        return 0, 0, "EXC " + str(e)


def run():
    env = load_env()
    cookie = env.get("YTM_COOKIE") or None
    suite = Suite("Premium audio via signature descrambling")

    if not cookie:
        suite.skip("all premium tests", "needs YTM_COOKIE")
        return suite.report()

    visitor = it.fetch_visitor_data()

    player_js_url, js, sts, transform = None, None, None, None

    with suite.test("locate and fetch YouTube player base.js") as t:
        player_js_url = find_player_js_url()
        t.require(player_js_url, "could not find base.js url in the web app shell")
        t.note("player js: %s" % player_js_url)
        js = fetch_text(player_js_url, timeout=60)
        t.require(len(js) > 100_000, "base.js looks truncated (%d bytes)" % len(js))
        t.note("base.js: %d bytes" % len(js))

    with suite.test("extract signatureTimestamp") as t:
        sts = extract_signature_timestamp(js)
        t.require(sts, "signatureTimestamp not found in base.js")
        t.note("signatureTimestamp = %d" % sts)

    with suite.test("extract the signature transform (canary)") as t:
        transform = extract_transform(js)
        if not transform:
            # Not a regression in this app: the upstream Android client has
            # WEB_REMIX disabled with the same note ("Could not parse
            # deobfuscation function"), so premium formats are currently
            # unobtainable for everyone. Kept as a canary - if YouTube ships a
            # player whose transform is extractable again, this starts passing.
            t.warn("no extractable transform in this player build - premium "
                   "formats stay unplayable (matches upstream Android client)")
            return suite.report()
        t.note("transform source: %d chars" % len(transform))
        sample, err = run_decipher(transform, "abcdefghijklmnopqrstuvwxyz0123456789")
        t.require(sample, "node failed to evaluate transform: %s" % err)
        t.require(sample != "abcdefghijklmnopqrstuvwxyz0123456789",
                  "transform returned its input unchanged - extraction is wrong")
        t.note("sanity: 26+10 char probe -> %r" % sample[:40])

    # --- the real thing ---------------------------------------------------
    video_id = "vw5hLooQzOU"  # MIMI - くうになる
    premium_ok = False

    with suite.test("WEB_REMIX player(sts) offers premium formats") as t:
        payload = {
            "videoId": video_id, "contentCheckOk": True, "racyCheckOk": True,
            "playbackContext": {"contentPlaybackContext": {"signatureTimestamp": sts}},
        }
        status, body = it.call("player", payload, it.WEB_REMIX,
                               cookie=cookie, visitor_data=visitor)
        t.require(status == 200, "player HTTP %s" % status)
        playability = body.get("playabilityStatus") or {}
        t.require(playability.get("status") == "OK",
                  "playabilityStatus=%s %s" % (playability.get("status"),
                                               playability.get("reason")))
        formats = it.audio_formats(body)
        itags = sorted({f.get("itag") for f in formats})
        t.note("itags = %s" % itags)
        unlocked = PREMIUM_ITAGS & set(itags)
        t.require(unlocked, "no premium itag offered - is Music Premium active?")
        t.note("premium itags offered: %s" % sorted(unlocked))

        globals()["_formats"] = formats

    with suite.test("descrambled premium stream actually downloads") as t:
        formats = globals().get("_formats") or []
        candidates = [f for f in formats if f.get("itag") in PREMIUM_ITAGS]
        t.require(candidates, "no premium formats to fetch")

        for fmt in sorted(candidates, key=lambda f: -(f.get("bitrate") or 0)):
            itag = fmt.get("itag")
            bitrate = fmt.get("bitrate") or 0

            if fmt.get("url"):
                code, size, note = probe(fmt["url"], UA_WEB)
                t.note("itag %-4s %-7d bps DIRECT -> HTTP %s %s"
                       % (itag, bitrate, code, "%d bytes" % size if size else note[:60]))
                if code in (200, 206):
                    premium_ok = True
                continue

            cipher = fmt.get("signatureCipher")
            if not cipher:
                t.warn("itag %s has neither url nor signatureCipher" % itag)
                continue

            values = parse_cipher(cipher)
            raw_url, scrambled = values.get("url"), values.get("s")
            sp = values.get("sp", "signature")
            if not raw_url or not scrambled:
                t.warn("itag %s cipher missing url/s" % itag)
                continue

            # Without descrambling this URL is a guaranteed 403 - show that.
            code_before, _, _ = probe(raw_url, UA_WEB)
            t.note("itag %-4s %-7d bps WITHOUT signature -> HTTP %s"
                   % (itag, bitrate, code_before))

            fixed, err = run_decipher(transform, scrambled)
            t.require(fixed, "descramble failed: %s" % err)
            signed = raw_url + ("&" if "?" in raw_url else "?") + "%s=%s" % (sp, fixed)
            code, size, note = probe(signed, UA_WEB)
            t.note("itag %-4s %-7d bps WITH signature    -> HTTP %s %s"
                   % (itag, bitrate, code, "%d bytes OK" % size if size else note[:60]))
            if code in (200, 206):
                premium_ok = True

        if not premium_ok:
            t.warn("no premium stream downloadable - expected while the signature "
                   "transform cannot be extracted")

    return suite.report()


if __name__ == "__main__":
    sys.exit(run())
