"""The voice between songs.

Spotify's DJ is three things stacked: the same recommender that builds the
station, a language model that writes a line about what is coming up, and a
synthesised voice that reads it. The first is already here; this module adds
the other two.

Both halves live on this machine rather than the phone, for the same reason
the lyrics do. The model key is here. The voice is here - this speaks through
Microsoft's read-aloud service, which needs no key but does need a Python
process, and putting it server side means the phone plays an ordinary
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


# 24kHz mono, and 96kbps rather than the 48 that `edge_tts.Communicate`
# hardcodes into its handshake. Measured against the live endpoint: 96 comes
# back at exactly twice the bytes for the same sentence, 128 and 160 come back
# empty, and every 48kHz variant is refused. So this is the ceiling the free
# read-aloud service offers, and the old default was sitting an octave of
# bitrate below it - which is audible, because the DJ is talking over music.
AUDIO_FORMAT = "audio-24khz-96kbitrate-mono-mp3"

# Radio hosts talk slightly faster than a screen reader. This is also why the
# clips are a little shorter, which is worth something when one plays over the
# opening bars of a song.
SPEAKING_RATE = "+8%"


async def _synthesise(text, voice, rate):
    """One websocket round trip to the read-aloud service.

    Written out rather than calling `edge_tts.Communicate` because the output
    format is baked into a literal inside its handshake and there is no
    parameter for it. Everything genuinely hard here - the Sec-MS-GEC token,
    the SSML envelope - is still `edge_tts`, so this tracks its updates.
    """
    import aiohttp
    import edge_tts.communicate as wire
    from edge_tts.constants import SEC_MS_GEC_VERSION, WSS_HEADERS, WSS_URL
    from edge_tts.drm import DRM

    config = wire.TTSConfig(voice=voice, rate=rate, volume="+0%", pitch="+0Hz",
                            boundary="SentenceBoundary")
    url = ("%s&ConnectionId=%s&Sec-MS-GEC=%s&Sec-MS-GEC-Version=%s"
           % (WSS_URL, wire.connect_id(), DRM.generate_sec_ms_gec(),
              SEC_MS_GEC_VERSION))
    config_frame = (
        "X-Timestamp:%s\r\n"
        "Content-Type:application/json; charset=utf-8\r\n"
        "Path:speech.config\r\n\r\n"
        '{"context":{"synthesis":{"audio":{"metadataoptions":{'
        '"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},'
        '"outputFormat":"%s"}}}}\r\n'
        % (wire.date_to_string(), AUDIO_FORMAT))

    chunks = []
    session = aiohttp.ClientSession(trust_env=True)
    try:
        async with session.ws_connect(
                url, compress=15,
                headers=DRM.headers_with_muid(WSS_HEADERS),
                ssl=wire._SSL_CTX) as socket:
            await socket.send_str(config_frame)
            await socket.send_str(wire.ssml_headers_plus_data(
                wire.connect_id(), wire.date_to_string(),
                wire.mkssml(config, text)))

            async for message in socket:
                if message.type == aiohttp.WSMsgType.TEXT:
                    if "Path:turn.end" in message.data:
                        break
                elif message.type == aiohttp.WSMsgType.BINARY:
                    if len(message.data) < 2:
                        continue
                    header = int.from_bytes(message.data[:2], "big")
                    chunks.append(message.data[2 + header:])
    finally:
        await session.close()
    return b"".join(chunks)


def speak(text, voice, path, rate=None):
    """Synthesise `text` to `path` as MP3.

    The synthesiser is async and this server is threaded, so each call gets its
    own event loop rather than borrowing one that belongs to another thread.
    """
    loop = asyncio.new_event_loop()
    try:
        audio = loop.run_until_complete(
            _synthesise(text, voice, rate or SPEAKING_RATE))
    finally:
        loop.close()
    if not audio:
        raise RuntimeError("the voice service returned no audio")

    temp = str(path) + ".tmp"
    with open(temp, "wb") as handle:
        handle.write(audio)
    os.replace(temp, path)


# -------------------------------------------------------------------- public


def voice_over(text, language=None, voice=None):
    """Speak a script that has already been written, and return its audio id.

    `line()` writes a sentence and speaks it. The DJ loop writes its own
    script while it is choosing the set - one decision, one model call - so it
    needs only this half. Cached on the words themselves, because the same
    sentence read by the same voice is the same audio, whatever set it belongs
    to.
    """
    text = (text or "").strip()
    if not text:
        raise RuntimeError("nothing to say")

    language = normalise_language(language)
    voice = voice or voice_for(language)
    key = hashlib.sha1(("say|%s|%s" % (text, voice)).lower().encode("utf-8")
                       ).hexdigest()[:20]

    with _lock_for(key):
        if _read_cache(key):
            return key
        _, audio_path = _paths(key)
        speak(text, voice, audio_path)
        _write_cache(key, {"v": CACHE_VERSION, "written": time.time(),
                           "text": text, "voice": voice,
                           "language": language})
    return key


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
