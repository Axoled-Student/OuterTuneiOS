"""The DJ loop: themed mini-sets, one at a time, reacting as you listen.

A station that picks twenty songs up front and reads a line over every third
one is not what Spotify's DJ does. Theirs runs a loop: look at what you have
been listening to, pick a theme for the next few songs, choose songs for it,
decide whether it is worth saying anything, say it, play the set, watch what
you skip - and then pick the next theme knowing what just happened.

This is that loop. One turn of it is one call to `next_set`, and one turn
produces one set: a theme, four or so songs chosen for it, and usually a
sentence introducing them.

A turn runs in order - plan, find the songs, then write the line about them -
because the DJ has to talk about the set that is actually going to play. Asking
for the script in the same breath as the song list is a round trip cheaper and
was how this started, but the model names songs it hoped for, and a good third
of those turn out not to be on YouTube Music. The station announced tracks
nobody was about to hear.

What makes it feel instant instead is that the moment a set is handed over, the
next one starts being built in the background. From the second set onward the
listener never waits for the DJ: the answer is already sitting in memory when
the last song of the current set ends, and how many round trips it took to get
there stopped mattering.

The songs are chosen to sit outside what the listener already plays. A
model handed a list of somebody's favourites and asked what to play next will
hand the favourites back, which is a station that only ever confirms what you
already knew. So the profile is given to it as a boundary rather than a menu:
these are the songs they have on repeat, do not choose them, and at most one
song per set may be by an artist they already listen to. What the DJ is for is
the third and fourth artist along - the same scene, the same feeling, a name
they have not heard. The rule is enforced twice, once in the asking and once in
the picking, because a model told not to reach for the obvious still reaches
for it perhaps a third of the time.

That only stops the same songs coming back within one station. Coming back
every station is a different problem, and needs a ledger that outlives the
session - what went out in the last few days is off the table, restarts
included.

Feedback is the point of the loop, so it is not decoration here. Skips move the
next theme away from what was skipped and get those songs blocked outright;
songs played to the end pull it towards them. A set built before the listener
skipped through it is thrown away rather than served, because a DJ that ignores
you reaching for the button is the thing being fixed.
"""
import concurrent.futures
import json
import os
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
# More proposals than the set needs. Between songs that are not on YouTube
# Music, songs already played, and different titles that turn out to be the
# same recording, a list of exactly four routinely resolved to one.
ASK_SIZE = SET_SIZE + 4
SESSION_TTL = 60 * 90
# How much of a set may be by an artist the listener already plays. Three of
# four songs by somebody new is what "out of my comfort zone" has to mean if it
# is going to mean anything; one familiar name keeps the set from feeling like
# a stranger's playlist.
FAMILIAR_PER_SET = 1
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


# ------------------------------------------------------------------- ledger


# What the station has actually played, across sessions and across restarts.
# Without this every new station starts from an empty memory, reaches for the
# strongest thing in the taste profile, and plays the listener their own
# favourites again - which is the complaint this exists to answer.
SERVED_STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            ".djset_served.json")
# Long enough that a song does not come back the same evening or the next one,
# short enough that the well does not run dry.
SERVED_TTL = 60 * 60 * 72
# How many of them the model is shown. Everything in the ledger is blocked in
# code regardless; this is only the reminder in the prompt.
SERVED_SHOWN = 30

_served = {}
_served_guard = threading.Lock()
_served_loaded = False


def _prune(now):
    """Drop anything past its welcome. Caller holds the guard."""
    for key in [k for k, row in _served.items()
                if now - row.get("at", 0) > SERVED_TTL]:
        _served.pop(key, None)


def _load_served():
    global _served_loaded
    with _served_guard:
        if _served_loaded:
            return
        _served_loaded = True
        try:
            with open(SERVED_STATE, encoding="utf-8") as fh:
                data = json.load(fh)
        except Exception:  # noqa: BLE001
            return
        if isinstance(data, dict):
            for key, row in data.items():
                if isinstance(row, dict) and row.get("at"):
                    _served[key] = {"at": row["at"], "name": row.get("name", "")}
        _prune(time.time())


def _write_served():
    """Caller holds the guard."""
    try:
        tmp = SERVED_STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(_served, fh)
        os.replace(tmp, SERVED_STATE)
    except Exception:  # noqa: BLE001
        pass


def _note_served(tracks):
    """Record a set as gone out. Only called when one actually reaches a
    listener, so the sets built on spec and never taken cost nothing."""
    _load_served()
    now = time.time()
    with _served_guard:
        for track in tracks or []:
            _served[rec.identity(track)] = {"at": now,
                                            "name": dj._describe(track)}
        _prune(now)
        _write_served()


def _served_keys():
    _load_served()
    now = time.time()
    with _served_guard:
        _prune(now)
        return set(_served)


