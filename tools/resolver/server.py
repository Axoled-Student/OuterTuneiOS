"""Local YouTube Music stream resolver for the iOS app.

Why this exists
---------------
googlevideo refuses an open-ended `Range: bytes=0-` outright, and caps
un-descrambled transfers at exactly 1 MiB - measured, reproducibly. Lifting that
cap needs YouTube's `n` parameter descrambled, which means executing YouTube's
player JS. yt-dlp does that through an external JS runtime (Deno); an iOS app
cannot.

It also cannot be offloaded to a cheap VPS: stream URLs are bound to the IP that
resolved them (verified - a URL resolved on a home connection returns 403 from a
datacenter), and YouTube bot-gates datacenter ranges anyway.

So this runs on the same residential connection as the browser the cookies came
from. It resolves with yt-dlp and proxies the bytes, forwarding Range headers so
AVPlayer can stream and seek instead of downloading whole files up front.

Usage
-----
    python tools/resolver/server.py --token <shared-secret> [--port 8787]
    python tools/resolver/server.py --token ... --cookies path/to/cookies.txt

Expose it with:  cloudflared tunnel --url http://127.0.0.1:8787
"""
import argparse
import http.server
import json
import os
import socketserver
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    import yt_dlp
except ImportError:
    sys.exit("yt-dlp is required:  python -m pip install --upgrade yt-dlp")

# Stream URLs stay valid ~6h; re-resolving is slow, so cache well inside that.
CACHE_TTL_SECONDS = 60 * 60 * 3
CHUNK = 256 * 1024

_cache = {}
_cache_lock = threading.Lock()


