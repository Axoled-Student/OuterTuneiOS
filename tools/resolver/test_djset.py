"""Unit tests for the DJ loop.

The model, the voice and YouTube Music are all stubbed. What is under test is
the loop itself: that a turn produces a themed set, that the next turn knows
what the last one played, that skipping actually changes what comes back, that
the set waiting in the background is used when it is still valid and thrown
away when it is not, and that no single failure takes the music down with it.

Run:  python tools/resolver/test_djset.py
"""
import os
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import discovery  # noqa: E402
import dj  # noqa: E402
import djset  # noqa: E402


class FakeTaste:
    """Artists they already play and songs they already own.

    `known` holds identities in the same shape the stubbed rec.identity below
    produces, because it is compared against resolved tracks, not against these
    rows.
    """
    def __init__(self):
        self.artists = {"mimi": 9, "yoasobi": 7, "radwimps": 4}
        self.tracks = [{"artist": "MIMI", "name": "ハナタバ"},
                       {"artist": "YOASOBI", "name": "アイドル"}]
        self.known = set()

    def refresh(self):
        pass


class FakeLearned:
    def __init__(self):
        self.rejected = set()

    def is_rejected(self, key):
        return key in self.rejected


class FakeEngine:
    cookie = None

    def __init__(self):
        self.taste = FakeTaste()
        self.learned = FakeLearned()

    def visitor(self):
        return "visitor"


def reply(theme, songs, say=True):
    """A planning reply. The script is a second call now, not part of this."""
    return ('{"theme": "%s", "say": %s, "songs": [%s]}'
            % (theme, "true" if say else "false",
               ", ".join('{"artist": "%s", "title": "%s"}' % s
                         for s in songs)))


def track(artist, title):
    return {"videoId": "id-" + title, "artist": artist, "title": title,
            "thumbnail": None}


