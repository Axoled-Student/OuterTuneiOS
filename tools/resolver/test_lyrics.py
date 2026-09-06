"""Unit tests for the lyrics module.

Everything here is offline and deterministic: LRC parsing, title cleaning,
language detection and the shape of a reply. The network and the model are
stubbed, because what those return is not this module's decision - how it
matches, aligns and caches is.

Run:  python tools/resolver/test_lyrics.py
"""
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import lyrics  # noqa: E402


SYNCED = "\n".join([
    "[ar: YOASOBI]",
    "[00:00.58] Line one",
    "[00:03.10][01:03.10] Repeated hook",
    "not timed at all",
    "[01:10] Late line",
])


class ParseTest(unittest.TestCase):
    def test_drops_metadata_and_untimed_lines(self):
        rows = lyrics.parse_lrc(SYNCED)
        self.assertEqual([row["text"] for row in rows],
                         ["Line one", "Repeated hook", "Repeated hook",
                          "Late line"])

    def test_expands_shared_timestamps_in_order(self):
        rows = lyrics.parse_lrc(SYNCED)
        self.assertEqual([row["t"] for row in rows], [0.58, 3.1, 63.1, 70.0])

    def test_empty_input(self):
        self.assertEqual(lyrics.parse_lrc(""), [])
        self.assertEqual(lyrics.parse_lrc(None), [])


class CleanTest(unittest.TestCase):
    def test_strips_youtube_trailers(self):
        self.assertEqual(lyrics.clean_title("アイドル (Official Music Video)"),
                         "アイドル")
        self.assertEqual(lyrics.clean_title("Blank Space [Lyric Video]"),
                         "Blank Space")
        self.assertEqual(lyrics.clean_title("好不容易 (feat. 婁峻碩)"),
                         "好不容易")

    def test_keeps_a_title_that_is_only_a_trailer(self):
        # Better to search for something than for nothing.
        self.assertEqual(lyrics.clean_title("(Official Video)"),
                         "(Official Video)")

    def test_takes_the_lead_artist(self):
        self.assertEqual(lyrics.clean_artist("ROSÉ & Bruno Mars"), "ROSÉ")
        self.assertEqual(lyrics.clean_artist("YOASOBI, ikura"), "YOASOBI")
        self.assertEqual(lyrics.clean_artist("Aimer - Topic"), "Aimer")


class LanguageTest(unittest.TestCase):
    def test_scripts(self):
        self.assertEqual(lyrics.detect_language("相壊す ぐわんぐわんな その眼に"),
                         "ja")
        self.assertEqual(lyrics.detect_language("Nice to meet you"), "en")
        self.assertEqual(lyrics.detect_language("사랑이 이겨요 마지막엔"), "ko")

    def test_separates_the_two_chinese_scripts(self):
        self.assertEqual(
            lyrics.detect_language("故事的小黄花 从出生那年就飘着 随记忆晃到现在"),
            "zh-Hans")
        self.assertEqual(
            lyrics.detect_language("故事的小黃花 從出生那年就飄著 隨記憶晃到現在"),
            "zh-Hant")

    def test_marker_table_is_well_formed(self):
        self.assertEqual(len(lyrics._SIMPLIFIED), len(lyrics._TRADITIONAL))
        self.assertFalse(lyrics._SIMPLIFIED & lyrics._TRADITIONAL)

    def test_translation_is_skipped_only_when_it_would_be_a_no_op(self):
        self.assertTrue(lyrics._same_language("zh-Hant", "zh-Hant"))
        # A simplified transcript in front of a traditional reader is worth
        # converting, so this must not count as the same language.
        self.assertFalse(lyrics._same_language("zh-Hans", "zh-Hant"))
        self.assertTrue(lyrics._same_language("en", "en"))
        self.assertFalse(lyrics._same_language("ja", "zh-Hant"))

    def test_target_normalisation(self):
        self.assertEqual(lyrics.normalise_target("zh-Hant-TW"), "zh-Hant")
        self.assertEqual(lyrics.normalise_target("zh-CN"), "zh-Hans")
        self.assertEqual(lyrics.normalise_target("en-US"), "en")
        self.assertIsNone(lyrics.normalise_target(""))