def _served_names(limit=SERVED_SHOWN):
    _load_served()
    now = time.time()
    with _served_guard:
        _prune(now)
        rows = sorted(_served.values(), key=lambda r: -r.get("at", 0))
    return [r["name"] for r in rows[:limit] if r.get("name")]


# ------------------------------------------------------------------ sessions


def _expire(now):
    with _sessions_guard:
        for key in [k for k, s in _sessions.items()
                    if now - s["touched"] > SESSION_TTL]:
            _sessions.pop(key, None)


def _find(session_id):
    """An existing run of sets, or None. Expiry happens here."""
    now = time.time()
    _expire(now)
    if not session_id:
        return None
    with _sessions_guard:
        found = _sessions.get(session_id)
    if found:
        found["touched"] = now
    return found


def _new_state(language, register=True):
    """A fresh run of sets.

    An unregistered one is a scratch session used to build a set before there
    is a listener for it; it joins the real ones when somebody adopts it.
    """
    now = time.time()
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
    if register:
        with _sessions_guard:
            _sessions[state["id"]] = state
    return state


def _adopt(state):
    """Put a scratch session into service under its own id."""
    state["touched"] = time.time()
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
    ]

    # Handed over as the edge of what they have already heard, not as a list to
    # choose from. Worded that way in the heading as well as the rule below,
    # because a heading that reads "songs they love" is an invitation however
    # the instruction underneath is phrased.
    if top:
        lines.append("Artists they already listen to: %s." % ", ".join(top))
    if loved:
        lines.append("Songs they already have on repeat: %s."
                     % "; ".join(loved))
    if not top and not loved:
        lines.append("Nothing is known about their taste yet, so play them "
                     "something good.")

    served = _served_names()
    if served:
        lines += ["", "This station has already played these for them in the "
                  "last few days. Do not choose any of them again:",
                  "; ".join(served)]

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
        "The point of this station is the music they have not found yet. "
        "Never choose a song they already have on repeat, and at most ONE of "
        "your choices may be by an artist they already listen to - the rest "
        "must be artists they have never played. Reach one step out from "
        "their taste rather than into the middle of it: the same scene, the "
        "same feeling, names they do not own yet.",
        "Then list %d real, existing songs that fit it, best first. Only the "
        "first few get played - the rest are spares, for the ones that turn "
        "out not to be on YouTube Music - so put your strongest choices at "
        "the top. At most one song per artist, and no cover, remix or "
        "alternate version of a song already in the list." % ASK_SIZE,
        "Finally, decide whether this set is worth introducing out loud. Say "
        "something when the mood changes or the set has a thread worth "
        "naming; stay quiet when it would just be noise.",
        "",
        'Reply with ONLY this JSON and nothing else:',
        '{"theme": "short phrase", "say": true, '
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
        "songs": songs,
    }


def _script_prompt(state, theme, tracks, language):
    """What the DJ says over the set, written once the set is real.

    This is a second call rather than part of the first on purpose. A script
    written alongside the song list introduces the songs the model hoped for,
    and a good third of those do not survive the lookup - so the DJ would
    announce a track nobody is about to hear. Naming only songs that are
    actually queued is worth the extra round trip, and every set after the
    first is built in the background anyway, where it costs nothing.
    """
    listing = "; ".join(dj._describe(t) for t in tracks)
    lines = [
        "You are the DJ of one listener's personal radio station. Introduce "
        "the set you are about to play them.",
        "",
        "The theme you chose: %s" % (theme or "no particular theme"),
        "The songs, in order: %s" % listing,
    ]
    if state["index"] == 0:
        lines.append("This is you signing on for the session, so welcome them "
                     "as well.")
    lines += [
        "",
        "Speak %s. One or two sentences, under 45 words. No emoji, no "
        "formatting, and do not read the list out like an index: name at most "
        "two of the songs, and only ones from the list above."
        % dj.LANGUAGE_NAMES.get(language, "in English"),
        "Never state release dates, chart positions, awards or anything else "
        "you would have to look up. Talk about how it sounds and where it "
        "takes them.",
        "Reply with the words you say and nothing else.",
    ]
    return "\n".join(lines)


# ------------------------------------------------------------------ building


def _lookup(engine, visitor, song):
    """One proposal, as a search. Shared with the station's own lookup cache,
    so a song either side already found costs nothing here."""
    query = ("%s %s" % (song["artist"], song["title"])).strip()
    return discovery._memo("s:" + query,
                           lambda: rec.search_song(query, visitor,
                                                   engine.cookie))


