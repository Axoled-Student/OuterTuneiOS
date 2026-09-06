"""The voice between songs.

Spotify's DJ is three things stacked: the same recommender that builds the
station, a language model that writes a line about what is coming up, and a
synthesised voice that reads it. The first is already here; this module adds
the other two.

Both halves live on this machine rather than the phone, for the same reason
the lyrics do. The model key is here. The voice is here - `edge_tts` speaks
through Microsoft's read-aloud service, which needs no key but does need a
Python process, and putting it server side means the phone plays an ordinary
MP3 URL instead of shipping a synthesiser. And the result caches: two devices
hearing the same handover pay for it once.

Writing a line takes about five seconds and speaking it under one, so the
client asks for the line belonging to the *next* track while the current one
is still playing. By the time the handover arrives the MP3 is already on disk.

Nothing here invents facts. The prompt forbids dates, chart positions and
release news, because a model with no source for them will produce them
anyway, confidently, and a DJ that lies about an artist is worse than one that
says nothing.
"""
import asyncio
import hashlib
import json
import os
import pathlib
import re
import threading
import time

import discovery

CACHE_DIR = pathlib.Path(__file__).resolve().parents[2] / "build" / "dj_cache"
# A handover between two particular songs says the same thing every time, so
# this is long. It exists only so the cache cannot grow without bound.
CACHE_TTL = 60 * 60 * 24 * 14
CACHE_VERSION = 1

MODEL = "gemini-3.8-flash-high"
# One sentence. Enough tokens for the model to reach a full stop in Japanese,
# which costs more of them than English does.
MAX_TOKENS = 160

# Microsoft's neural voices, keyed by the language the line is written in.
# The multilingual entries are deliberate: a Chinese sentence introducing a
# Japanese title is the normal case here, not the exception, and a locale-only
# voice reads the foreign half as if it were spelled out.
VOICES = {
    "zh-Hant": "zh-TW-HsiaoChenNeural",
    "zh-Hans": "zh-CN-XiaoxiaoNeural",
    "ja": "ja-JP-NanamiNeural",
    "ko": "ko-KR-SunHiNeural",
    "en": "en-US-AvaNeural",
}
FALLBACK_VOICE = "en-US-AvaMultilingualNeural"

LANGUAGE_NAMES = {
    "zh-Hant": "Traditional Chinese, as spoken in Taiwan",
    "zh-Hans": "Simplified Chinese",
    "ja": "Japanese",
    "ko": "Korean",
    "en": "English",
}

# One in-flight line per cache key: the same handover requested by two devices
# at once should cost one model call, not two.
_locks = {}
_locks_guard = threading.Lock()


def _lock_for(key):
    with _locks_guard:
        lock = _locks.get(key)
        if lock is None:
            lock = _locks[key] = threading.Lock()
        return lock


# ------------------------------------------------------------------ language


def normalise_language(tag):
    """Fold a client's language tag onto one this module has a voice for."""
    tag = (tag or "").strip().replace("_", "-")
    if not tag:
        return "en"
    low = tag.lower()
    if low.startswith("zh"):
        # zh-TW, zh-HK and zh-Hant all read traditional characters; only
        # mainland and Singapore tags mean the simplified set.
        parts = low.split("-")
        if "hans" in parts or "cn" in parts or "sg" in parts:
            return "zh-Hans"
        return "zh-Hant"
    for known in ("ja", "ko", "en"):
        if low == known or low.startswith(known + "-"):
            return known
    # An unknown language still gets a station; it just gets it in English,
    # which every one of these voices can read.
    return "en"


def voice_for(language):
    return VOICES.get(language, FALLBACK_VOICE)


# --------------------------------------------------------------------- cache


def _key(theme, prev, upcoming, language, voice):
    raw = "|".join([
        (theme or "").strip().lower(),
        "%s - %s" % (prev.get("artist", ""), prev.get("title", "")),
        "%s - %s" % (upcoming.get("artist", ""), upcoming.get("title", "")),
        language, voice,
    ]).lower()
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:20]


def _paths(key):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return CACHE_DIR / (key + ".json"), CACHE_DIR / (key + ".mp3")


def _read_cache(key):
    meta_path, audio_path = _paths(key)
    try:
        with open(meta_path, encoding="utf-8") as handle:
            entry = json.load(handle)
    except (OSError, ValueError):
        return None
    if entry.get("v") != CACHE_VERSION:
        return None
    if time.time() - float(entry.get("written") or 0) > CACHE_TTL:
        return None
    # The sidecar is the record; the audio is the thing being served. One
    # without the other is a half-written entry, so treat it as a miss.
    if not audio_path.exists() or audio_path.stat().st_size == 0:
        return None
    return entry


def _write_cache(key, entry):
    meta_path, _ = _paths(key)
    temp = str(meta_path) + ".tmp"
    try:
        with open(temp, "w", encoding="utf-8") as handle:
            json.dump(entry, handle, ensure_ascii=False)
        os.replace(temp, meta_path)
    except OSError:
        pass


def audio_bytes(key):
    """The spoken line for a cache key, or None if it is not on disk."""
    if not re.fullmatch(r"[0-9a-f]{1,40}", key or ""):
        return None
    _, audio_path = _paths(key)
    try:
        with open(audio_path, "rb") as handle:
            return handle.read()
    except OSError:
        return None


