"""The DJ loop: themed mini-sets, one at a time, reacting as you listen.

A station that picks twenty songs up front and reads a line over every third
one is not what Spotify's DJ does. Theirs runs a loop: look at what you have
been listening to, pick a theme for the next few songs, choose songs for it,
decide whether it is worth saying anything, say it, play the set, watch what
you skip - and then pick the next theme knowing what just happened.

This is that loop. One turn of it is one call to `next_set`, and one turn
produces one set: a theme, four or so songs chosen for it, and usually a
sentence introducing them.

Two things make it feel instant. The theme, the songs and the script come back
from a single model call rather than three - they are one creative decision
anyway, and asking three times costs three round trips. And the moment a set is
handed over, the next one starts being built in the background, so from the
second set onward the listener is never waiting for the DJ: the answer is
already sitting in memory when the last song of the current set ends.

Feedback is the point of the loop, so it is not decoration here. Skips move the
next theme away from what was skipped and get those songs blocked outright;
songs played to the end pull it towards them. A set built before the listener
skipped through it is thrown away rather than served, because a DJ that ignores
you reaching for the button is the thing being fixed.
"""
import concurrent.futures
import json
import re
import threading
import time
import uuid

import discovery
import dj
import recommender as rec

# Four songs is about twelve minutes - long enough to be a set rather than a
# pair, short enough that a theme the listener dislikes is over soon.
SET_SIZE = 4
SESSION_TTL = 60 * 90
# How much history the prompt carries. Everything played is blocked from
# repeating regardless; this is only what the model is shown.
RECENT_SHOWN = 24

_sessions = {}
_sessions_guard = threading.Lock()

_pool = concurrent.futures.ThreadPoolExecutor(
    max_workers=3, thread_name_prefix="djset")
# Separate pool, for the same reason discovery keeps one: a set's lookups
# cannot run together if they are queued behind the job that spawned them.
_lookup_pool = concurrent.futures.ThreadPoolExecutor(
    max_workers=8, thread_name_prefix="djsetlookup")
# And the voice gets a third, for a sharper version of the same reason: a
# background set waits on the line it is having spoken, so if the speaking
# were queued behind other background sets they would all wait on each other.
_voice_pool = concurrent.futures.ThreadPoolExecutor(
    max_workers=4, thread_name_prefix="djsetvoice")


# ------------------------------------------------------------------ sessions


def _expire(now):
    with _sessions_guard:
        for key in [k for k, s in _sessions.items()
                    if now - s["touched"] > SESSION_TTL]:
            _sessions.pop(key, None)


def _session(session_id, language):
    """The listener's current run of sets, or a new one."""
    now = time.time()
    _expire(now)
    if session_id:
        with _sessions_guard:
            found = _sessions.get(session_id)
        if found:
            found["touched"] = now
            return found

    state = {
        "id": uuid.uuid4().hex[:12],
        "language": language,
        "index": 0,              # sets handed over so far
        "history": [],           # (theme, [descriptions]) for the prompt
        "played": [],            # descriptions, newest last
        "seen_keys": set(),      # identities, so nothing repeats in a session
        "seen_ids": set(),
        "skipped": [],
        "liked": [],
        "silent_run": 0,         # consecutive sets with no commentary
        "ahead": None,           # (future, skip_count_when_started)
        "touched": now,
        "lock": threading.Lock(),
    }
    with _sessions_guard:
        _sessions[state["id"]] = state
    return state


# -------------------------------------------------------------------- asking


def _profile(engine):
    top = [a for a, _ in sorted(engine.taste.artists.items(),
                                key=lambda kv: -kv[1])[:12]]
    loved = ["%s - %s" % (t["artist"], t["name"])
             for t in engine.taste.tracks[:10]]
    return top, loved