class ArrayTest(unittest.TestCase):
    def test_accepts_a_fenced_reply(self):
        raw = 'here you go\n```json\n["a", "b"]\n```'
        self.assertEqual(lyrics._parse_array(raw, 2), ["a", "b"])

    def test_rejects_the_wrong_length(self):
        # A short reply would shift every later line against the wrong text,
        # which is worse than showing no translation at all.
        self.assertIsNone(lyrics._parse_array('["a"]', 2))

    def test_rejects_junk(self):
        self.assertIsNone(lyrics._parse_array("sorry, I cannot", 2))
        self.assertIsNone(lyrics._parse_array("", 1))


class GetTest(unittest.TestCase):
    """The public path, with lrclib and the model both replaced."""

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self._cache_dir = lyrics.CACHE_DIR
        lyrics.CACHE_DIR = __import__("pathlib").Path(self.temp.name)
        self.addCleanup(setattr, lyrics, "CACHE_DIR", self._cache_dir)

        self.searches = []
        self._search = lyrics._search
        self.addCleanup(setattr, lyrics, "_search", self._search)
        lyrics._search = self.fake_search

        self.translated = []
        self._translate = lyrics.translate_lines
        self.addCleanup(setattr, lyrics, "translate_lines", self._translate)
        lyrics.translate_lines = self.fake_translate

    def fake_search(self, title, artist, duration):
        self.searches.append((title, artist, duration))
        return {"syncedLyrics": "[00:01.00] hello\n[00:04.00] world",
                "plainLyrics": "hello\nworld",
                "trackName": "Hello", "artistName": "Someone"}

    def fake_translate(self, texts, target, model=None):
        self.translated.append((tuple(texts), target))
        return ["<%s>" % text for text in texts]

    def test_returns_timed_lines(self):
        reply = lyrics.get("Hello", "Someone", duration=200)
        self.assertTrue(reply["ok"])
        self.assertTrue(reply["synced"])
        self.assertEqual([row["t"] for row in reply["lines"]], [1.0, 4.0])
        self.assertFalse(reply["translated"])

    def test_second_call_does_not_search_again(self):
        lyrics.get("Hello", "Someone", duration=200)
        lyrics.get("Hello", "Someone", duration=200)
        self.assertEqual(len(self.searches), 1)

    def test_duration_is_bucketed(self):
        # The same recording reported a second apart is one cache entry.
        lyrics.get("Hello", "Someone", duration=200)
        lyrics.get("Hello", "Someone", duration=201)
        self.assertEqual(len(self.searches), 1)

    def test_waiting_caller_gets_the_translation_inline(self):
        reply = lyrics.get("Hello", "Someone", duration=200,
                           target="zh-Hant-TW", wait=True)
        self.assertTrue(reply["translated"])
        self.assertEqual([row["tr"] for row in reply["lines"]],
                         ["<hello>", "<world>"])
        self.assertEqual(reply["target"], "zh-Hant")

    def test_translation_is_cached(self):
        lyrics.get("Hello", "Someone", duration=200, target="zh-Hant",
                   wait=True)
        lyrics.get("Hello", "Someone", duration=200, target="zh-Hant",
                   wait=True)
        self.assertEqual(len(self.translated), 1)

    def test_lyrics_do_not_wait_on_the_model(self):
        # The default path answers with the words immediately and says a
        # translation is on its way.
        stop = __import__("threading").Event()
        lyrics.translate_lines = lambda texts, target, model=None: (
            stop.wait(30), ["late"] * len(texts))[1]

        reply = lyrics.get("Hello", "Someone", duration=200, target="ja")
        self.assertFalse(reply["translated"])
        self.assertTrue(reply["translating"])
        self.assertEqual(len(reply["lines"]), 2)
        stop.set()

    def test_no_translation_when_it_would_be_a_no_op(self):
        reply = lyrics.get("Hello", "Someone", duration=200, target="en",
                           wait=True)
        self.assertFalse(reply["translated"])
        self.assertFalse(reply["translating"])
        self.assertEqual(self.translated, [])

    def test_a_miss_is_still_a_valid_reply(self):
        lyrics._search = lambda *args: None
        reply = lyrics.get("Nothing", "Nobody", duration=100)
        self.assertFalse(reply["ok"])
        self.assertEqual(reply["lines"], [])
        self.assertFalse(reply["translating"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
