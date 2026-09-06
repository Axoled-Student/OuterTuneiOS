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

Most of a set is music the listener already loves, and some of it is not, and
both halves have to be forced. A model handed a list of somebody's favourites
and asked what to play next hands the favourites straight back, so discovery
needs a slot held open for it. A model told to stay off the favourites returns
a set of strangers, which is not a station either - it is a stranger reading
out a list. So the profile arrives as three lists rather than one: who they
love, what they have on right now, and what they loved once and have not put
on in months. Roughly two thirds of what plays is theirs, drawn from further
down that profile than the songs they are already playing on their own, and at
least one name per set is somebody they have never heard. The balance is
enforced twice, once in the asking and once in the picking, because a model
given a ratio keeps to it about as well as it keeps to anything else.

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
# A DJ plays you music you love. Spotify's aims for roughly two thirds already
# familiar and one third new, and draws the familiar part from across your
# history rather than off the top of it - "old favourites you may have
# forgotten" is how they put it. Holding discovery to one name per set was the
# first mistake; holding it to three was the opposite one, and a station of
# strangers is not a station. So most of a set is theirs, at least one slot is
# always somebody new, and the familiar part comes from further down the
# profile than the five songs they are already playing on their own.
FAMILIAR_PER_SET = 3
STRANGERS_PER_SET = 1
# A cap only stops the set going too far one way. With a cap and a slot held
# for discovery and nothing else, six live sets came back 54% familiar: inside
# the letter of the rule and outside the point of it, because nothing ever
# obliged the model's strangers to give a slot back. So the familiar side is
# reserved the same way the discovery slot is - under the floor, a stranger is
# passed over and the gap is filled from their own artists instead.
FAMILIAR_MIN = 2
# Songs already in their library, as opposed to other songs by artists they
# play. Worth hearing - a DJ that never plays anything you own is a stranger
# reading out a list - but they can put these on themselves, so they stay a
# minority of the set.
OWNED_PER_SET = 2
# How many older favourites the prompt surfaces per set, rotating, so the
# familiar half is familiar without being the same four titles every time.
DEEP_CUTS = 10
# How much history the prompt carries. Everything played is blocked from
# repeating regardless; this is only what the model is shown.
RECENT_SHOWN = 24