def _comfort(engine):
    """What counts as already-theirs: artists they play, songs they own.

    Both come from the taste profile. The artists are the comfort zone the set
    is supposed to step outside of; the songs are the ones that must not come
    back at all, because being played your own favourites is the thing that
    makes a station feel like it is not listening.
    """
    taste = getattr(engine, "taste", None)
    familiar = set(getattr(taste, "artists", None) or ())
    known = set(getattr(taste, "known", None) or ())
    return familiar, known


def _resolve(engine, state, songs, want):
    """Look the proposals up together and take the first few that survive.

    Order matters: the model was told to put its strongest choices first, so
    the spares behind them are only reached for when something ahead of them
    was fictional, already played, or the same recording under another name.
    Nothing past the ones taken is marked as seen - a song not needed today
    should still be available tomorrow.

    Two passes over the same candidates. The first holds the line on how much
    of a set may come from artists the listener already plays, which is where
    the model drifts back to whatever it can see in the profile. The second
    gives that line up, because a set of two songs is worse than a set with one
    familiar name too many - and only reaches for it when the first pass came
    up short.
    """
    visitor = engine.visitor()
    futures = [_lookup_pool.submit(_lookup, engine, visitor, q) for q in songs]
    found = []
    for future in futures:
        try:
            track = future.result(timeout=25)
        except Exception:  # noqa: BLE001
            continue
        if track:
            found.append(track)

    familiar, known = _comfort(engine)
    served = _served_keys()
    out, artists, close_to_home = [], set(), 0
    with state["lock"]:
        for strict in (True, False):
            for track in found:
                if len(out) >= want:
                    break
                key = rec.identity(track)
                artist = rec.primary_artist(track.get("artist"))
                if (track["videoId"] in state["seen_ids"]
                        or key in state["seen_keys"]
                        or artist in artists
                        or key in known
                        or key in served
                        or engine.learned.is_rejected(key)):
                    continue
                near = artist in familiar
                if strict and near and close_to_home >= FAMILIAR_PER_SET:
                    continue
                state["seen_ids"].add(track["videoId"])
                state["seen_keys"].add(key)
                artists.add(artist)
                if near:
                    close_to_home += 1
                out.append(track)
            if len(out) >= want:
                break
    return out


def _backfill(engine, state, tracks, want):
    """Top a short set up from the station of the song that did survive.

    The model cannot always name four songs that all exist, are all new to this
    listener and are all by different artists - especially deep into a session,
    where most of what fits the taste profile has already been played. Rather
    than hand over a one-song set, the rest comes from YouTube Music's own
    radio for the first track, which is at least demonstrably adjacent to it.
    The theme is honest about the songs it chose; the tail is a neighbour.
    """
    if not tracks or len(tracks) >= want:
        return tracks

    seed = tracks[0]["videoId"]
    visitor = engine.visitor()
    try:
        nearby = discovery._memo(
            "r:" + seed,
            lambda: rec.radio(seed, visitor, engine.cookie, limit=20))
    except Exception:  # noqa: BLE001
        return tracks

    familiar, known = _comfort(engine)
    served = _served_keys()
    artists = {rec.primary_artist(t.get("artist")) for t in tracks}
    with state["lock"]:
        # Two passes, strangers first. A radio is ranked by how close each
        # track sits to its seed, so the artists this listener already plays
        # come out at the top of it - taking them in the order offered would
        # quietly undo the set. They are still better than a short set, so the
        # second pass has them; it just does not reach for them first.
        for strict in (True, False):
            for track in nearby or []:
                if len(tracks) >= want:
                    break
                key = rec.identity(track)
                artist = rec.primary_artist(track.get("artist"))
                if (track["videoId"] in state["seen_ids"]
                        or key in state["seen_keys"]
                        or artist in artists
                        or key in known
                        or key in served
                        or engine.learned.is_rejected(key)):
                    continue
                if strict and artist in familiar:
                    continue
                state["seen_ids"].add(track["videoId"])
                state["seen_keys"].add(key)
                artists.add(artist)
                tracks.append(track)
            if len(tracks) >= want:
                break
    return tracks


def _build(engine, state, language, model):
    """One turn of the loop, start to finish: plan it, find it, then talk
    about what was actually found."""
    cfg = discovery._ai_config()
    if not cfg:
        return {"error": "no AI endpoint configured (ai.env missing)"}

    try:
        raw = discovery._ask_model(cfg, _ask(engine, state, language),
                                   model or dj.MODEL,
                                   max_tokens=800, timeout=60)
        plan = _parse(raw)
    except Exception as e:  # noqa: BLE001
        return {"error": "could not plan the set: %s" % str(e)[:200]}

    tracks = _resolve(engine, state, plan["songs"], SET_SIZE)
    tracks = _backfill(engine, state, tracks, SET_SIZE)
    if not tracks:
        return {"error": "none of the songs could be found"}

    # Neither writing the line nor speaking it is worth losing a set over, so
    # both failures come back as a set that simply does not talk.
    script, audio, trouble = "", None, None
    if plan["say"]:
        prompt = _script_prompt(state, plan["theme"], tracks, language)
        try:
            script = dj._tidy(discovery._ask_model(cfg, prompt,
                                                   model or dj.MODEL,
                                                   max_tokens=300, timeout=45))
        except Exception as e:  # noqa: BLE001
            trouble = "could not write the line: %s" % str(e)[:160]
    if script:
        try:
            audio = dj.voice_over(script, language)
        except Exception as e:  # noqa: BLE001
            trouble = "could not speak it: %s" % str(e)[:160]

    return {
        "theme": plan["theme"],
        "say": bool(script),
        "script": script,
        "audio": audio,
        "tracks": tracks,
        "error": trouble,
    }


