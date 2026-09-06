"""Unit tests for the normal queue - the one you get by tapping a song.

Nothing here touches the network. What is under test is `select`, which turns a
pool of candidates into the twenty tracks that actually play, and the two
classifiers it leans on: which writing system a track is in, and whether it is
a real release or somebody's upload of one.

These cover the four ways a real queue went wrong: Russian rap behind a
Mandarin seed, half a Mandarin queue arriving in latin script, the same two
profile favourites opening every queue whatever was tapped, and lyric-video
rips served as if they were the song.

Run:  python tools/resolver/test_recommender.py
"""
import os
import shutil
import sys
import tempfile
import time
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import recommender as rec  # noqa: E402


class FakeTaste:
    def __init__(self, artists=None, known=None):
        self.artists = artists or {}
        self.known = known or set()


def track(artist, title, source="radio", rank=0):
    return {"videoId": "id-%s-%s" % (artist, title), "artist": artist,
            "title": title, "source": source, "rank": rank}


def pick(pool, taste, limit=10, seed_script=None, **kw):
    return rec.select(pool, taste, limit, set(), set(), {},
                      seed_script=seed_script, **kw)


class ScriptTest(unittest.TestCase):
    def test_cyrillic_is_not_latin(self):
        self.assertEqual(rec.script_of(u"Трудно найти"), "cyrl")
        self.assertEqual(
            rec.script_of(u"iphone kupi (bare minimum) / Базовый минимум"),
            "cyrl")

    def test_a_russian_song_under_a_chinese_artist_name_is_still_russian(self):
        # The bucket is built from title and artist together, and this one got
        # into a Mandarin queue on the strength of its uploader's name.
        self.assertEqual(rec.track_script({"title": u"Я Одна (Radio Edit)",
                                           "artist": u"滄凌"}), "cyrl")

    def test_one_stylised_letter_does_not_make_a_song_russian(self):
        self.assertEqual(rec.track_script({"title": u"Яの歌", "artist": "Vocaloid P"}),
                         "jp")

    def test_a_mandarin_seed_does_not_accept_russian(self):
        self.assertFalse(rec.language_compatible("han", "cyrl"))

    def test_an_english_seed_does_not_accept_russian(self):
        self.assertFalse(rec.language_compatible("latin", "cyrl"))

    def test_the_scripts_that_were_already_right_still_are(self):
        self.assertEqual(rec.script_of(u"太陽與地球"), "han")
        self.assertEqual(rec.script_of(u"月に吠える"), "jp")
        self.assertEqual(rec.script_of(u"꽃 길"), "kr")
        self.assertEqual(rec.script_of("Perfect"), "latin")
        self.assertTrue(rec.language_compatible("jp", "han"))
        self.assertTrue(rec.language_compatible("han", "latin"))


class ReuploadTest(unittest.TestCase):
    def test_the_uploads_that_are_not_the_song(self):
        for title in (u"方大同 - 特別的人【歌詞】",
                      u"特別的人 動態歌詞",
                      "Thats my name (Ultra Slowed)",
                      "Some Song (sped up)",
                      "Some Song [Nightcore]",
                      u"花降らし acoustic cover / pazi",
                      "Falling - cover by someone",
                      "Song Title (Karaoke)",
                      "Song Title - Lyric Video",
                      "Falling (Original Song: Harry Styles) by JK of BTS",
                      u"青い珊瑚礁 原曲:小審美治"):
            self.assertTrue(rec.is_reupload({"title": title}), title)

    def test_real_releases_are_left_alone(self):
        for title in ("Perfect", "Photograph", u"太陽與地球",
                      "Someone You Loved", "Undercover Martyn", "Discover",
                      "Hotel California - Live", "Faded (Restrung)",
                      "One Call Away [Remix] (feat. Tyga)",
                      "Original Sin", "The Original"):
            self.assertFalse(rec.is_reupload({"title": title}), title)