class Resolver:
    def __init__(self, cookies_path=None, client_args=None):
        self.cookies_path = cookies_path
        self.client_args = client_args

    def _options(self):
        options = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "noplaylist": True,
            # Audio only. `bestaudio` picks the highest-bitrate audio-only
            # stream, which is itag 251 (opus ~132k) or 140 (m4a ~130k).
            "format": "bestaudio[ext=m4a]/bestaudio",
        }
        if self.cookies_path:
            options["cookiefile"] = self.cookies_path
        if self.client_args:
            options["extractor_args"] = {
                "youtube": {"player_client": self.client_args}
            }
        return options

    def resolve(self, video_id):
        """Return {url, mime, ext, itag, bitrate, filesize, title, artist}."""
        key = video_id
        now = time.time()
        with _cache_lock:
            hit = _cache.get(key)
            if hit and hit["expires_at"] > now:
                return hit["data"]

        url = "https://music.youtube.com/watch?v=%s" % video_id
        with yt_dlp.YoutubeDL(self._options()) as ydl:
            info = ydl.extract_info(url, download=False)

        # With a `format` selector set, extract_info annotates the chosen one.
        chosen = info.get("requested_formats") or []
        fmt = chosen[0] if chosen else info

        data = {
            "videoId": video_id,
            "title": info.get("title"),
            "artist": info.get("artist") or info.get("uploader"),
            "duration": info.get("duration"),
            "url": fmt.get("url"),
            "itag": str(fmt.get("format_id") or ""),
            "ext": fmt.get("ext"),
            "mime": ("audio/mp4" if fmt.get("ext") == "m4a" else
                     "audio/webm" if fmt.get("ext") == "webm" else
                     "application/octet-stream"),
            "bitrate": int((fmt.get("abr") or fmt.get("tbr") or 0) * 1000),
            "filesize": fmt.get("filesize") or fmt.get("filesize_approx"),
            "httpHeaders": fmt.get("http_headers") or {},
        }
        if not data["url"]:
            raise RuntimeError("yt-dlp returned no stream url")

        with _cache_lock:
            _cache[key] = {"data": data, "expires_at": now + CACHE_TTL_SECONDS}
        return data


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "OuterTuneResolver/1.0"
    resolver = None
    token = None

    def _authorised(self, params):
        if not self.token:
            return True
        supplied = (params.get("token", [None])[0]
                    or self.headers.get("X-Auth-Token"))
        return supplied == self.token

    def _send_json(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        route = parsed.path.rstrip("/")

        if route == "/health":
            return self._send_json(200, {"ok": True, "service": "outertune-resolver"})

        if not self._authorised(params):
            return self._send_json(401, {"error": "bad or missing token"})

        video_id = (params.get("v") or params.get("videoId") or [None])[0]
        if route == "/resolve":
            if not video_id:
                return self._send_json(400, {"error": "missing v"})
            try:
                data = dict(self.resolver.resolve(video_id))
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            # Never hand the raw googlevideo url to the phone: it is bound to
            # this machine's IP and would 403 there.
            data.pop("url", None)
            data.pop("httpHeaders", None)
            data["streamPath"] = "/stream?v=%s" % video_id
            return self._send_json(200, data)

        if route == "/stream":
            if not video_id:
                return self._send_json(400, {"error": "missing v"})
            return self._proxy_stream(video_id)

        return self._send_json(404, {"error": "not found"})

    def do_HEAD(self):  # noqa: N802
        parsed = urllib.parse.urlparse(self.path)
        params = urllib.parse.parse_qs(parsed.query)
        if parsed.path.rstrip("/") != "/stream" or not self._authorised(params):
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        video_id = (params.get("v") or [None])[0]
        try:
            data = self.resolver.resolve(video_id)
        except Exception:  # noqa: BLE001
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", data["mime"])
        if data.get("filesize"):
            self.send_header("Content-Length", str(data["filesize"]))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

    def _proxy_stream(self, video_id):
        """Fetch from googlevideo and relay, honouring the client's Range."""
        try:
            data = self.resolver.resolve(video_id)
        except Exception as e:  # noqa: BLE001
            return self._send_json(502, {"error": str(e)[:300]})

        upstream = urllib.request.Request(data["url"])
        for key, value in (data.get("httpHeaders") or {}).items():
            upstream.add_header(key, value)
        upstream.add_header("Accept-Encoding", "identity")

        client_range = self.headers.get("Range")
        # An open-ended range is exactly what googlevideo rejects, so give it a
        # bounded one and let the client see a normal 206.
        if client_range and client_range.startswith("bytes="):
            spec = client_range.split("=", 1)[1].split(",")[0].strip()
            start, _, end = spec.partition("-")
            start = int(start) if start else 0
            if end:
                upstream.add_header("Range", "bytes=%d-%d" % (start, int(end)))
            else:
                total = data.get("filesize")
                if total:
                    upstream.add_header("Range", "bytes=%d-%d" % (start, int(total) - 1))
                else:
                    upstream.add_header("Range", "bytes=%d-" % start)
        else:
            total = data.get("filesize")
            if total:
                upstream.add_header("Range", "bytes=0-%d" % (int(total) - 1))

        try:
            response = urllib.request.urlopen(upstream, timeout=60)
        except urllib.error.HTTPError as e:
            # A stale cached url is the usual cause; drop it and resolve again.
            with _cache_lock:
                _cache.pop(video_id, None)
            return self._send_json(502, {"error": "upstream HTTP %d" % e.code})
        except Exception as e:  # noqa: BLE001
            return self._send_json(502, {"error": str(e)[:200]})

        status = 206 if response.status == 206 else 200
        self.send_response(status)
        self.send_header("Content-Type", data["mime"])
        self.send_header("Accept-Ranges", "bytes")
        for header in ("Content-Length", "Content-Range"):
            value = response.headers.get(header)
            if value:
                self.send_header(header, value)
        self.end_headers()

        try:
            while True:
                block = response.read(CHUNK)
                if not block:
                    break
                self.wfile.write(block)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the phone seeked or stopped; entirely normal
        finally:
            response.close()

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--token", default=os.environ.get("RESOLVER_TOKEN"),
                        help="shared secret the app must present")
    parser.add_argument("--cookies", default=None,
                        help="Netscape cookie file for a signed-in session")
    parser.add_argument("--player-client", default=None,
                        help="override yt-dlp's youtube player_client")
    args = parser.parse_args()

    if not args.token:
        print("WARNING: no --token set; anyone who reaches this port can use it.",
              file=sys.stderr)

    Handler.resolver = Resolver(cookies_path=args.cookies,
                                client_args=args.player_client)
    Handler.token = args.token

    server = ThreadedServer((args.host, args.port), Handler)
    print("resolver listening on http://%s:%d" % (args.host, args.port))
    print("  cookies: %s" % (args.cookies or "(none - anonymous)"))
    print("  token  : %s" % ("set" if args.token else "NOT SET"))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nshutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
