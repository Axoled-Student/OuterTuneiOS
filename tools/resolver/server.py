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
from. It resolves with yt-dlp, verifies the complete source, losslessly remuxes
it into fast-start M4A, then serves normal byte ranges that AVPlayer can seek.

Usage
-----
    python tools/resolver/server.py [--port 8787]
    python tools/resolver/server.py --cookies path/to/cookies.txt

Authentication is optional. Pass ``--token <shared-secret>`` only when wanted.

Expose it with:  cloudflared tunnel --url http://127.0.0.1:8787
"""
import argparse
import hashlib
import http.server
import json
import os
import pathlib
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import concurrent.futures
import urllib.error
import urllib.parse
import urllib.request
import uuid

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

try:
    import yt_dlp
except ImportError:
    sys.exit("yt-dlp is required:  python -m pip install --upgrade yt-dlp")

# Stream URLs stay valid ~6h; re-resolving is slow, so cache well inside that.
CACHE_TTL_SECONDS = 60 * 60 * 3
CHUNK = 256 * 1024
# Prepared M4As are the whole point of the cache, but they are also 3-10MB
# each and nothing was ever deleting them. Cap the directory and evict the
# least recently served file once it is exceeded.
PREPARED_BUDGET = 12 << 30

_cache = {}
_cache_lock = threading.Lock()
_prepare_locks = {}

# Warming runs off the request thread: the phone should pay one small round
# trip, not wait for a download it is not going to play yet.
_warm_pool = concurrent.futures.ThreadPoolExecutor(max_workers=3,
                                                   thread_name_prefix="warm")
_warming = set()
_warm_lock = threading.Lock()


def warm_async(resolver, video_ids):
    """Prepare these ids in the background, skipping any already in flight."""
    queued = []
    for video_id in video_ids:
        with _warm_lock:
            if video_id in _warming:
                continue
            _warming.add(video_id)
        queued.append(video_id)

        def job(target=video_id):
            try:
                resolver.prepare(target)
            except Exception:  # noqa: BLE001
                pass  # best effort; /stream prepares on demand if this failed
            finally:
                with _warm_lock:
                    _warming.discard(target)

        _warm_pool.submit(job)
    return queued


class Resolver:
    def __init__(self, cookies_path=None, client_args=None, cache_dir=None):
        self.cookies_path = cookies_path
        self.client_args = client_args
        default_cache = pathlib.Path(__file__).resolve().parents[2] / "build" / "resolver_cache"
        self.cache_dir = pathlib.Path(cache_dir or default_cache)
        self.cache_dir.mkdir(parents=True, exist_ok=True)

    def _options(self, use_cookies=True):
        options = {
            "quiet": True,
            "no_warnings": True,
            "skip_download": True,
            "noplaylist": True,
            # Prefer the highest-bitrate AAC/M4A audio-only stream: Premium
            # sessions expose itag 141 (~258 kbps), with itag 140 (~129 kbps)
            # as the normal fallback. AAC also keeps the iOS remux path simple.
            "format": "bestaudio[ext=m4a]/bestaudio",
        }
        if self.cookies_path and use_cookies:
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

        info, fmt = self._extract(video_id)

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

    def _extract(self, video_id):
        """Resolve a stream as cheaply as the content allows.

        Measured on this machine over six tracks, every one of which returned
        the identical itag 140 at 129kbps:

            music.youtube.com + cookies   4.85s   (what this used to do)
            www.youtube.com   + cookies   1.95s
            www.youtube.com   anonymous   0.88s

        The music front end costs ~3s per lookup and buys nothing, and the
        signed-in session costs another ~1s. Cookies still matter for anything
        age- or region-gated, so they stay - as the fallback, not the default.
        """
        url = "https://www.youtube.com/watch?v=%s" % video_id
        attempts = [False, True] if self.cookies_path else [False]
        failure = None

        for use_cookies in attempts:
            try:
                with yt_dlp.YoutubeDL(self._options(use_cookies)) as ydl:
                    info = ydl.extract_info(url, download=False)
            except Exception as error:  # noqa: BLE001
                failure = error
                continue
            # With a `format` selector set, extract_info annotates the chosen one.
            chosen = info.get("requested_formats") or []
            fmt = chosen[0] if chosen else info
            if fmt.get("url"):
                return info, fmt
            failure = failure or RuntimeError("no stream url")

        raise RuntimeError("could not resolve %s: %s" % (video_id, failure))

    def is_prepared(self, video_id):
        """True when /stream can answer this id from disk with no network."""
        with _cache_lock:
            hit = _cache.get(video_id)
        if not hit or hit["expires_at"] <= time.time():
            return False
        path = self._prepared_path(video_id, hit["data"].get("itag"))
        try:
            return path.stat().st_size > 1024
        except OSError:
            return False

    def prune_prepared(self):
        """Evict least-recently-served files once the directory is over budget."""
        entries, total = [], 0
        for path in self.cache_dir.glob("*.m4a"):
            try:
                stat = path.stat()
            except OSError:
                continue
            entries.append((stat.st_mtime, stat.st_size, path))
            total += stat.st_size

        if total <= PREPARED_BUDGET:
            return
        for _, size, path in sorted(entries):
            try:
                path.unlink()
            except OSError:
                continue
            total -= size
            if total <= PREPARED_BUDGET * 3 // 4:
                break

    def invalidate(self, video_id):
        """Forget a resolved URL so the next request obtains a fresh one."""
        with _cache_lock:
            _cache.pop(video_id, None)

    def _prepared_path(self, video_id, itag):
        readable = "".join(c if c.isalnum() or c in "-_" else "_" for c in video_id)[:48]
        digest = hashlib.sha256((video_id + ":" + str(itag)).encode()).hexdigest()[:12]
        return self.cache_dir / ("%s-%s-%s.m4a" % (readable, itag or "audio", digest))

    def _preparation_lock(self, path):
        key = str(path)
        with _cache_lock:
            return _prepare_locks.setdefault(key, threading.Lock())

    def _download_source(self, video_id, destination):
        """Download one complete DASH source, refreshing a stale URL once."""
        for attempt in range(2):
            data = self.resolve(video_id)
            request = urllib.request.Request(data["url"])
            for key, value in (data.get("httpHeaders") or {}).items():
                request.add_header(key, value)
            request.add_header("Accept-Encoding", "identity")
            if data.get("filesize"):
                request.add_header("Range", "bytes=0-%d" % (int(data["filesize"]) - 1))

            try:
                with urllib.request.urlopen(request, timeout=90) as response:
                    with open(destination, "wb") as output:
                        while True:
                            block = response.read(CHUNK)
                            if not block:
                                break
                            output.write(block)
                actual_size = destination.stat().st_size
                if actual_size == 0:
                    raise RuntimeError("upstream returned an empty audio file")
                expected_size = int(data.get("filesize") or 0)
                if expected_size and actual_size != expected_size:
                    destination.unlink(missing_ok=True)
                    if attempt == 0:
                        self.invalidate(video_id)
                        continue
                    raise RuntimeError(
                        "incomplete upstream audio (%d/%d bytes)"
                        % (actual_size, expected_size)
                    )
                return data
            except urllib.error.HTTPError as error:
                if attempt == 0 and error.code in (403, 410):
                    self.invalidate(video_id)
                    continue
                raise RuntimeError("upstream HTTP %d" % error.code) from error

        raise RuntimeError("upstream audio URL remained unavailable")

    def prepare(self, video_id):
        """Cache a fast-start M4A so iOS can begin with small Range requests."""
        metadata = self.resolve(video_id)
        output_path = self._prepared_path(video_id, metadata.get("itag"))

        with self._preparation_lock(output_path):
            if not output_path.exists() or output_path.stat().st_size < 1024:
                ffmpeg = shutil.which("ffmpeg")
                if not ffmpeg:
                    raise RuntimeError("ffmpeg is required for progressive M4A playback")

                unique = uuid.uuid4().hex
                source_path = output_path.with_name(output_path.name + "." + unique + ".dash.part")
                temp_output = output_path.with_name(output_path.name + "." + unique + ".m4a.part")
                try:
                    metadata = self._download_source(video_id, source_path)
                    command = [
                        ffmpeg,
                        "-hide_banner",
                        "-loglevel", "error",
                        "-nostdin",
                        "-y",
                        "-i", str(source_path),
                        "-map", "0:a:0",
                        "-vn",
                        "-c:a", "copy",
                        "-movflags", "+faststart",
                        "-f", "mp4",
                        str(temp_output),
                    ]
                    completed = subprocess.run(
                        command,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.PIPE,
                        text=True,
                        timeout=120,
                        check=False,
                    )
                    if completed.returncode != 0:
                        detail = (completed.stderr or "ffmpeg failed").strip()[-500:]
                        raise RuntimeError("failed to prepare M4A: %s" % detail)
                    if not temp_output.exists() or temp_output.stat().st_size < 1024:
                        raise RuntimeError("ffmpeg produced no playable M4A")
                    os.replace(temp_output, output_path)
                finally:
                    source_path.unlink(missing_ok=True)
                    temp_output.unlink(missing_ok=True)

        self.prune_prepared()

        prepared = dict(metadata)
        prepared["preparedPath"] = str(output_path)
        prepared["filesize"] = output_path.stat().st_size
        prepared["mime"] = "audio/mp4"
        prepared["ext"] = "m4a"
        prepared["progressive"] = True
        return prepared


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "OuterTuneResolver/1.1"
    resolver = None
    queue_engine = None
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

        if not self._authorised(params):
            return self._send_json(401, {"error": "bad or missing token"})

        if route == "/health":
            return self._send_json(200, {
                "ok": True,
                "service": "outertune-resolver",
                "authRequired": bool(self.token),
                "progressiveM4A": True,
                "preload": True,
            })

        video_id = (params.get("v") or params.get("videoId") or [None])[0]
        if route == "/feedback":
            engine = self.__class__.queue_engine
            artist = (params.get("artist") or [""])[0]
            title = (params.get("title") or [""])[0]
            if not video_id and not title:
                return self._send_json(400, {"error": "missing v or title"})
            try:
                played = float((params.get("played") or ["0"])[0])
                duration = float((params.get("duration") or ["0"])[0])
            except ValueError:
                played, duration = 0.0, 0.0
            explicit = (params.get("explicit") or [None])[0]
            import recommender
            track_key = recommender.identity({"artist": artist, "title": title})
            artist_key = recommender.primary_artist(artist)
            outcome = engine.learned.record(track_key, artist_key, played,
                                            duration, explicit,
                                            title=title, artist=artist)
            return self._send_json(200, {"ok": True, "outcome": outcome})

        if route == "/feedback/summary":
            return self._send_json(200,
                                   self.__class__.queue_engine.learned.summary())

        if route == "/home":
            try:
                per = max(4, min(int((params.get("per") or ["12"])[0]), 24))
            except ValueError:
                per = 12
            try:
                import discovery
                # `refresh=1` (pull-to-refresh) forces a fresh rotation.
                force = (params.get("refresh") or ["0"])[0] not in ("0", "", "false")
                rotate = int(time.time()) if force else None
                payload = discovery.home(self.__class__.queue_engine, per=per,
                                         force=force, rotate=rotate)
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            return self._send_json(200, payload)

        if route == "/airadio":
            # An empty prompt is valid: the server picks the theme itself, so
            # the client can offer a single "just play something" button.
            prompt = (params.get("prompt") or params.get("q") or [""])[0]
            try:
                limit = max(1, min(int((params.get("limit") or ["20"])[0]), 40))
            except ValueError:
                limit = 20
            # A station id turns this into "what else have you found?", which
            # is how the client keeps playing while the rest is still coming.
            station = (params.get("station") or [""])[0].strip() or None
            try:
                after = max(0, int((params.get("after") or ["0"])[0]))
            except ValueError:
                after = 0
            try:
                import discovery
                payload = discovery.ai_radio(self.__class__.queue_engine,
                                             prompt.strip(), limit=limit,
                                             station=station, after=after)
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            return self._send_json(200, payload)

        if route == "/queue":
            if not video_id:
                return self._send_json(400, {"error": "missing v"})
            try:
                limit = max(1, min(int(params.get("limit", ["20"])[0]), 50))
            except ValueError:
                limit = 20
            session_key = (params.get("session") or ["default"])[0]
            seed_hint = None
            title = (params.get("title") or [None])[0]
            artist = (params.get("artist") or [None])[0]
            if title or artist:
                seed_hint = {"videoId": video_id, "title": title or "",
                             "artist": artist or ""}
            try:
                engine = self.__class__.queue_engine
                payload = engine.queue(video_id, limit=limit,
                                       session_key=session_key,
                                       seed_hint=seed_hint)
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            return self._send_json(200, payload)

        if route == "/queue/reset":
            session_key = (params.get("session") or ["default"])[0]
            self.__class__.queue_engine.reset(session_key)
            return self._send_json(200, {"ok": True, "session": session_key})

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
            data["progressive"] = True
            data["streamPath"] = "/stream?v=%s" % video_id
            return self._send_json(200, data)

        if route == "/prepare":
            if not video_id:
                return self._send_json(400, {"error": "missing v"})
            try:
                data = dict(self.resolver.prepare(video_id))
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:500]})
            data.pop("url", None)
            data.pop("httpHeaders", None)
            data.pop("preparedPath", None)
            data["prepared"] = True
            data["streamPath"] = "/stream?v=%s" % video_id
            return self._send_json(200, data)

        if route == "/warm":
            raw = params.get("v") or params.get("videoId") or []
            ids = []
            for group in raw:
                for candidate in group.split(","):
                    candidate = candidate.strip()
                    if candidate and candidate not in ids:
                        ids.append(candidate)
            ids = ids[:8]
            if not ids:
                return self._send_json(400, {"error": "missing v"})
            ready = [i for i in ids if self.resolver.is_prepared(i)]
            queued = warm_async(self.resolver,
                                [i for i in ids if i not in ready])
            return self._send_json(200, {"ok": True, "ready": ready,
                                         "queued": queued})

        if route == "/lyrics":
            title = (params.get("title") or [""])[0].strip()
            artist = (params.get("artist") or [""])[0].strip()
            if not title:
                return self._send_json(400, {"error": "missing title"})
            try:
                seconds = float((params.get("duration") or ["0"])[0])
            except ValueError:
                seconds = 0.0
            target = (params.get("target") or [""])[0].strip() or None
            if (params.get("translate") or ["1"])[0] in ("0", "false", ""):
                target = None
            try:
                import lyrics
                payload = lyrics.get(title, artist, duration=seconds or None,
                                     target=target)
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            return self._send_json(200, payload)

        if route == "/djset":
            # One turn of the DJ loop: a theme, the songs for it, and the
            # sentence introducing them. The client sends back what was
            # skipped and what was played through, which is what steers the
            # next turn.
            try:
                import djset
                payload = djset.next_set(
                    self.__class__.queue_engine,
                    session_id=(params.get("session") or [""])[0].strip(),
                    language=(params.get("lang") or [""])[0],
                    skipped=[v for v in params.get("skipped", []) if v.strip()],
                    liked=[v for v in params.get("liked", []) if v.strip()],
                    model=(params.get("model") or [""])[0].strip() or None)
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            status = 200 if payload.get("tracks") else 502
            return self._send_json(status, payload)

        if route == "/djline":
            # The voice between songs. The client asks for the handover into
            # the *next* track while the current one is still playing, so the
            # few seconds this takes are never waited on.
            upcoming = {"artist": (params.get("artist") or [""])[0].strip(),
                        "title": (params.get("title") or [""])[0].strip()}
            prev = {"artist": (params.get("prevArtist") or [""])[0].strip(),
                    "title": (params.get("prevTitle") or [""])[0].strip()}
            if not (upcoming["title"] or upcoming["artist"]):
                return self._send_json(400, {"error": "missing title"})
            first = (params.get("first") or ["0"])[0] not in ("0", "", "false")
            voice = (params.get("voice") or [""])[0].strip() or None
            try:
                import dj
                payload = dj.line((params.get("theme") or [""])[0].strip(),
                                  prev, upcoming,
                                  language=(params.get("lang") or [""])[0],
                                  first=first, voice=voice)
            except Exception as e:  # noqa: BLE001
                return self._send_json(502, {"error": str(e)[:300]})
            if payload.get("audio"):
                payload["audioPath"] = "/djvoice?id=%s" % payload["audio"]
            return self._send_json(200, payload)

        if route == "/djvoice":
            import dj
            audio = dj.audio_bytes((params.get("id") or [""])[0].strip())
            if audio is None:
                return self._send_json(404, {"error": "no such line"})
            self.send_response(200)
            self.send_header("Content-Type", "audio/mpeg")
            self.send_header("Content-Length", str(len(audio)))
            # A handover is keyed by the two songs either side of it, so the
            # bytes behind one id never change.
            self.send_header("Cache-Control", "public, max-age=604800")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            self.wfile.write(audio)
            return

        if route == "/stream":
            if not video_id:
                return self._send_json(400, {"error": "missing v"})
            return self._serve_prepared(video_id)

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
            data = self.resolver.prepare(video_id)
        except Exception:  # noqa: BLE001
            self.send_response(502)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self._serve_file(data, send_body=False)

    def _serve_prepared(self, video_id):
        try:
            data = self.resolver.prepare(video_id)
        except Exception as e:  # noqa: BLE001
            return self._send_json(502, {"error": str(e)[:500]})
        return self._serve_file(data, send_body=True)

    def _serve_file(self, data, send_body):
        path = pathlib.Path(data["preparedPath"])
        size = path.stat().st_size
        # Keep the pruner's idea of "recently used" honest: a track played
        # often should outlive one prepared once and never returned to.
        try:
            os.utime(path, None)
        except OSError:
            pass
        range_header = self.headers.get("Range")
        start = 0
        end = size - 1

        if range_header:
            try:
                if not range_header.startswith("bytes=") or "," in range_header:
                    raise ValueError("unsupported range")
                spec = range_header.split("=", 1)[1].strip()
                start_text, separator, end_text = spec.partition("-")
                if not separator:
                    raise ValueError("missing separator")
                if start_text:
                    start = int(start_text)
                    end = int(end_text) if end_text else size - 1
                else:
                    suffix = int(end_text)
                    if suffix <= 0:
                        raise ValueError("bad suffix")
                    start = max(size - suffix, 0)
                    end = size - 1
                if start < 0 or start >= size or end < start:
                    raise ValueError("out of bounds")
                end = min(end, size - 1)
            except (TypeError, ValueError):
                self.send_response(416)
                self.send_header("Content-Range", "bytes */%d" % size)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return

        length = end - start + 1
        self.send_response(206 if range_header else 200)
        self.send_header("Content-Type", "audio/mp4")
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        self.send_header("Cache-Control", "private, max-age=3600")
        if range_header:
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
        self.end_headers()

        if not send_body:
            return

        try:
            with open(path, "rb") as source:
                source.seek(start)
                remaining = length
                while remaining > 0:
                    block = source.read(min(CHUNK, remaining))
                    if not block:
                        break
                    self.wfile.write(block)
                    remaining -= len(block)
        except (BrokenPipeError, ConnectionResetError):
            pass  # the phone seeked or stopped; entirely normal

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))


class ThreadedServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    # Bound to every interface so a phone on the same network or through a
    # tunnel can reach it; loopback-only made the tunnel the sole route in.
    parser.add_argument("--host", default="0.0.0.0")
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

    # Queue generation lives here rather than in the app so the algorithm can be
    # changed without rebuilding and reinstalling the iOS client.
    import recommender
    cookie_header = None
    if args.cookies and os.path.exists(args.cookies):
        pairs = []
        with open(args.cookies, encoding="utf-8") as fh:
            for line in fh:
                if line.startswith("#") or not line.strip():
                    continue
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 7:
                    pairs.append("%s=%s" % (parts[5], parts[6]))
        cookie_header = "; ".join(pairs) if pairs else None
    Handler.queue_engine = recommender.QueueEngine(cookie=cookie_header)

    # Build the home page up front; a cold build is tens of seconds of network
    # round-trips and nobody should be made to wait for it interactively.
    try:
        import discovery
        discovery.start_auto_refresh(Handler.queue_engine)
        print("  home shelves rebuild automatically every %d min"
              % (discovery.HOME_TTL // 60))
    except Exception as e:  # noqa: BLE001
        print("  home warmup skipped: %s" % e)

    # And the same for the DJ: an opening set costs half a minute to build, so
    # one stands by rather than being built while somebody waits for it.
    try:
        import djset
        djset.start_auto_warm(Handler.queue_engine)
        print("  dj keeps an opening set ready per language in use")
    except Exception as e:  # noqa: BLE001
        print("  dj warmup skipped: %s" % e)
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