class SelectTest(unittest.TestCase):
    def test_reuploads_are_left_out_when_there_is_enough_else(self):
        pool = [track("A%d" % n, "Song%d" % n) for n in range(20)]
        pool += [track("B%d" % n, "Song%d (Slowed)" % n) for n in range(5)]
        out = pick(pool, FakeTaste(), limit=10)
        self.assertEqual(len(out), 10)
        self.assertFalse([t for t in out if rec.is_reupload(t)])

    def test_a_reupload_beats_a_queue_that_stops_early(self):
        # Almost nothing in the pool is clean. Dropping them all would leave a
        # queue of two, which is worse than a queue with an edit in it.
        pool = [track("A%d" % n, "Song%d (Slowed)" % n) for n in range(6)]
        pool += [track("B%d" % n, "Song%d" % n) for n in range(2)]
        out = pick(pool, FakeTaste(), limit=10)
        self.assertEqual(len(out), 8)

    def test_a_mandarin_seed_only_gets_a_quarter_of_a_batch_in_english(self):
        # The shape that broke in the wild: a deep latin taste profile with
        # high affinity, up against the seed's own Mandarin radio.
        affinity = {"lat%d" % n: 5.0 for n in range(20)}
        pool = [track("lat%d" % n, "Latin %d" % n, source="taste", rank=n)
                for n in range(20)]
        pool += [track(u"華語%d" % n, u"歌曲%d" % n, source="radio", rank=n)
                 for n in range(20)]
        out = pick(pool, FakeTaste(artists=affinity), limit=20,
                   seed_script="han")
        self.assertEqual(len(out), 20)
        latin = [t for t in out if rec.track_script(t) == "latin"]
        self.assertLessEqual(len(latin), 5)

    def test_the_language_cap_gives_way_rather_than_shorten_the_queue(self):
        pool = [track("lat%d" % n, "Latin %d" % n, source="taste", rank=n)
                for n in range(10)]
        out = pick(pool, FakeTaste(), limit=10, seed_script="han")
        self.assertEqual(len(out), 10)

    def test_the_queue_opens_with_the_song_that_was_tapped(self):
        # Every seed used to open with whatever sat at the top of the profile,
        # because the radio reservation was only spent once the batch ran out
        # of anything else.
        affinity = {"fav%d" % n: 9.0 for n in range(10)}
        pool = [track("fav%d" % n, "Favourite %d" % n, source="taste", rank=n)
                for n in range(10)]
        pool += [track("nearby%d" % n, "Nearby %d" % n, source="radio", rank=n)
                 for n in range(10)]
        out = pick(pool, FakeTaste(artists=affinity), limit=10)
        self.assertEqual(out[0]["source"], "radio")

    def test_the_radio_is_spread_through_the_batch_not_left_to_the_end(self):
        affinity = {"fav%d" % n: 9.0 for n in range(10)}
        pool = [track("fav%d" % n, "Favourite %d" % n, source="taste", rank=n)
                for n in range(10)]
        pool += [track("nearby%d" % n, "Nearby %d" % n, source="radio", rank=n)
                 for n in range(10)]
        out = pick(pool, FakeTaste(artists=affinity), limit=10)
        first_half = [t for t in out[:5] if t["source"] == "radio"]
        self.assertGreaterEqual(len(first_half), 2)

    def test_two_songs_by_one_artist_is_still_the_limit(self):
        pool = [track("One", "Song %d" % n, rank=n) for n in range(10)]
        pool += [track("Other%d" % n, "Else %d" % n, rank=n) for n in range(10)]
        out = pick(pool, FakeTaste(), limit=10)
        mine = [t for t in out if t["artist"] == "One"]
        self.assertLessEqual(len(mine), rec.ARTIST_CAP)

    def test_songs_already_in_the_profile_stay_a_minority(self):
        known = {rec.identity(track("own%d" % n, "Owned %d" % n))
                 for n in range(20)}
        affinity = {"own%d" % n: 9.0 for n in range(20)}
        pool = [track("own%d" % n, "Owned %d" % n, source="taste", rank=n)
                for n in range(20)]
        pool += [track("new%d" % n, "New %d" % n, source="radio", rank=n)
                 for n in range(20)]
        out = pick(pool, FakeTaste(artists=affinity, known=known), limit=10)
        theirs = [t for t in out if rec.identity(t) in known]
        self.assertLessEqual(len(theirs), 2)


class RecentTest(unittest.TestCase):
    """The ledger that stops every queue opening with the same favourite."""

    def setUp(self):
        self.home = tempfile.mkdtemp()
        self.path = os.path.join(self.home, "recent.json")
        self.addCleanup(shutil.rmtree, self.home, True)

    def ledger(self, ttl=rec.RECENT_TTL):
        return rec.RecentlyServed(path=self.path, ttl=ttl)

    def test_a_song_just_played_is_pushed_down_the_order(self):
        led = self.ledger()
        led.note([track("Fav", "Anthem")])
        self.assertGreater(led.penalty(rec.identity(track("Fav", "Anthem"))),
                           0.5)
        self.assertEqual(led.penalty(rec.identity(track("Fav", "Other"))), 0.0)

    def test_the_demotion_fades_rather_than_switching_off(self):
        led = self.ledger(ttl=100)
        key = rec.identity(track("Fav", "Anthem"))
        led.note([track("Fav", "Anthem")])
        fresh = led.penalty(key)
        led._at[key] = time.time() - 90
        self.assertLess(led.penalty(key), fresh / 4)

    def test_the_ledger_forgets_after_a_while(self):
        led = self.ledger(ttl=100)
        key = rec.identity(track("Fav", "Anthem"))
        led.note([track("Fav", "Anthem")])
        led._at[key] = time.time() - 200
        self.assertEqual(led.penalty(key), 0.0)

    def test_the_ledger_outlives_the_process(self):
        self.ledger().note([track("Fav", "Anthem")])
        again = self.ledger()
        self.assertGreater(again.penalty(rec.identity(track("Fav", "Anthem"))),
                           0.5)

    def test_the_next_queue_does_not_open_with_the_same_favourite(self):
        # Two different seeds, two different sessions, one taste profile. The
        # complaint was that both came back with the same track in slot two.
        affinity = {"fav%d" % n: 9.0 - n for n in range(5)}
        pool = [track("fav%d" % n, "Favourite %d" % n, source="taste", rank=n)
                for n in range(5)]
        taste = FakeTaste(artists=affinity)
        led = self.ledger()

        first = pick(pool, taste, limit=3, recent=led)
        led.note(first)
        second = pick(pool, taste, limit=3, recent=led)
        self.assertNotEqual(first[0]["title"], second[0]["title"])

    def test_a_demoted_song_still_plays_when_it_is_all_there_is(self):
        pool = [track("fav0", "Only One", source="taste")]
        led = self.ledger()
        led.note(pool)
        self.assertEqual(len(pick(pool, FakeTaste(), limit=3, recent=led)), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