class LoopTest(unittest.TestCase):
    def setUp(self):
        self.engine = FakeEngine()
        djset._sessions.clear()

        self._cfg = discovery._ai_config
        discovery._ai_config = lambda: {"endpoint": "x", "key": "y"}
        self.addCleanup(setattr, discovery, "_ai_config", self._cfg)

        self._ask = discovery._ask_model
        self.addCleanup(setattr, discovery, "_ask_model", self._ask)

        self._search = djset.rec.search_song
        self.addCleanup(setattr, djset.rec, "search_song", self._search)

        self._identity = djset.rec.identity
        djset.rec.identity = lambda t: (t.get("artist", "").lower() + "|"
                                        + t.get("title", "").lower())
        self.addCleanup(setattr, djset.rec, "identity", self._identity)

        self._radio = djset.rec.radio
        self.addCleanup(setattr, djset.rec, "radio", self._radio)

        self._voice = dj.voice_over
        self.addCleanup(setattr, dj, "voice_over", self._voice)

        self.prompts = []          # planning prompts only
        self.scripts = []          # the second call, once the set is real
        self.spoken = []
        self.replies = []
        self.script_replies = []
        self.missing = set()
        self.radio_pool = []
        self.radio_calls = []

        def ask(cfg, prompt, model=None, timeout=90, max_tokens=2000,
                temperature=0.7):
            # A turn is two calls now. Only the planning one is counted, so
            # the tests that count model calls per set still read straight.
            if "Reply with ONLY this JSON" not in prompt:
                self.scripts.append(prompt)
                if not self.script_replies:
                    return "Here we go."
                nxt = self.script_replies.pop(0)
                if isinstance(nxt, Exception):
                    raise nxt
                return nxt
            self.prompts.append(prompt)
            if not self.replies:
                return reply("filler %d" % len(self.prompts),
                             [("Artist%d" % len(self.prompts), "Song%d"
                               % len(self.prompts))])
            nxt = self.replies.pop(0)
            if isinstance(nxt, Exception):
                raise nxt
            return nxt
        discovery._ask_model = ask

        def radio(video_id, visitor, cookie=None, limit=60):
            self.radio_calls.append(video_id)
            return list(self.radio_pool)
        djset.rec.radio = radio

        # Same shape as the real one: "artist title" in, a track row out.
        def search(query, visitor, cookie=None):
            artist, _, title = query.partition(" ")
            if title in self.missing:
                return None
            return {"videoId": "id-" + title, "artist": artist,
                    "title": title, "thumbnail": None}
        djset.rec.search_song = search

        def voice_over(text, language=None, voice=None):
            self.spoken.append((text, language))
            return "aud" + str(len(self.spoken))
        dj.voice_over = voice_over

        djset._ready.clear()
        self.addCleanup(djset._ready.clear)
        djset._wanted.clear()
        self.addCleanup(djset._wanted.clear)

        # The ledger of what has gone out is deliberately persistent, so each
        # test gets its own file and its own empty memory of it.
        self._served_state = djset.SERVED_STATE
        djset.SERVED_STATE = os.path.join(tempfile.mkdtemp(), "served.json")
        self.addCleanup(setattr, djset, "SERVED_STATE", self._served_state)
        djset._served.clear()
        djset._served_loaded = False
        self.addCleanup(self.forget_served)
        self._langs = djset.LANGS_STATE
        djset.LANGS_STATE = os.path.join(tempfile.gettempdir(),
                                         "djset_langs_test.json")
        self.addCleanup(setattr, djset, "LANGS_STATE", self._langs)

        # Registered last so it runs first: a set still building in the
        # background would otherwise reach for stubs that have been put back,
        # and record itself against the next test's expectations.
        self.addCleanup(self.quiesce)
        discovery._lookup_cache.clear()
        self.addCleanup(discovery._lookup_cache.clear)

    def forget_served(self):
        djset._served.clear()
        djset._served_loaded = False

    def quiesce(self):
        for state in list(djset._sessions.values()):
            ahead = state.pop("ahead", None)
            if not ahead:
                continue
            ahead[0].cancel()
            try:
                ahead[0].result(timeout=10)
            except Exception:  # noqa: BLE001
                pass
        djset._sessions.clear()

    def turn(self, session=None, **kw):
        return djset.next_set(self.engine, session_id=session,
                              language=kw.pop("language", "zh-TW"), **kw)

    def drain(self, state_id):
        """Let the background set for a session finish, so tests are stable."""
        state = djset._sessions[state_id]
        ahead = state.get("ahead")
        if ahead:
            try:
                ahead[0].result(timeout=10)
            except Exception:  # noqa: BLE001
                pass

    # -- one turn

    def test_a_turn_returns_a_themed_set_with_its_script(self):
        self.replies = [reply("late night drive",
                              [("A", "One"), ("B", "Two"), ("C", "Three")])]
        out = self.turn()
        self.assertEqual(out["theme"], "late night drive")
        self.assertEqual(out["set"], 1)
        self.assertEqual([t["title"] for t in out["tracks"]],
                         ["One", "Two", "Three"])
        self.assertTrue(out["say"])
        self.assertEqual(out["audio"], "aud1")
        self.assertEqual(out["audioPath"], "/djvoice?id=aud1")
        self.assertTrue(out["session"])

    def test_the_script_is_spoken_in_the_listeners_language(self):
        self.replies = [reply("x", [("A", "One")])]
        self.turn(language="ja-JP")
        self.assertEqual(self.spoken[0][1], "ja")

    def test_an_unspoken_set_still_returns_songs(self):
        self.replies = [reply("quiet one", [("A", "One")], say=False)]
        out = self.turn()
        self.assertFalse(out["say"])
        self.assertIsNone(out["audio"])
        self.assertEqual(self.spoken, [])
        self.assertEqual(len(out["tracks"]), 1)

    def test_the_first_set_is_told_it_is_signing_on(self):
        self.replies = [reply("x", [("A", "One")])]
        self.turn()
        self.assertIn("first set of the session", self.prompts[0])

    # -- the loop remembers

    def test_the_next_turn_is_told_what_the_last_one_played(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("two", [("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        second = self.turn(session=first["session"])
        self.assertEqual(second["set"], 2)
        later = self.prompts[1]
        self.assertIn("A - One", later)
        self.assertIn("never choose any of these again", later)
        self.assertIn("Sets you have already played", later)
        self.assertIn("one", later)

    def test_a_song_already_played_is_dropped_from_a_later_set(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("two", [("A", "One"), ("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        second = self.turn(session=first["session"])
        self.assertEqual([t["title"] for t in second["tracks"]], ["Two"])

    def test_a_rejected_song_never_reaches_a_set(self):
        self.engine.learned.rejected.add("a|one")
        self.replies = [reply("one", [("A", "One"), ("B", "Two")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]], ["Two"])

    def test_songs_that_do_not_exist_are_simply_absent(self):
        self.missing.add("Two")
        self.replies = [reply("one", [("A", "One"), ("B", "Two"),
                                      ("C", "Three")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]], ["One", "Three"])

    # -- feedback steers it

    def test_a_skip_reaches_the_next_prompt(self):
        self.replies = [reply("one", [("A", "One")])]
        first = self.turn()
        self.drain(first["session"])
        self.replies = [reply("two", [("B", "Two")])]
        self.turn(session=first["session"], skipped=["A - One"])
        self.drain(first["session"])
        joined = self.prompts[-1]
        self.assertIn("SKIPPED", joined)
        self.assertIn("A - One", joined)

    def test_a_song_played_through_reaches_the_next_prompt(self):
        self.replies = [reply("one", [("A", "One")])]
        first = self.turn()
        self.drain(first["session"])
        self.replies = [reply("two", [("B", "Two")])]
        self.turn(session=first["session"], liked=["A - One"])
        self.drain(first["session"])
        self.assertIn("all the way through", self.prompts[-1])

    def test_two_skips_throw_away_the_set_built_before_them(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("PRECOMPUTED", [("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        # The background set is ready and says PRECOMPUTED. Two skips mean it
        # was planned for a listener who has since said otherwise.
        self.replies = [reply("rethought", [("C", "Three")])]
        second = self.turn(session=first["session"],
                           skipped=["A - One", "X - Nine"])
        self.assertEqual(second["theme"], "rethought")

    def test_one_skip_still_uses_the_set_already_waiting(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("PRECOMPUTED", [("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        before = len(self.prompts)
        second = self.turn(session=first["session"], skipped=["A - One"])
        self.assertEqual(second["theme"], "PRECOMPUTED")
        # One model call for the *following* set, not for this one.
        self.drain(first["session"])
        self.assertEqual(len(self.prompts), before + 1)

    def test_the_same_skip_twice_only_counts_once(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("PRECOMPUTED", [("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        self.turn(session=first["session"], skipped=["A - One"])
        self.drain(first["session"])
        # Re-sending the same two skips is not two fresh skips.
        out = self.turn(session=first["session"],
                        skipped=["A - One", "A - One"])
        self.assertTrue(out["tracks"])

    # -- the set waiting in the background

    def test_the_second_set_costs_no_model_call_of_its_own(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("two", [("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        before = len(self.prompts)
        second = self.turn(session=first["session"])
        self.assertEqual(second["theme"], "two")
        self.drain(first["session"])
        self.assertEqual(len(self.prompts), before + 1)

    def test_a_background_set_that_failed_is_rebuilt_rather_than_served(self):
        self.replies = [reply("one", [("A", "One")]),
                        RuntimeError("upstream fell over")]
        first = self.turn()
        self.drain(first["session"])
        self.replies = [reply("recovered", [("B", "Two")])]
        second = self.turn(session=first["session"])
        self.assertEqual(second["theme"], "recovered")

    def test_an_unknown_session_starts_a_new_one_rather_than_failing(self):
        self.replies = [reply("one", [("A", "One")])]
        out = self.turn(session="nosuchsession")
        self.assertEqual(out["set"], 1)
        self.assertTrue(out["tracks"])
        self.assertNotEqual(out["session"], "nosuchsession")

    # -- when things break

    def test_a_mute_voice_still_hands_back_the_set(self):
        def boom(text, language=None, voice=None):
            raise RuntimeError("no network")
        dj.voice_over = boom
        self.replies = [reply("one", [("A", "One")])]
        out = self.turn()
        self.assertTrue(out["tracks"])
        self.assertEqual(out["script"], "Here we go.")
        self.assertIsNone(out["audio"])
        self.assertIn("could not speak", out["error"])

    def test_a_model_that_fails_is_a_clean_error(self):
        self.replies = [RuntimeError("502 upstream")]
        out = self.turn()
        self.assertEqual(out["tracks"], [])
        self.assertIn("could not plan", out["error"])

    def test_junk_instead_of_json_is_a_clean_error(self):
        self.replies = ["I'm sorry, I can't help with that."]
        out = self.turn()
        self.assertEqual(out["tracks"], [])
        self.assertIn("could not plan", out["error"])

    def test_json_wrapped_in_a_fence_is_still_read(self):
        self.replies = ["```json\n" + reply("fenced", [("A", "One")]) + "\n```"]
        out = self.turn()
        self.assertEqual(out["theme"], "fenced")

    def test_a_set_whose_songs_all_vanish_is_an_error_not_an_empty_set(self):
        self.missing.add("One")
        self.replies = [reply("one", [("A", "One")])]
        out = self.turn()
        self.assertEqual(out["tracks"], [])
        self.assertIn("none of the songs", out["error"])

    def test_no_ai_key_is_a_clean_error(self):
        discovery._ai_config = lambda: None
        out = self.turn()
        self.assertEqual(out["tracks"], [])
        self.assertIn("ai.env", out["error"])

    def test_a_failed_turn_does_not_advance_the_set_number(self):
        self.replies = [RuntimeError("nope"), reply("worked", [("A", "One")])]
        first = self.turn()
        self.assertEqual(first["set"], 0)
        second = self.turn(session=first["session"])
        self.assertEqual(second["set"], 1)

    # -- housekeeping

    def test_sessions_expire(self):
        self.replies = [reply("one", [("A", "One")])]
        out = self.turn()
        self.drain(out["session"])
        djset._sessions[out["session"]]["touched"] -= djset.SESSION_TTL + 10
        self.replies = [reply("fresh", [("B", "Two")])]
        again = self.turn(session=out["session"])
        self.assertNotEqual(again["session"], out["session"])

    def test_two_listeners_do_not_share_a_session(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("two", [("B", "Two")])]
        a = self.turn()
        b = self.turn()
        self.assertNotEqual(a["session"], b["session"])

    def test_concurrent_turns_on_one_session_do_not_duplicate_songs(self):
        self.replies = [reply("one", [("A", "One")])]
        first = self.turn()
        self.drain(first["session"])

        seen = []
        barrier = threading.Barrier(2)

        def race():
            barrier.wait(5)
            seen.append(self.turn(session=first["session"]))

        threads = [threading.Thread(target=race) for _ in range(2)]
        for t in threads:
            t.start()
        for t in threads:
            t.join(20)

        titles = [t["title"] for out in seen for t in out["tracks"]]
        self.assertEqual(len(titles), len(set(titles)))

    # -- the set is real before the DJ talks about it

    def test_the_line_is_written_about_the_songs_that_survived(self):
        self.missing.add("Two")
        self.replies = [reply("one", [("A", "One"), ("B", "Two"),
                                      ("C", "Three")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]],
                         ["One", "Three"])
        # The song that turned out not to exist must not reach the words
        # being spoken over the set.
        prompt = self.scripts[0]
        self.assertIn("A - One", prompt)
        self.assertIn("C - Three", prompt)
        self.assertNotIn("Two", prompt)

    def test_the_planning_call_does_not_ask_for_a_script(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn()
        self.assertNotIn("script", self.prompts[0])
        self.assertEqual(len(self.scripts), 1)

    def test_the_spoken_line_is_the_one_the_model_wrote(self):
        fence = chr(96) * 3
        self.script_replies = [fence + '\n"Let us begin."\n' + fence]
        self.replies = [reply("one", [("A", "One")])]
        out = self.turn()
        self.assertEqual(out["script"], "Let us begin.")
        self.assertEqual(self.spoken[0][0], "Let us begin.")

    def test_a_script_the_model_will_not_write_still_leaves_a_set(self):
        self.script_replies = [RuntimeError("upstream fell over")]
        self.replies = [reply("one", [("A", "One")])]
        out = self.turn()
        self.assertTrue(out["tracks"])
        self.assertFalse(out["say"])
        self.assertEqual(out["script"], "")
        self.assertIsNone(out["audio"])
        self.assertIn("could not write", out["error"])

    def test_an_unspoken_set_costs_no_second_call(self):
        self.replies = [reply("quiet", [("A", "One")], say=False)]
        self.turn()
        self.assertEqual(self.scripts, [])

    # -- keeping the set full

    def test_a_short_set_is_topped_up_from_the_radio_of_what_survived(self):
        self.missing.update({"Two", "Three", "Four"})
        self.radio_pool = [track("D", "N1"), track("E", "N2"),
                           track("F", "N3"), track("G", "N4")]
        self.replies = [reply("one", [("A", "One"), ("B", "Two"),
                                      ("C", "Three"), ("Z", "Four")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]],
                         ["One", "N1", "N2", "N3"])
        self.assertEqual(self.radio_calls, ["id-One"])

    def test_the_top_up_skips_songs_this_session_already_played(self):
        self.replies = [reply("one", [("A", "One")]),
                        reply("two", [("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])
        second = self.turn(session=first["session"])
        self.assertEqual([t["title"] for t in second["tracks"]], ["Two"])
        # Now offer the radio a song this session has already played.
        self.radio_pool = [track("A", "One"), track("N", "N1")]
        self.drain(first["session"])
        third = self.turn(session=first["session"])
        self.assertNotIn("One", [t["title"] for t in third["tracks"]])

    def test_a_full_set_is_never_topped_up(self):
        self.replies = [reply("one", [("A", "One"), ("B", "Two"),
                                      ("C", "Three"), ("D", "Four"),
                                      ("E", "Five")])]
        out = self.turn()
        self.assertEqual(len(out["tracks"]), djset.SET_SIZE)
        self.assertEqual(self.radio_calls, [])

    def test_a_spare_that_was_not_needed_is_still_playable_later(self):
        self.replies = [reply("one", [("A", "One"), ("B", "Two"),
                                      ("C", "Three"), ("D", "Four"),
                                      ("E", "Five")]),
                        reply("two", [("E", "Five")])]
        first = self.turn()
        self.drain(first["session"])
        second = self.turn(session=first["session"])
        self.assertEqual([t["title"] for t in second["tracks"]], ["Five"])

    def test_two_songs_by_one_artist_only_get_one_slot(self):
        self.replies = [reply("one", [("A", "One"), ("A", "Two"),
                                      ("B", "Three")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]],
                         ["One", "Three"])

    # -- the opening set standing by

    def test_a_standing_opening_set_is_served_without_a_model_call(self):
        lang = dj.normalise_language("zh-TW")
        self.replies = [reply("prewarmed", [("A", "One")])]
        self.assertTrue(djset._prewarm(self.engine, lang))
        before = len(self.prompts)
        out = self.turn()
        self.assertEqual(out["theme"], "prewarmed")
        self.assertEqual(out["set"], 1)
        self.drain(out["session"])
        # One call, and it is for the set after this one.
        self.assertEqual(len(self.prompts), before + 1)

    def test_a_standing_set_is_not_given_to_a_session_already_running(self):
        self.replies = [reply("one", [("A", "One")])]
        first = self.turn()
        self.drain(first["session"])
        self.replies = [reply("prewarmed", [("Z", "Nine")])]
        self.assertTrue(djset._prewarm(self.engine,
                                       dj.normalise_language("zh-TW")))
        second = self.turn(session=first["session"])
        self.assertNotEqual(second["theme"], "prewarmed")

    def test_a_stale_standing_set_is_ignored(self):
        lang = dj.normalise_language("zh-TW")
        self.replies = [reply("prewarmed", [("A", "One")])]
        self.assertTrue(djset._prewarm(self.engine, lang))
        djset._ready[lang]["at"] -= djset.READY_TTL + 10
        self.replies = [reply("fresh", [("B", "Two")])]
        out = self.turn()
        self.assertEqual(out["theme"], "fresh")

    def test_a_standing_set_brings_its_no_repeat_memory_with_it(self):
        lang = dj.normalise_language("zh-TW")
        self.replies = [reply("prewarmed", [("A", "One")]),
                        reply("second", [("A", "One"), ("B", "Two")])]
        self.assertTrue(djset._prewarm(self.engine, lang))
        first = self.turn()
        self.drain(first["session"])
        second = self.turn(session=first["session"])
        self.assertEqual(second["set"], 2)
        self.assertEqual([t["title"] for t in second["tracks"]], ["Two"])

    def test_a_prewarm_that_fails_leaves_nothing_standing(self):
        self.replies = [RuntimeError("upstream fell over")]
        self.assertFalse(djset._prewarm(self.engine,
                                        dj.normalise_language("zh-TW")))
        self.assertEqual(djset._ready, {})

    def test_the_language_asked_for_is_remembered_for_warming(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn(language="ja-JP")
        self.assertIn(dj.normalise_language("ja-JP"), djset._wanted)

    def test_the_model_is_asked_for_more_songs_than_the_set_needs(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn()
        self.assertIn("list %d real" % djset.ASK_SIZE, self.prompts[0])

    # ------------------------------------------------- out of the comfort zone

    def test_a_song_the_listener_already_owns_is_never_served(self):
        self.engine.taste.known = {"mimi|hanataba"}
        self.replies = [reply("one", [("MIMI", "Hanataba"), ("A", "One"),
                                      ("B", "Two"), ("C", "Three"),
                                      ("D", "Four")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]],
                         ["One", "Two", "Three", "Four"])

    def test_only_one_song_comes_from_an_artist_they_already_play(self):
        # Three of the five proposals are artists in the taste profile. One
        # gets a slot; the rest of the set goes to names they have not played.
        self.replies = [reply("one", [("MIMI", "One"), ("YOASOBI", "Two"),
                                      ("RADWIMPS", "Three"), ("A", "Four"),
                                      ("B", "Five"), ("C", "Six")])]
        out = self.turn()
        titles = [t["title"] for t in out["tracks"]]
        self.assertEqual(titles, ["One", "Four", "Five", "Six"])

    def test_the_familiar_cap_gives_way_rather_than_hand_over_a_short_set(self):
        # Nothing but artists they already play. A set of one is worse than a
        # set that leans familiar, so the second pass takes them.
        self.replies = [reply("one", [("MIMI", "One"), ("YOASOBI", "Two"),
                                      ("RADWIMPS", "Three")])]
        out = self.turn()
        self.assertEqual([t["title"] for t in out["tracks"]],
                         ["One", "Two", "Three"])

    def test_the_top_up_prefers_a_stranger_to_a_familiar_name(self):
        self.missing.update({"Two", "Three", "Four"})
        self.radio_pool = [track("YOASOBI", "Near"), track("D", "N1"),
                           track("E", "N2")]
        self.replies = [reply("one", [("A", "One"), ("B", "Two"),
                                      ("C", "Three"), ("Z", "Four")])]
        out = self.turn()
        titles = [t["title"] for t in out["tracks"]]
        self.assertEqual(titles[:3], ["One", "N1", "N2"])
        # Only once the strangers run out does the familiar one get a slot.
        self.assertEqual(titles[3], "Near")

    def test_the_model_is_told_not_to_replay_what_they_already_own(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn()
        prompt = self.prompts[0]
        self.assertIn("Songs they already have on repeat", prompt)
        self.assertIn("at most ONE of", prompt)
        self.assertNotIn("Songs they love", prompt)

    # ------------------------------------------------------- across stations

    def test_a_song_played_by_one_station_is_not_replayed_by_the_next(self):
        self.replies = [reply("one", [("A", "One"), ("B", "Two")])]
        first = self.turn()
        self.drain(first["session"])

        self.replies = [reply("two", [("A", "One"), ("B", "Two"),
                                      ("C", "Three"), ("D", "Four"),
                                      ("E", "Five")])]
        second = self.turn()
        self.assertEqual([t["title"] for t in second["tracks"]],
                         ["Three", "Four", "Five"])

    def test_the_ledger_outlives_the_process(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn()

        # Same file, fresh memory - what a restart looks like.
        djset._served.clear()
        djset._served_loaded = False
        self.assertIn("a|one", djset._served_keys())

    def test_a_set_built_but_never_taken_is_not_marked_as_played(self):
        self.replies = [reply("standby", [("A", "One"), ("B", "Two")])]
        djset._prewarm(self.engine, dj.normalise_language("zh-TW"))
        self.assertEqual(djset._served_keys(), set())

    def test_the_ledger_forgets_after_a_few_days(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn()
        for row in djset._served.values():
            row["at"] -= djset.SERVED_TTL + 60
        self.assertEqual(djset._served_keys(), set())

    def test_the_model_is_shown_what_the_station_played_before(self):
        self.replies = [reply("one", [("A", "One")])]
        self.turn()
        self.replies = [reply("two", [("B", "Two")])]
        self.turn()
        self.assertIn("already played these for them in the last few days",
                      self.prompts[-1])
        self.assertIn("A - One", self.prompts[-1])


if __name__ == "__main__":
    unittest.main(verbosity=2)
