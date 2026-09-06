"""Deterministic protocol tests for the companion stream resolver."""

import http.client
import http.server
import json
import os
import pathlib
import shutil
import tempfile
import threading
import time
import unittest

import server as resolver_server


class QuietHandler(resolver_server.Handler):
    def log_message(self, _fmt, *_args):
        pass


class StubResolver:
    def __init__(self, upstream_url="http://127.0.0.1:1/audio"):
        self.upstream_url = upstream_url
        self.invalidations = 0
        self.prepared = []
        self.ready = set()
        handle = tempfile.NamedTemporaryFile(delete=False, suffix=".m4a")
        handle.write(b"abcdefgh")
        handle.close()
        self.prepared_path = handle.name

    def resolve(self, video_id):
        return {
            "videoId": video_id,
            "title": "Test",
            "artist": "OuterTune",
            "duration": 3,
            "url": self.upstream_url,
            "itag": "141",
            "ext": "m4a",
            "mime": "audio/mp4",
            "bitrate": 258000,
            "filesize": 8,
            "httpHeaders": {"User-Agent": "resolver-test"},
        }

    def invalidate(self, _video_id):
        self.invalidations += 1

    def is_prepared(self, video_id):
        return video_id in self.ready

    def prepare(self, video_id):
        self.prepared.append(video_id)
        payload = self.resolve(video_id)
        payload.update({
            "preparedPath": self.prepared_path,
            "progressive": True,
            "filesize": 8,
        })
        return payload


