"""Unit tests for the progressive AI radio station.

The model and YouTube Music are both stubbed. What is being tested is the part
this module actually decides: that the opening handful comes back without
waiting for the long wave, that the long wave lands behind it, that the two
waves together still respect one cap per artist, and that a half-failure still
produces a playable station.

Run:  python tools/resolver/test_airadio.py
"""
import os
import sys
import threading
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import discovery  # noqa: E402


class FakeTaste:
    def __init__(self):
        self.artists = {"MIMI": 9, "TAK": 4}
        self.tracks = [{"artist": "MIMI", "name": "Hanataba", "weight": 3}]
        self.refreshed = 0

    def refresh(self):
        self.refreshed += 1


class FakeLearned:
    def __init__(self, rejected=()):
        self.rejected = set(rejected)

    def is_rejected(self, key):
        return key in self.rejected


class FakeEngine:
    cookie = None

    def __init__(self, rejected=()):
        self.taste = FakeTaste()
        self.learned = FakeLearned(rejected)

    def visitor(self):
        return "visitor"


def song(artist, title):
    return {"videoId": "%s-%s" % (artist, title), "title": title,
            "artist": artist, "thumbnail": None}


class StationTest(unittest.TestCase):
    def setUp(self):
        discovery._stations.clear()

        self._cfg = discovery._ai_config
        discovery._ai_config = lambda: {"endpoint": "x", "key": "y"}
        self.addCleanup(setattr, discovery, "_ai_config", self._cfg)

        self._ask = discovery._ask_model
        self.addCleanup(setattr, discovery, "_ask_model", self._ask)

        self._search = discovery.rec.search_song
        self.addCleanup(setattr, discovery.rec, "search_song", self._search)
        # `_parse_list` hands over "<artist> <title>", so that is what the
        # stub is given back.
        discovery.rec.search_song = staticmethod(
            lambda query, visitor, cookie=None:
            song(*query.split(" ", 1)) if " " in query else None).__func__

        self._theme = discovery.auto_theme
        self.addCleanup(setattr, discovery, "auto_theme", self._theme)
        discovery.auto_theme = lambda engine, cfg, model=None: "a made-up mood"

        # A test that wants a slow long wave holds it here rather than
        # sleeping, so it cannot still be running - and still holding a pool
        # worker, and still calling stubs that are about to be taken away -
        # once the test that asked for it has finished.
        self._release = threading.Event()
        self.addCleanup(self._settle)

    def _settle(self):
        """Release any held long wave and wait for it to actually stop."""
        self._release.set()
        deadline = time.time() + 10
        while time.time() < deadline:
            if not any(state.get("pending")
                       for state in list(discovery._stations.values())):
                return
            time.sleep(0.02)
        self.fail("a long wave was still running at teardown")

    @staticmethod
    def is_opening(prompt):
        """The opening ask is the one for exactly SPRINT songs."""
        return "%d real" % discovery.SPRINT in prompt

    def stub_model(self, sprint, tail, hold_tail=False):
        """Answer the short ask with `sprint` and the long one with `tail`."""
        def fake(cfg, prompt, model=None, timeout=90, max_tokens=2000,
                 temperature=0.7):
            if self.is_opening(prompt):
                names = sprint
            else:
                names = tail
                if hold_tail:
                    self._release.wait(10)
            return "[%s]" % ", ".join(
                '{"artist": "%s", "title": "%s"}' % (a, t) for a, t in names)
        discovery._ask_model = fake

    def drain(self, station, timeout=10):
        """Wait for the long wave, the way a client polls."""
        deadline = time.time() + timeout
        while time.time() < deadline:
            view = discovery.ai_radio(FakeEngine(), "", station=station)
            if not view["pending"]:
                return view
            time.sleep(0.05)
        self.fail("station never finished")

    # -- opening

    def test_opening_returns_without_the_long_wave(self):
        self.stub_model([("A", "1"), ("B", "2")], [("C", "3")], hold_tail=True)

        began = time.time()
        view = discovery.ai_radio(FakeEngine(), "morning pop", limit=20)
        self.assertLess(time.time() - began, 3,
                        "the opening waited for the slow wave")
        self.assertEqual(len(view["tracks"]), 2)
        self.assertTrue(view["pending"])
        self.assertTrue(view["station"])

    def test_the_long_wave_lands_behind_it(self):
        self.stub_model([("A", "1")], [("C", "3"), ("D", "4")])
        view = discovery.ai_radio(FakeEngine(), "morning pop", limit=20)
        done = self.drain(view["station"])
        self.assertEqual([t["artist"] for t in done["tracks"]],
                         ["A", "C", "D"])
        self.assertFalse(done["pending"])

    def test_after_returns_only_what_is_new(self):
        self.stub_model([("A", "1")], [("C", "3"), ("D", "4")])
        view = discovery.ai_radio(FakeEngine(), "morning pop", limit=20)
        self.drain(view["station"])
        more = discovery.ai_radio(FakeEngine(), "", station=view["station"],
                                  after=1)
        self.assertEqual([t["artist"] for t in more["tracks"]], ["C", "D"])
        self.assertEqual(more["total"], 3)

    # -- what the two waves together must not do

    def test_one_artist_cannot_fill_the_station(self):
        # Each wave is told "at most two"; only the station can hold the line
        # across both of them.
        self.stub_model([("MIMI", "1"), ("MIMI", "2")],
                        [("MIMI", "3"), ("MIMI", "4"), ("Other", "5")])
        view = discovery.ai_radio(FakeEngine(), "j-pop", limit=20)
        done = self.drain(view["station"])
        artists = [t["artist"] for t in done["tracks"]]
        self.assertEqual(artists.count("MIMI"), discovery.PER_ARTIST)
        self.assertIn("Other", artists)

    def test_the_same_song_is_not_added_twice(self):
        self.stub_model([("A", "1")], [("A", "1"), ("B", "2")])
        view = discovery.ai_radio(FakeEngine(), "pop", limit=20)
        done = self.drain(view["station"])
        self.assertEqual(len(done["tracks"]), 2)

    def test_skipped_songs_stay_out(self):
        engine = FakeEngine(rejected={discovery.rec.identity(song("A", "1"))})
        self.stub_model([("A", "1"), ("B", "2")], [])
        view = discovery.ai_radio(engine, "pop", limit=20)
        self.assertEqual([t["artist"] for t in view["tracks"]], ["B"])

    def test_an_auto_station_skips_what_is_already_on_repeat(self):
        # FakeTaste plays "MIMI - Hanataba" a lot, and the model offers it
        # anyway; only the station can keep it out.
        self.stub_model([("MIMI", "Hanataba"), ("B", "2")], [])
        view = discovery.ai_radio(FakeEngine(), "", limit=20)
        self.assertEqual([t["artist"] for t in view["tracks"]], ["B"])

    def test_a_named_station_still_plays_favourites(self):
        # Asking for MIMI by name must not be filtered by the same rule.
        self.stub_model([("MIMI", "Hanataba")], [])
        view = discovery.ai_radio(FakeEngine(), "mimi songs", limit=20)
        self.assertEqual([t["title"] for t in view["tracks"]], ["Hanataba"])

    def test_limit_is_respected(self):
        # limit=4 so the long wave asks for eight songs; at limit=3 it would
        # ask for six and the stub could not tell the two waves apart.
        self.stub_model([("A", "1"), ("B", "2")],
                        [("C", "3"), ("D", "4"), ("E", "5")])
        view = discovery.ai_radio(FakeEngine(), "pop", limit=4)
        done = self.drain(view["station"])
        self.assertEqual(len(done["tracks"]), 4)

    # -- degraded paths

    def test_a_failed_opening_still_gives_a_station(self):
        calls = []

        def fake(cfg, prompt, model=None, timeout=90, max_tokens=2000,
                 temperature=0.7):
            calls.append(prompt)
            if self.is_opening(prompt):
                raise RuntimeError("boom")
            return '[{"artist": "C", "title": "3"}]'
        discovery._ask_model = fake

        view = discovery.ai_radio(FakeEngine(), "pop", limit=20)
        self.assertEqual([t["artist"] for t in view["tracks"]], ["C"])
        self.assertIn("quick pass failed", view["error"] or "")

    def test_unresolvable_proposals_are_dropped_not_queued(self):
        discovery.rec.search_song = lambda query, visitor, cookie=None: None
        self.stub_model([("A", "1")], [("C", "3")])
        view = discovery.ai_radio(FakeEngine(), "pop", limit=20)
        done = self.drain(view["station"])
        self.assertEqual(done["tracks"], [])

    def test_unknown_station_is_a_clean_answer(self):
        view = discovery.ai_radio(FakeEngine(), "", station="nope")
        self.assertEqual(view["tracks"], [])
        self.assertFalse(view["pending"])
        self.assertEqual(view["error"], "unknown station")

    def test_auto_mode_is_named_by_the_slow_wave(self):
        self.stub_model([("A", "1")], [("C", "3")])
        view = discovery.ai_radio(FakeEngine(), "", limit=20)
        self.assertTrue(view["auto"])
        done = self.drain(view["station"])
        self.assertEqual(done["prompt"], "a made-up mood")

    def test_expired_stations_are_forgotten(self):
        self.stub_model([("A", "1")], [])
        view = discovery.ai_radio(FakeEngine(), "pop", limit=20)
        self.drain(view["station"])
        discovery._stations[view["station"]]["created"] -= (
            discovery.STATION_TTL + 1)
        again = discovery.ai_radio(FakeEngine(), "", station=view["station"])
        self.assertEqual(again["error"], "unknown station")


if __name__ == "__main__":
    unittest.main(verbosity=2)