def _ask(engine, state, language):
    """One prompt for the whole turn: theme, songs, and whether to speak."""
    top, loved = _profile(engine)
    hour = time.localtime().tm_hour
    part = ("late at night" if hour >= 22 or hour < 5 else
            "in the morning" if hour < 11 else
            "in the afternoon" if hour < 17 else "in the evening")

    lines = [
        "You are the DJ of one listener's personal radio station. You choose "
        "what comes next and you talk to them between sets.",
        "",
        "It is %s for them." % part,
        "Their favourite artists: %s" % (", ".join(top) or "not known yet"),
        "Songs they love: %s" % ("; ".join(loved) or "not known yet"),
    ]

    if state["history"]:
        told = ["%d. %s" % (n + 1, theme)
                for n, (theme, _) in enumerate(state["history"][-6:])]
        lines += ["", "Sets you have already played them tonight:"] + told
    if state["played"]:
        lines += ["", "Already played - never choose any of these again:",
                  "; ".join(state["played"][-RECENT_SHOWN:])]
    if state["skipped"]:
        lines += ["", "They SKIPPED these. Move away from whatever these have "
                  "in common:", "; ".join(state["skipped"][-10:])]
    if state["liked"]:
        lines += ["", "They listened to these all the way through. More in "
                  "this direction:", "; ".join(state["liked"][-10:])]

    if state["index"] == 0:
        lines += ["", "This is the first set of the session - you are signing "
                  "on, so introduce the station."]
    elif state["silent_run"] >= 2:
        lines += ["", "You have not spoken for a couple of sets now, so say "
                  "something this time."]

    lines += [
        "",
        "Pick ONE theme for the next short set: a mood, a thread, a time of "
        "day, a sound. It should follow on from what just happened rather "
        "than repeat it, and it must not be a theme you already played.",
        "Choose %d real, existing songs that fit it. Vary the artists - at "
        "most one song per artist. Prefer recordings that are actually on "
        "YouTube Music." % SET_SIZE,
        "Then decide whether the set is worth introducing out loud. Say "
        "something when the mood changes or the set has a thread worth "
        "naming; stay quiet when it would just be noise.",
        "",
        "The script is spoken aloud, so: %s, one or two sentences, under 45 "
        "words, no emoji, no formatting, no track listing read out like an "
        "index. Name at most two of the songs. Never state release dates, "
        "chart positions, awards or anything else you would have to look up - "
        "talk about how it sounds and where it takes them."
        % dj.LANGUAGE_NAMES.get(language, "in English"),
        "",
        'Reply with ONLY this JSON and nothing else:',
        '{"theme": "short phrase", "say": true, "script": "what you say", '
        '"songs": [{"artist": "...", "title": "..."}]}',
    ]
    return "\n".join(lines)


def _parse(raw):
    """The JSON object out of a model reply, wrappers and all."""
    text = (raw or "").strip()
    fence = re.search(r"```(?:json)?\s*(.+?)```", text, re.S)
    if fence:
        text = fence.group(1).strip()
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        raise ValueError("no JSON object in the reply")
    payload = json.loads(text[start:end + 1])

    songs = []
    for row in payload.get("songs") or []:
        if not isinstance(row, dict):
            continue
        artist = (row.get("artist") or "").strip()
        title = (row.get("title") or "").strip()
        if title:
            songs.append({"artist": artist, "title": title})
    if not songs:
        raise ValueError("no songs in the reply")

    return {
        "theme": (payload.get("theme") or "").strip()[:200],
        "say": bool(payload.get("say", True)),
        "script": (payload.get("script") or "").strip(),
        "songs": songs,
    }


# ------------------------------------------------------------------ building


def _lookup(engine, visitor, song):
    """One proposal, as a search. Shared with the station's own lookup cache,
    so a song either side already found costs nothing here."""
    query = ("%s %s" % (song["artist"], song["title"])).strip()
    return discovery._memo("s:" + query,
                           lambda: rec.search_song(query, visitor,
                                                   engine.cookie))


def _resolve(engine, state, songs):
    """Look the proposals up together, keep the real ones, drop repeats."""
    visitor = engine.visitor()
    futures = [_lookup_pool.submit(_lookup, engine, visitor, q) for q in songs]
    out = []
    with state["lock"]:
        for future in futures:
            try:
                track = future.result(timeout=25)
            except Exception:  # noqa: BLE001
                continue
            if not track:
                continue
            key = rec.identity(track)
            if (track["videoId"] in state["seen_ids"]
                    or key in state["seen_keys"]
                    or engine.learned.is_rejected(key)):
                continue
            state["seen_ids"].add(track["videoId"])
            state["seen_keys"].add(key)
            out.append(track)
    return out