def _commit(state, built):
    """Record a set as played, so the next turn knows about it - and so does
    the next station, which is what the ledger is for."""
    _note_served(built.get("tracks"))
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


# ------------------------------------------------------------------- warming


# Languages somebody has actually listened in, remembered across restarts so a
# fresh process warms the right ones rather than guessing.
LANGS_STATE = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                           ".djset_langs.json")
READY_TTL = 60 * 25
WARM_INTERVAL = 60 * 20

_ready = {}
_ready_guard = threading.Lock()
_warming = set()
_wanted = set()
_warm_thread = None


def _load_wanted():
    try:
        with open(LANGS_STATE, encoding="utf-8") as fh:
            for tag in json.load(fh) or []:
                if isinstance(tag, str):
                    _wanted.add(tag)
    except Exception:  # noqa: BLE001
        pass


def _remember_language(language):
    if language in _wanted:
        return
    _wanted.add(language)
    try:
        tmp = LANGS_STATE + ".tmp"
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(sorted(_wanted), fh)
        os.replace(tmp, LANGS_STATE)
    except Exception:  # noqa: BLE001
        pass


def _prewarm(engine, language, model=None):
    """Build an opening set before anybody asks for one.

    Every set after the first already arrives from the background, because the
    one before it started building the moment it was handed over. The first set
    has nothing in front of it, and it is the one the listener is actually
    waiting on - they press play and the station says nothing for twenty
    seconds. So one opening set stands by at all times.
    """
    with _ready_guard:
        if language in _warming:
            return False
        _warming.add(language)
    try:
        engine.taste.refresh()
        scratch = _new_state(language, register=False)
        built = _build(engine, scratch, language, model)
        if not built.get("tracks"):
            return False
        with _ready_guard:
            _ready[language] = {"state": scratch, "built": built,
                                "at": time.time()}
        return True
    finally:
        with _ready_guard:
            _warming.discard(language)


def _take_ready(language):
    """The opening set standing by for this language, if it is still fresh."""
    now = time.time()
    with _ready_guard:
        entry = _ready.pop(language, None)
    if not entry or now - entry["at"] > READY_TTL:
        return None
    return entry


def start_auto_warm(engine, model=None, interval=None):
    """Keep an opening set standing by for every language in use.

    Same shape as the home page rebuild, and for the same reason: the work is
    half a minute of model and network round trips, so it happens on the
    server's own schedule instead of in front of somebody.
    """
    global _warm_thread
    if _warm_thread and _warm_thread.is_alive():
        return
    period = interval or WARM_INTERVAL
    _load_wanted()

    def loop():
        while True:
            for language in sorted(_wanted):
                with _ready_guard:
                    entry = _ready.get(language)
                if entry and time.time() - entry["at"] < period:
                    continue
                try:
                    _prewarm(engine, language, model)
                except Exception:  # noqa: BLE001
                    pass
            # Short poll: a set taken by a listener should be replaced within
            # the minute, not at the end of the rebuild period.
            time.sleep(60)

    _warm_thread = threading.Thread(target=loop, daemon=True)
    _warm_thread.start()


# -------------------------------------------------------------------- public


def next_set(engine, session_id=None, language=None, skipped=(), liked=(),
             model=None):
    """The next themed mini-set, with its commentary already spoken.

    Pass the session id back on every call. Pass what was skipped and what was
    played through since the last one; both change what comes next.
    """
    language = dj.normalise_language(language)
    _remember_language(language)

    state = _find(session_id)
    # A set built before this listener arrived, if one is standing by. Nothing
    # about it is personal to a session - it is the first set of a station that
    # had not been started yet, which is exactly what is being asked for.
    opening = _take_ready(language) if state is None else None
    if opening is not None:
        state = _adopt(opening["state"])
    elif state is None:
        state = _new_state(language)
    state["language"] = language
    engine.taste.refresh()

    fresh_skips = _feedback(state, skipped, liked)

    built = opening["built"] if opening is not None else None
    ahead = state.pop("ahead", None)
    if built is None and ahead is not None:
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
