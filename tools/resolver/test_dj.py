"""Unit tests for the DJ voice.

The model and the speech service are both stubbed, and the cache is pointed at
a throwaway directory. What is being tested is what this module decides: which
voice a language tag gets, that the prompt says the right things, that a
handover is written once and served from disk after that, and - most of all -
that every way this can fail still leaves the client something to act on. A
station whose DJ has laryngitis should still play music.

Run:  python tools/resolver/test_dj.py
"""
import os
import pathlib
import shutil
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import discovery  # noqa: E402
import dj  # noqa: E402


PREV = {"artist": "MIMI", "title": "ハナタバ"}
NEXT = {"artist": "Kanye West", "title": "Stronger"}


class DJTest(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp(prefix="djtest"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self._dir = dj.CACHE_DIR
        dj.CACHE_DIR = self.tmp
        self.addCleanup(setattr, dj, "CACHE_DIR", self._dir)

        dj._locks.clear()

        self._cfg = discovery._ai_config
        discovery._ai_config = lambda: {"endpoint": "x", "key": "y"}
        self.addCleanup(setattr, discovery, "_ai_config", self._cfg)

        self._ask = discovery._ask_model
        self.addCleanup(setattr, discovery, "_ask_model", self._ask)

        self._speak = dj.speak
        self.addCleanup(setattr, dj, "speak", self._speak)

        self.prompts = []
        self.spoken = []
        self.stub_model("Here comes something warm.")
        self.stub_voice()

    def stub_model(self, reply):
        def fake(cfg, prompt, model=None, timeout=90, max_tokens=2000,
                 temperature=0.7):
            self.prompts.append(prompt)
            if isinstance(reply, Exception):
                raise reply
            return reply
        discovery._ask_model = fake

    def stub_voice(self, error=None, body=b"ID3fake-mp3-bytes"):
        def fake(text, voice, path):
            self.spoken.append((text, voice))
            if error:
                raise error
            with open(path, "wb") as handle:
                handle.write(body)
        dj.speak = fake

    # -- which voice speaks

    def test_traditional_and_simplified_are_different_voices(self):
        self.assertEqual(dj.normalise_language("zh-TW"), "zh-Hant")
        self.assertEqual(dj.normalise_language("zh-HK"), "zh-Hant")
        self.assertEqual(dj.normalise_language("zh-Hans-CN"), "zh-Hans")
        self.assertNotEqual(dj.voice_for("zh-Hant"), dj.voice_for("zh-Hans"))

    def test_underscores_and_case_are_accepted(self):
        self.assertEqual(dj.normalise_language("ja_jp"), "ja")
        self.assertEqual(dj.normalise_language("EN-GB"), "en")

    def test_an_unknown_language_still_gets_a_voice(self):
        # No Portuguese voice here, but the station must not go silent.
        self.assertEqual(dj.normalise_language("pt-BR"), "en")
        self.assertTrue(dj.voice_for("pt-BR"))

    def test_missing_language_is_english(self):
        self.assertEqual(dj.normalise_language(None), "en")
        self.assertEqual(dj.normalise_language("  "), "en")

    # -- what the model is asked

    def test_the_prompt_carries_both_songs_and_the_language(self):
        dj.line("late night drive", PREV, NEXT, language="zh-TW")
        prompt = self.prompts[0]
        self.assertIn("late night drive", prompt)
        self.assertIn("ハナタバ", prompt)
        self.assertIn("Stronger", prompt)
        self.assertIn("Traditional Chinese", prompt)

    def test_the_prompt_forbids_facts_it_would_have_to_invent(self):
        dj.line("pop", PREV, NEXT, language="en")
        prompt = self.prompts[0]
        for banned in ("chart positions", "awards", "release news"):
            self.assertIn(banned, prompt)

    def test_a_song_with_no_artist_is_never_called_unknown(self):
        # A placeholder in the prompt comes back out of the speakers.
        dj.line("pop", PREV, {"title": "Stronger"}, language="en")
        self.assertNotIn("unknown", self.prompts[0].split("Write ONE")[0])
        self.assertIn("Coming up: Stronger\n", self.prompts[0])

    def test_a_first_song_with_no_previous_track(self):
        dj.line("pop", {}, NEXT, language="en")
        self.assertNotIn("Just played", self.prompts[0])

    def test_the_first_song_has_nothing_to_hand_over_from(self):
        dj.line("pop", PREV, NEXT, language="en", first=True)
        self.assertNotIn("Just played", self.prompts[0])
        self.assertIn("first song", self.prompts[0])

    # -- what comes back

    def test_a_line_is_written_spoken_and_returned(self):
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertTrue(out["ok"])
        self.assertEqual(out["text"], "Here comes something warm.")
        self.assertEqual(out["voice"], dj.VOICES["en"])
        self.assertFalse(out["cached"])
        self.assertEqual(dj.audio_bytes(out["audio"]), b"ID3fake-mp3-bytes")

    def test_wrappers_the_model_adds_anyway_are_stripped(self):
        self.stub_model('```\n"Coming up next, something bright."\n```')
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertEqual(out["text"], "Coming up next, something bright.")

    def test_a_chosen_voice_overrides_the_language_default(self):
        out = dj.line("pop", PREV, NEXT, language="en",
                      voice="en-US-AndrewNeural")
        self.assertEqual(out["voice"], "en-US-AndrewNeural")
        self.assertEqual(self.spoken[0][1], "en-US-AndrewNeural")

    # -- the cache

    def test_the_same_handover_is_only_paid_for_once(self):
        first = dj.line("pop", PREV, NEXT, language="en")
        second = dj.line("pop", PREV, NEXT, language="en")
        self.assertEqual(len(self.prompts), 1)
        self.assertEqual(len(self.spoken), 1)
        self.assertTrue(second["cached"])
        self.assertEqual(second["audio"], first["audio"])

    def test_a_different_next_song_is_a_different_line(self):
        dj.line("pop", PREV, NEXT, language="en")
        dj.line("pop", PREV, {"artist": "Kanye West", "title": "Heartless"},
                language="en")
        self.assertEqual(len(self.prompts), 2)

    def test_the_same_songs_in_another_language_are_another_line(self):
        a = dj.line("pop", PREV, NEXT, language="en")
        b = dj.line("pop", PREV, NEXT, language="ja")
        self.assertNotEqual(a["audio"], b["audio"])
        self.assertEqual(len(self.prompts), 2)

    def test_a_stale_entry_is_rewritten(self):
        out = dj.line("pop", PREV, NEXT, language="en")
        meta, _ = dj._paths(out["audio"])
        text = meta.read_text(encoding="utf-8")
        meta.write_text(text.replace('"v": 1', '"v": 0'), encoding="utf-8")
        again = dj.line("pop", PREV, NEXT, language="en")
        self.assertFalse(again["cached"])
        self.assertEqual(len(self.prompts), 2)

    def test_a_sidecar_without_audio_is_not_served(self):
        out = dj.line("pop", PREV, NEXT, language="en")
        _, audio = dj._paths(out["audio"])
        audio.unlink()
        again = dj.line("pop", PREV, NEXT, language="en")
        self.assertFalse(again["cached"])

    def test_two_callers_at_once_pay_once(self):
        results = []
        barrier = threading.Barrier(2)

        def race():
            barrier.wait(5)
            results.append(dj.line("pop", PREV, NEXT, language="en"))

        threads = [threading.Thread(target=race) for _ in range(2)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(10)
        self.assertEqual(len(results), 2)
        self.assertEqual(len(self.prompts), 1)

    def test_a_bad_id_reads_nothing_rather_than_wandering_the_disk(self):
        self.assertIsNone(dj.audio_bytes("../../../etc/passwd"))
        self.assertIsNone(dj.audio_bytes("nope"))
        self.assertIsNone(dj.audio_bytes(""))

    # -- degraded paths

    def test_a_mute_voice_still_hands_back_the_sentence(self):
        self.stub_voice(error=RuntimeError("no network"))
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertTrue(out["ok"])
        self.assertEqual(out["text"], "Here comes something warm.")
        self.assertIsNone(out["audio"])
        self.assertIn("could not speak", out["error"])

    def test_a_failed_speak_is_not_remembered_as_a_success(self):
        self.stub_voice(error=RuntimeError("no network"))
        dj.line("pop", PREV, NEXT, language="en")
        self.stub_voice()
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertIsNotNone(out["audio"])

    def test_a_silent_model_is_a_clean_failure(self):
        self.stub_model("   ")
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertFalse(out["ok"])
        self.assertIn("could not write", out["error"])
        self.assertEqual(self.spoken, [])

    def test_a_thrown_model_is_a_clean_failure(self):
        self.stub_model(RuntimeError("502 upstream"))
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertFalse(out["ok"])
        self.assertIn("502 upstream", out["error"])

    def test_no_ai_key_is_a_clean_failure(self):
        discovery._ai_config = lambda: None
        out = dj.line("pop", PREV, NEXT, language="en")
        self.assertFalse(out["ok"])
        self.assertIn("ai.env", out["error"])

    def test_nothing_coming_up_is_refused_before_the_model(self):
        out = dj.line("pop", PREV, {}, language="en")
        self.assertFalse(out["ok"])
        self.assertEqual(self.prompts, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