def _build(engine, state, language, model):
    """One turn of the loop, start to finish.

    The script is spoken while the songs are being looked up, because neither
    needs the other and together they are the whole wait.
    """
    cfg = discovery._ai_config()
    if not cfg:
        return {"error": "no AI endpoint configured (ai.env missing)"}

    try:
        raw = discovery._ask_model(cfg, _ask(engine, state, language),
                                   model or dj.MODEL,
                                   max_tokens=600, timeout=60)
        plan = _parse(raw)
    except Exception as e:  # noqa: BLE001
        return {"error": "could not plan the set: %s" % str(e)[:200]}

    speaking = None
    if plan["say"] and plan["script"]:
        speaking = _voice_pool.submit(dj.voice_over, plan["script"], language)

    tracks = _resolve(engine, state, plan["songs"])

    audio = None
    speak_error = None
    if speaking is not None:
        try:
            audio = speaking.result(timeout=45)
        except Exception as e:  # noqa: BLE001
            speak_error = "could not speak it: %s" % str(e)[:160]

    if not tracks:
        return {"error": "none of the songs could be found"}

    return {
        "theme": plan["theme"],
        "say": bool(plan["say"] and plan["script"]),
        "script": plan["script"] if plan["say"] else "",
        "audio": audio,
        "tracks": tracks,
        "error": speak_error,
    }


def _commit(state, built):
    """Record a set as played, so the next turn knows about it."""
    with state["lock"]:
        state["index"] += 1
        state["history"].append((built["theme"], []))
        for track in built["tracks"]:
            state["played"].append(dj._describe(track))
        state["silent_run"] = 0 if built.get("say") else state["silent_run"] + 1


def _feedback(state, skipped, liked):
    """Fold what the listener just did into the session.

    Returns how many of the skips are new, which decides whether a set built
    before they started skipping is still worth serving.
    """
    fresh = 0
    with state["lock"]:
        for name in skipped:
            if name and name not in state["skipped"]:
                state["skipped"].append(name)
                fresh += 1
        for name in liked:
            if name and name not in state["liked"]:
                state["liked"].append(name)
    return fresh


# -------------------------------------------------------------------- public


def next_set(engine, session_id=None, language=None, skipped=(), liked=(),
             model=None):
    """The next themed mini-set, with its commentary already spoken.

    Pass the session id back on every call. Pass what was skipped and what was
    played through since the last one; both change what comes next.
    """
    language = dj.normalise_language(language)
    state = _session(session_id, language)
    state["language"] = language
    engine.taste.refresh()

    fresh_skips = _feedback(state, skipped, liked)

    built = None
    ahead = state.pop("ahead", None)
    if ahead is not None:
        future, _ = ahead
        # One skip is taste drift; two or more means the set waiting in memory
        # was planned for a listener who has since told us otherwise.
        if fresh_skips >= 2:
            future.cancel()
        else:
            try:
                built = future.result(timeout=75)
            except Exception:  # noqa: BLE001
                built = None
            if built and built.get("error") and not built.get("tracks"):
                built = None

    if built is None:
        built = _build(engine, state, language, model)

    if built.get("error") and not built.get("tracks"):
        return {"session": state["id"], "set": state["index"],
                "theme": "", "say": False, "script": "", "audio": None,
                "tracks": [], "error": built["error"]}

    _commit(state, built)

    # The next turn starts now rather than when it is asked for. This is what
    # makes every set after the first arrive instantly.
    state["ahead"] = (_pool.submit(_build, engine, state, language, model),
                      len(state["skipped"]))

    view = {
        "session": state["id"],
        "set": state["index"],
        "theme": built["theme"],
        "say": built["say"],
        "script": built["script"],
        "audio": built["audio"],
        "tracks": [discovery._track_row(t) for t in built["tracks"]],
        "error": built.get("error"),
    }
    if built["audio"]:
        view["audioPath"] = "/djvoice?id=%s" % built["audio"]
    return view