class ResolverHarness(unittest.TestCase):
    """Starts a resolver on a free port and talks to it over real HTTP."""

    def start_resolver(self, resolver, token=None):
        handler = type("ConfiguredQuietHandler", (QuietHandler,), {})
        handler.resolver = resolver
        handler.token = token
        server = resolver_server.ThreadedServer(("127.0.0.1", 0), handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        if getattr(resolver, "prepared_path", None):
            self.addCleanup(lambda: os.path.exists(resolver.prepared_path)
                            and os.unlink(resolver.prepared_path))
        return server.server_address[1]

    def request(self, port, path, headers=None, method="GET"):
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        body = response.read()
        result = response.status, dict(response.getheaders()), body
        connection.close()
        return result


class ResolverServerTest(ResolverHarness):
    def test_url_only_health_accepts_stale_client_token(self):
        port = self.start_resolver(StubResolver(), token=None)
        status, _, body = self.request(port, "/health?token=old-phone-token")
        self.assertEqual(status, 200)
        self.assertFalse(json.loads(body)["authRequired"])

    def test_health_checks_token_when_operator_enables_one(self):
        port = self.start_resolver(StubResolver(), token="correct")
        wrong, _, _ = self.request(port, "/health?token=wrong")
        right, _, body = self.request(port, "/health?token=correct")
        self.assertEqual(wrong, 401)
        self.assertEqual(right, 200)
        self.assertTrue(json.loads(body)["authRequired"])

    def test_resolve_hides_googlevideo_url_and_reports_premium_metadata(self):
        port = self.start_resolver(StubResolver())
        status, _, body = self.request(port, "/resolve?v=video123")
        payload = json.loads(body)
        self.assertEqual(status, 200)
        self.assertEqual(payload["itag"], "141")
        self.assertEqual(payload["bitrate"], 258000)
        self.assertEqual(payload["streamPath"], "/stream?v=video123")
        self.assertTrue(payload["progressive"])
        self.assertNotIn("url", payload)
        self.assertNotIn("httpHeaders", payload)

    def test_prepare_hides_server_path(self):
        stub = StubResolver()
        port = self.start_resolver(stub)
        status, _, body = self.request(port, "/prepare?v=video123")
        payload = json.loads(body)

        self.assertEqual(status, 200)
        self.assertTrue(payload["prepared"])
        self.assertEqual(payload["filesize"], 8)
        self.assertNotIn("preparedPath", payload)

    def test_stream_serves_seekable_ranges_from_prepared_m4a(self):
        stub = StubResolver()
        port = self.start_resolver(stub)
        status, headers, body = self.request(
            port, "/stream?v=video123", headers={"Range": "bytes=2-5"}
        )

        self.assertEqual(status, 206)
        self.assertEqual(body, b"cdef")
        self.assertEqual(headers["Content-Range"], "bytes 2-5/8")

    def test_stream_supports_head_and_suffix_ranges_used_by_avplayer(self):
        port = self.start_resolver(StubResolver())
        head_status, head_headers, head_body = self.request(
            port, "/stream?v=video123", method="HEAD"
        )
        suffix_status, suffix_headers, suffix_body = self.request(
            port, "/stream?v=video123", headers={"Range": "bytes=-3"}
        )

        self.assertEqual(head_status, 200)
        self.assertEqual(head_headers["Content-Length"], "8")
        self.assertEqual(head_headers["Accept-Ranges"], "bytes")
        self.assertEqual(head_body, b"")
        self.assertEqual(suffix_status, 206)
        self.assertEqual(suffix_headers["Content-Range"], "bytes 5-7/8")
        self.assertEqual(suffix_body, b"fgh")

    def test_stream_rejects_out_of_bounds_range(self):
        port = self.start_resolver(StubResolver())
        status, headers, body = self.request(
            port, "/stream?v=video123", headers={"Range": "bytes=99-"}
        )
        self.assertEqual(status, 416)
        self.assertEqual(headers["Content-Range"], "bytes */8")
        self.assertEqual(body, b"")


class WarmRouteTest(ResolverHarness):
    def test_warm_queues_a_batch_without_waiting_for_it(self):
        """The phone should pay one small request, not a download."""
        stub = StubResolver()
        stub.ready.add("already")
        port = self.start_resolver(stub)

        started = time.time()
        status, _, body = self.request(port, "/warm?v=one,two,already,one")
        elapsed = time.time() - started
        payload = json.loads(body)

        self.assertEqual(status, 200)
        self.assertLess(elapsed, 2.0)
        self.assertEqual(payload["ready"], ["already"])
        # Deduplicated, and the one already on disk is not fetched again.
        self.assertEqual(payload["queued"], ["one", "two"])

        deadline = time.time() + 5
        while time.time() < deadline and len(stub.prepared) < 2:
            time.sleep(0.05)
        self.assertEqual(sorted(stub.prepared), ["one", "two"])

    def test_warm_without_ids_is_a_client_error(self):
        port = self.start_resolver(StubResolver())
        status, _, _ = self.request(port, "/warm")
        self.assertEqual(status, 400)


class LyricsRouteTest(ResolverHarness):
    """Route wiring only - the module itself is covered by test_lyrics.py."""

    def setUp(self):
        import lyrics
        self.calls = []
        self._get = lyrics.get
        self.addCleanup(setattr, lyrics, "get", self._get)
        lyrics.get = self.fake_get

    def fake_get(self, title, artist, duration=None, target=None, **kwargs):
        self.calls.append((title, artist, duration, target))
        return {"ok": True, "synced": True, "translating": False,
                "lines": [{"t": 1.0, "text": "hi", "tr": "嗨"}]}

    def test_passes_the_query_through_and_returns_lines(self):
        port = self.start_resolver(StubResolver())
        status, _, body = self.request(
            port, "/lyrics?title=Hello&artist=Someone&duration=201"
                  "&target=zh-Hant-TW")
        payload = json.loads(body)

        self.assertEqual(status, 200)
        self.assertEqual(self.calls, [("Hello", "Someone", 201.0, "zh-Hant-TW")])
        self.assertEqual(payload["lines"][0]["tr"], "嗨")

    def test_translation_can_be_turned_off(self):
        port = self.start_resolver(StubResolver())
        self.request(port, "/lyrics?title=Hello&target=zh-Hant&translate=0")
        self.assertEqual(self.calls[0][3], None)

    def test_title_is_required(self):
        port = self.start_resolver(StubResolver())
        status, _, _ = self.request(port, "/lyrics?artist=Someone")
        self.assertEqual(status, 400)
        self.assertEqual(self.calls, [])


class PreparedCacheTest(unittest.TestCase):
    def test_prune_evicts_least_recently_served_files_over_budget(self):
        directory = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)

        resolver = resolver_server.Resolver(cache_dir=directory)
        now = time.time()
        for index in range(4):
            path = directory / ("track%d.m4a" % index)
            path.write_bytes(b"x" * 1024)
            # Oldest first, so track0 is the one that should go.
            os.utime(path, (now - (10 - index) * 60,) * 2)

        original = resolver_server.PREPARED_BUDGET
        resolver_server.PREPARED_BUDGET = 3 * 1024
        self.addCleanup(setattr, resolver_server, "PREPARED_BUDGET", original)

        resolver.prune_prepared()

        remaining = sorted(p.name for p in directory.glob("*.m4a"))
        # Down to three quarters of the budget: two files, the newest two.
        self.assertEqual(remaining, ["track2.m4a", "track3.m4a"])

    def test_prune_leaves_a_cache_inside_its_budget_alone(self):
        directory = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, directory, True)

        resolver = resolver_server.Resolver(cache_dir=directory)
        (directory / "keep.m4a").write_bytes(b"x" * 1024)
        resolver.prune_prepared()

        self.assertTrue((directory / "keep.m4a").exists())


if __name__ == "__main__":
    unittest.main()