# -------------------------------------------------------------------- script


def _describe(track):
    """"Artist - Title", or whichever half of it exists.

    Never the word "unknown": a placeholder in the prompt comes straight back
    out of the speakers as "here is Stronger by unknown".
    """
    artist = (track.get("artist") or "").strip()
    title = (track.get("title") or "").strip()
    if artist and title:
        return "%s - %s" % (artist, title)
    return title or artist


def _script_prompt(theme, prev, upcoming, language, first):
    played = ""
    if not first and _describe(prev):
        played = "Just played: %s\n" % _describe(prev)
    opening = ("This is the first song of the session; welcome the listener "
               "in half a clause, then introduce it."
               if first else
               "Hand over from the last song to the next one.")
    return (
        "You are the voice between songs on one listener's personal radio "
        "station.\n"
        "Station: %s\n"
        "%s"
        "Coming up: %s\n\n"
        "%s\n"
        "Write ONE spoken sentence of at most 25 words, in %s. Say how the "
        "music feels and why it follows. Do not state facts you would have to "
        "look up - no dates, chart positions, awards, sales or release news; "
        "inventing them is worse than saying nothing. Keep song and artist "
        "names exactly as written above, in their own script. If no artist is "
        "named, do not guess one and do not say it is unknown - just talk "
        "about the song. No emoji, no markdown, no quotation marks, no stage "
        "directions.\n"
        "Reply with the sentence and nothing else."
        % (theme or "a mix picked for them", played, _describe(upcoming),
           opening, LANGUAGE_NAMES.get(language, "English")))


def _tidy(text):
    """Strip the wrappers a model reaches for even when told not to."""
    text = (text or "").strip()
    # A model that ignores "no markdown" usually reaches for a fenced block.
    text = re.sub(r"^```[a-z]*\s*|\s*```$", "", text).strip()
    text = re.sub(r"\s+", " ", text)
    if len(text) >= 2 and text[0] in "\"'“”「『" and text[-1] in "\"'“”」』":
        text = text[1:-1].strip()
    return text


def write_line(theme, prev, upcoming, language, first=False, model=None):
    """Ask the model for one sentence. Raises on failure; the caller decides."""
    cfg = discovery._ai_config()
    if not cfg:
        raise RuntimeError("no AI endpoint configured (ai.env missing)")
    raw = discovery._ask_model(cfg,
                               _script_prompt(theme, prev, upcoming, language,
                                              first),
                               model or MODEL,
                               timeout=40, max_tokens=MAX_TOKENS,
                               temperature=0.9)
    text = _tidy(raw)
    if not text:
        raise RuntimeError("model returned nothing to say")
    return text


# --------------------------------------------------------------------- voice


def speak(text, voice, path):
    """Synthesise `text` to `path` as MP3.

    `edge_tts` is async and this server is threaded, so each call gets its own
    event loop rather than borrowing one that belongs to another thread.
    """
    import edge_tts  # imported late: the resolver still runs without a DJ

    temp = str(path) + ".tmp"

    async def run():
        await edge_tts.Communicate(text, voice).save(temp)

    loop = asyncio.new_event_loop()
    try:
        loop.run_until_complete(run())
    finally:
        loop.close()
    if not os.path.exists(temp) or os.path.getsize(temp) == 0:
        raise RuntimeError("the voice service returned no audio")
    os.replace(temp, path)


# -------------------------------------------------------------------- public


def line(theme, prev, upcoming, language=None, first=False, model=None,
         voice=None):
    """A written and spoken handover into `upcoming`.

    Returns a dict the client can act on even when something failed: `text` is
    what the DJ says and `audio` is the id to fetch it as MP3, and either may
    be absent. A client with text but no audio can still read it aloud itself.
    """
    upcoming = upcoming or {}
    if not (upcoming.get("title") or upcoming.get("artist")):
        return {"ok": False, "error": "no upcoming track"}

    prev = prev or {}
    language = normalise_language(language)
    voice = voice or voice_for(language)

    key = _key(theme, prev, upcoming, language, voice)
    cached = _read_cache(key)
    if cached:
        return {"ok": True, "text": cached["text"], "audio": key,
                "language": language, "voice": voice, "cached": True}

    with _lock_for(key):
        # Another thread may have finished while this one waited for the lock.
        cached = _read_cache(key)
        if cached:
            return {"ok": True, "text": cached["text"], "audio": key,
                    "language": language, "voice": voice, "cached": True}

        try:
            text = write_line(theme, prev, upcoming, language, first, model)
        except Exception as e:  # noqa: BLE001
            return {"ok": False, "error": "could not write a line: %s"
                    % str(e)[:200], "language": language}

        _, audio_path = _paths(key)
        try:
            speak(text, voice, audio_path)
        except Exception as e:  # noqa: BLE001
            # The sentence is still worth handing over: a client that can
            # speak for itself gets a DJ anyway, and one that cannot simply
            # skips this handover.
            return {"ok": True, "text": text, "audio": None,
                    "language": language, "voice": voice,
                    "error": "could not speak it: %s" % str(e)[:200]}

        _write_cache(key, {"v": CACHE_VERSION, "written": time.time(),
                           "text": text, "voice": voice,
                           "language": language})
        return {"ok": True, "text": text, "audio": key,
                "language": language, "voice": voice, "cached": False}