_sessions = {}
_sessions_guard = threading.Lock()
# Which slice of the old favourites the next new station opens on. Every
# station starts at set one, so without this every station opens on the same
# slice of the profile - and once most of a set is meant to be music they
# already love, that means two stations opened minutes apart open with the
# same three names.
_rotation = 0

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
# Long enough that stations opened minutes or hours apart never repeat, which
# is what this was for. Not longer: most of a set is now meant to be music they
# already love, and a three-day block eats through the familiar half of the
# profile faster than it refills, which quietly forces the station back to
# strangers. A favourite should be able to come round again tomorrow.
SERVED_TTL = 60 * 60 * 24
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
    global _rotation
    now = time.time()
    with _sessions_guard:
        _rotation += 1
        rotation = _rotation
    state = {
        "id": uuid.uuid4().hex[:12],
        "language": language,
        "index": 0,              # sets handed over so far
        "rotation": rotation,    # where in the old favourites this one opens
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


def _profile(engine, offset=0):
    """The three things a DJ knows about you: who you love, what you have on
    right now, and what you loved once and have not put on in months.

    Split up because a model shown only the top of a profile picks off the top
    of a profile, which is how a station ends up handing somebody their own
    five favourite songs back. The third bucket rotates on `offset`, so the
    familiar part of consecutive sets is drawn from different places in it.
    """
    top = [a for a, _ in sorted(engine.taste.artists.items(),
                                key=lambda kv: -kv[1])[:12]]
    tracks = list(engine.taste.tracks)
    loved = ["%s - %s" % (t["artist"], t["name"]) for t in tracks[:8]]
    deep, buried = tracks[8:], []
    if deep:
        start = (offset * DEEP_CUTS) % len(deep)
        rows = [deep[(start + n) % len(deep)]
                for n in range(min(DEEP_CUTS, len(deep)))]
        buried = ["%s - %s" % (t["artist"], t["name"]) for t in rows]
    return top, loved, buried


def _ask(engine, state, language):
    """One prompt for the whole turn: theme, songs, and whether to speak."""
    top, loved, buried = _profile(
        engine, state["index"] + state.get("rotation", 0))
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

    # Three headings rather than one. Handed a single list of songs somebody
    # loves, the model hands that list straight back - which is what "it keeps
    # picking the same songs I like" was. Naming the buckets apart lets the
    # rule below point at one of them in particular.
    if top:
        lines.append("Artists they love: %s." % ", ".join(top))
    if loved:
        lines.append("On heavy rotation right now: %s." % "; ".join(loved))
    if buried:
        lines.append("Loved once, not played in a while: %s."
                     % "; ".join(buried))
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
        "Build it the way a radio DJ would rather than the way a "
        "recommender would: mostly music they already love, with room for "
        "something new. Most of your list - five or six of them - must be "
        "artists from the lists above, and reach for what they loved once and "
        "have not played in a while before what is already on heavy rotation, "
        "because they can put that on themselves. The rest must be artists "
        "they have never played, standing right next to their taste rather "
        "than far from it.",
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


def _floor(want):
    """How many of a set must be theirs - never so many that the slot held for
    discovery has nowhere left to go. That matters for the short sets the
    top-up asks about, where two of theirs plus one stranger is already more
    than the set has room for."""
    return min(FAMILIAR_MIN, max(0, want - STRANGERS_PER_SET))


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


class _Balance:
    """The shape a set is meant to end up in, kept as it fills.

    Mostly artists they already love, never all of them, some of it from their
    own library, and always at least one name they have never played.

    It is an object because the same balance has to survive two different
    pools - the model's proposals and the radio standing behind them - filling
    the same set. Counting each pool on its own was how the top-up used to
    undo the balance the first pass had just struck.
    """

    def __init__(self, want, familiar, known):
        self.want = want
        self.familiar = familiar
        self.known = known
        self.floor = _floor(want)
        self.near = self.owned = self.strangers = 0

    def _near(self, track):
        return rec.primary_artist(track.get("artist")) in self.familiar

    def fits(self, track, taken, strict):
        """Whether this track can have the next slot.

        Slots are held open at both ends. Without a floor a run of strangers
        fills the set and the station stops being theirs - six live sets came
        back 54% familiar that way. Without the reservation at the other end a
        good run of favourites fills it before discovery reaches a single
        slot, which is how "mostly what you love" quietly becomes "only what
        you love".

        The relaxed pass gives all of it up, because a set of two songs is
        worse than a set weighted wrong. What makes that safe is the order the
        pools are worked in: by the time anything is asked with `strict` off,
        the radio has already had its chance at the slots being held.
        """
        if not strict:
            return True
        near = self._near(track)
        left = self.want - taken
        if not near and left <= self.floor - self.near:
            return False
        if near and self.near >= FAMILIAR_PER_SET:
            return False
        if rec.identity(track) in self.known and self.owned >= OWNED_PER_SET:
            return False
        if near and left <= STRANGERS_PER_SET - self.strangers:
            return False
        return True

    def add(self, track):
        if self._near(track):
            self.near += 1
        else:
            self.strangers += 1
        if rec.identity(track) in self.known:
            self.owned += 1


def _take(engine, state, candidates, tracks, balance, strict):
    """Move candidates into the set, in order, for as long as they fit.

    Only what is taken is marked as seen. A song passed over today - because
    the set was full, or because it was the wrong side of the balance - should
    still be there to play tomorrow.
    """
    served = _served_keys()
    artists = {rec.primary_artist(t.get("artist")) for t in tracks}
    with state["lock"]:
        for track in candidates or []:
            if len(tracks) >= balance.want:
                break
            key = rec.identity(track)
            artist = rec.primary_artist(track.get("artist"))
            if (track["videoId"] in state["seen_ids"]
                    or key in state["seen_keys"]
                    or artist in artists
                    or key in served
                    or engine.learned.is_rejected(key)):
                continue
            if not balance.fits(track, len(tracks), strict):
                continue
            state["seen_ids"].add(track["videoId"])
            state["seen_keys"].add(key)
            artists.add(artist)
            balance.add(track)
            tracks.append(track)
    return tracks


def _nearby(engine, tracks, cache):
    """YouTube Music's own station for the first song that survived.

    The model cannot always name four songs that all exist, are all new to
    this listener and are all by different artists - especially deep into a
    session, where most of what fits the taste profile has already been
    played. This is where the rest comes from: demonstrably adjacent to
    something the set already contains, rather than invented.

    It is also where the familiar half is found when the model has not
    supplied one. A radio is ranked by how close each track sits to its seed,
    so the artists this listener already plays come out at the top of it.
    """
    if not tracks:
        return []
    if "rows" not in cache:
        seed = tracks[0]["videoId"]
        try:
            cache["rows"] = discovery._memo(
                "r:" + seed,
                lambda: rec.radio(seed, engine.visitor(), engine.cookie,
                                  limit=20)) or []
        except Exception:  # noqa: BLE001
            cache["rows"] = []
    return cache["rows"]


def _resolve(engine, state, songs, want):
    """Look the proposals up together and build the set out of what survives.

    Order matters twice over. Within a pool it is the model's: it was told to
    put its strongest choices first, so the spares behind them are only
    reached for when something ahead of them was fictional, already played, or
    the same recording under another name.

    Across pools it is the balance's. The proposals get first refusal under
    the full rules; then the radio behind them, still under the full rules,
    because that is where a familiar name is certain to be found when the
    model did not offer one; and only then does either pool get to fill what
    is left with the rules off. Putting the radio after both relaxed passes -
    which is what a separate top-up function amounted to - meant the slots
    being held for artists they love were handed to the strangers that had
    just been passed over for them.
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
    balance = _Balance(want, familiar, known)
    tracks, radio = [], {}
    for strict in (True, False):
        _take(engine, state, found, tracks, balance, strict)
        if len(tracks) >= want:
            break
        # No radio is fetched at all when the model delivered a balanced set,
        # which is the common case and the one worth keeping cheap.
        _take(engine, state, _nearby(engine, tracks, radio), tracks, balance,
              strict)
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


def _overtaken(entry):
    """Whether a station has played this standby set out from under it.

    A set standing by was built against the ledger as it stood at the time. If
    a station has run since - and one usually has, because that is what the
    listener was doing while this was being built - the songs it chose may
    have gone out already. Handing it over then opens the new station with
    what the last one just finished, which is the one thing the ledger exists
    to prevent.
    """
    served = _served_keys()
    return any(rec.identity(t) in served
               for t in entry["built"].get("tracks") or ())


def _retire_overtaken(language):
    """Drop an overtaken standby set so the warm loop replaces it.

    Left in place it would sit there until its rebuild came round, and every
    station opened in the meantime would find it, reject it, and wait out a
    build from scratch.
    """
    with _ready_guard:
        entry = _ready.get(language)
    if entry and _overtaken(entry):
        with _ready_guard:
            if _ready.get(language) is entry:
                _ready.pop(language, None)


def _take_ready(language):
    """The opening set standing by for this language, if it is still fresh -
    and if no station has played its songs while it stood there."""
    now = time.time()
    with _ready_guard:
        entry = _ready.pop(language, None)
    if not entry or now - entry["at"] > READY_TTL:
        return None
    if _overtaken(entry):
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
    _retire_overtaken(language)

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
