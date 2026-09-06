"""Timed lyrics, and a translation of them, resolved server side.

The app used to call lrclib itself and print the reply verbatim. That left two
problems this module exists to solve.

The first is matching. lrclib's search is loose: `search?track_name=...` for a
YouTube title like "アイドル (Official Music Video)" returns nothing, while the
cleaned title returns twenty hits of which only some are time-tagged. Picking
well needs a few attempts and a duration comparison, and doing that on the
phone means shipping a build every time the heuristic changes.

The second is translation, which needs a model, and the model key lives here -
not on the phone. Translating is also expensive enough (about 7s for six lines)
that it must be cached, and this machine is the only place with a disk to cache
it on that every device shares.

Everything is keyed on (title, artist, duration bucket), so the second listener
to open the same song pays nothing.
"""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

LRCLIB = "https://lrclib.net/api/"
# lrclib asks clients to identify themselves rather than send a browser UA.
UA = ("OuterTuneiOS-resolver/1.0 "
      "(https://github.com/Axoled-Student/OuterTuneiOS)")

CACHE_DIR = pathlib.Path(__file__).resolve().parents[2] / "build" / "lyrics_cache"
# Lyrics do not change. This TTL only exists so a track that had no transcript
# when it was new gets looked at again later.
CACHE_TTL = 60 * 60 * 24 * 30
MISS_TTL = 60 * 60 * 12
# Bumped whenever the shape of an entry, or the meaning of a field in it,
# changes: an older file is refetched rather than misread.
CACHE_VERSION = 2

# Lines per model request. Small enough that one bad reply costs little and
# that the chunks can run at the same time; large enough that the model still
# sees the surrounding verse and can keep pronouns and tense consistent.
CHUNK_LINES = 32
TRANSLATE_MODEL = "gemini-3.8-flash-high"

# Chunks of one song translate side by side here. The whole-song jobs run in
# their own pool: sharing one would let a few queued songs occupy every worker
# and leave the chunks they are waiting on with nowhere to run.
_pool = concurrent.futures.ThreadPoolExecutor(max_workers=6,
                                              thread_name_prefix="lyrics")
_job_pool = concurrent.futures.ThreadPoolExecutor(max_workers=2,
                                                  thread_name_prefix="lyricsjob")
# One in-flight translation per cache key: opening the same song on two devices
# should not pay the model twice.
_locks = {}
_locks_guard = threading.Lock()
_pending = set()
_pending_guard = threading.Lock()


def _lock_for(key):
    with _locks_guard:
        lock = _locks.get(key)
        if lock is None:
            lock = threading.Lock()
            _locks[key] = lock
        return lock


# ------------------------------------------------------------------ fetching


def _http_json(path, params, timeout=15):
    url = LRCLIB + path + "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(url, headers={"User-Agent": UA})
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.loads(response.read().decode("utf-8"))


# YouTube titles carry a trailer that lrclib has never heard of.
_NOISE = re.compile(
    r"\s*[\(\[（【][^\)\]）】]*"
    r"(official|music\s*video|mv|m/v|audio|lyric|lyrics|visualizer|"
    r"live|performance|ver\.?|version|remaster(ed)?|hd|4k|"
    r"歌詞|動畫|完整版)"
    r"[^\)\]）】]*[\)\]）】]",
    re.IGNORECASE)
# The credit may or may not be bracketed; either way it runs to the end.
_FEAT = re.compile(r"\s*[\(\[（【]?\s*(feat\.?|ft\.?|featuring)\s+.*$",
                   re.IGNORECASE)
_TRAILING = re.compile(r"\s*[-–|/]\s*(topic|official.*|lyrics?.*)$",
                       re.IGNORECASE)


def clean_title(title):
    text = _NOISE.sub("", title or "")
    text = _FEAT.sub("", text)
    text = _TRAILING.sub("", text)
    return text.strip(" -–　") or (title or "").strip()


def clean_artist(artist):
    # "YOASOBI, Ikura" / "YOASOBI & Ikura" - lrclib indexes the lead only.
    text = _TRAILING.sub("", artist or "")
    text = re.split(r"\s*[,&，、]\s*|\s+x\s+", text)[0]
    return text.strip() or (artist or "").strip()


def _score(candidate, duration):
    """Prefer time-tagged, then the closest running time."""
    synced = 1 if candidate.get("syncedLyrics") else 0
    if not duration:
        return (synced, 0)
    gap = abs(float(candidate.get("duration") or 0) - float(duration))
    # Anything inside five seconds is the same recording as far as the
    # timestamps are concerned; beyond that the offsets visibly drift.
    return (synced, -gap)


def _search(title, artist, duration):
    attempts = []
    if title:
        attempts.append({"track_name": title, "artist_name": artist or ""})
        if artist:
            attempts.append({"track_name": title})
        if clean_title(title) != title:
            attempts.append({"track_name": clean_title(title),
                             "artist_name": clean_artist(artist) or ""})
    if title or artist:
        attempts.append({"q": ("%s %s" % (clean_artist(artist),
                                          clean_title(title))).strip()})

    for params in attempts:
        try:
            rows = _http_json("search", params)
        except Exception:  # noqa: BLE001  - a miss is not an error here
            continue
        rows = [r for r in rows or [] if isinstance(r, dict)]
        rows = [r for r in rows if r.get("syncedLyrics") or r.get("plainLyrics")]
        if not rows:
            continue
        return max(rows, key=lambda r: _score(r, duration))
    return None


# ----------------------------------------------------------------- parsing


_STAMP = re.compile(r"\[(\d+):(\d+(?:[.:]\d+)?)\]")


def parse_lrc(raw):
    """LRC text -> [{"t": seconds, "text": str}], sorted, tags dropped."""
    out = []
    for line in (raw or "").split("\n"):
        stamps = []
        cursor = 0
        while True:
            match = _STAMP.match(line, cursor)
            if not match:
                break
            minutes = int(match.group(1))
            seconds = float(match.group(2).replace(":", "."))
            stamps.append(minutes * 60 + seconds)
            cursor = match.end()
        if not stamps:
            continue
        text = line[cursor:].strip()
        for stamp in stamps:
            out.append({"t": round(stamp, 2), "text": text})
    out.sort(key=lambda row: row["t"])
    return out


# Script ranges are enough to answer the only question that matters here:
# would translating into the requested language be a no-op?
_RANGES = (
    ("ja", ((0x3040, 0x30FF),)),          # kana; kanji alone is ambiguous
    ("ko", ((0xAC00, 0xD7AF), (0x1100, 0x11FF))),
    ("zh", ((0x4E00, 0x9FFF), (0x3400, 0x4DBF))),
    ("ru", ((0x0400, 0x04FF),)),
    ("ar", ((0x0600, 0x06FF),)),
    ("th", ((0x0E00, 0x0E7F),)),
)


def detect_language(text):
    counts = {}
    latin = 0
    for char in text or "":
        code = ord(char)
        if 0x41 <= code <= 0x5A or 0x61 <= code <= 0x7A:
            latin += 1
            continue
        for name, ranges in _RANGES:
            if any(low <= code <= high for low, high in ranges):
                counts[name] = counts.get(name, 0) + 1
                break
    if not counts and latin:
        return "en"
    if not counts:
        return None
    # Kana outranks han: Japanese lyrics are mostly kanji by character count,
    # but any kana at all settles the question.
    if counts.get("ja", 0) >= 4:
        return "ja"
    best = max(counts.items(), key=lambda item: item[1])[0]
    return han_script(text) if best == "zh" else best


# Characters whose simplified and traditional forms differ, common enough that
# a few lines of any lyric will contain several. This is what separates a
# transcript that is already what the listener reads from one that needs
# converting - "zh" on its own cannot answer that.
_SIMPLIFIED = set("们这说时会后国门车长马华爱无与见学现样电开关东网还让过来对应觉记谁边"
                    "远头图声义风龙飞点虽双发买卖谢语话读书写从飘荡万众专业丝严个临为举乌"
                    "乐习乡乱争云亚产亲亿仅仓仪优传伤体余儿内决冲净减击则刚创剑劝动务劳势"
                    "医单卫厂历压厅县参变叶号吗员响团园圆场坏块坚墙壮处备够夹夺奋奖妇妈孙"
                    "宁宝实审宽寻导尔尘尝尽层属岁岛币师帮带庆库废异张弯归当录忆态总恋恶惊"
                    "惯愿战户执扩扫扬担择挥换据数断显术机杂权条杨极构标树桥检楼欢欧残毁毕"
                    "气汉汤没泪洁测济湾湿满滚灭灯灵灾热爷状独猫环画疗疯盘码确础礼离种积称"
                    "稳穷竞笔简类紧红约级纪纯纳纸线练组细织终经结绕给络绝统继续绿编缘缩罗"
                    "罚联肠脑脸舰艰艺节苏药获蓝虑补装观规触计认讨训议讲许论设访证评识诉词"
                    "译试诗诚该详误请课调谈谋谎贝负财责败货质购贴贵费资赏赢赶转轮软载输辞"
                    "达迁运进连迟适选递遗邮释钟钢钱铁铃银销锁错键镜闭问间闻阅队阶阳阴际陆"
                    "陈险随隐难韩页顶项顺须顾预领频题颜额饭饮饿馆驾骑验鱼鲜鸟鸡鸣麦齐齿龄"
                    "龟")
_TRADITIONAL = set("們這說時會後國門車長馬華愛無與見學現樣電開關東網還讓過來對應覺記誰邊"
                     "遠頭圖聲義風龍飛點雖雙發買賣謝語話讀書寫從飄蕩萬眾專業絲嚴個臨為舉烏"
                     "樂習鄉亂爭雲亞產親億僅倉儀優傳傷體餘兒內決沖淨減擊則剛創劍勸動務勞勢"
                     "醫單衛廠歷壓廳縣參變葉號嗎員響團園圓場壞塊堅牆壯處備夠夾奪奮獎婦媽孫"
                     "寧寶實審寬尋導爾塵嘗盡層屬歲島幣師幫帶慶庫廢異張彎歸當錄憶態總戀惡驚"
                     "慣願戰戶執擴掃揚擔擇揮換據數斷顯術機雜權條楊極構標樹橋檢樓歡歐殘毀畢"
                     "氣漢湯沒淚潔測濟灣濕滿滾滅燈靈災熱爺狀獨貓環畫療瘋盤碼確礎禮離種積稱"
                     "穩窮競筆簡類緊紅約級紀純納紙線練組細織終經結繞給絡絕統繼續綠編緣縮羅"
                     "罰聯腸腦臉艦艱藝節蘇藥獲藍慮補裝觀規觸計認討訓議講許論設訪證評識訴詞"
                     "譯試詩誠該詳誤請課調談謀謊貝負財責敗貨質購貼貴費資賞贏趕轉輪軟載輸辭"
                     "達遷運進連遲適選遞遺郵釋鐘鋼錢鐵鈴銀銷鎖錯鍵鏡閉問間聞閱隊階陽陰際陸"
                     "陳險隨隱難韓頁頂項順須顧預領頻題顏額飯飲餓館駕騎驗魚鮮鳥雞鳴麥齊齒齡"
                     "龜")


def han_script(text):
    """`zh-Hans` or `zh-Hant` for Chinese text, by counting divergent forms."""
    simplified = sum(1 for char in text or "" if char in _SIMPLIFIED)
    traditional = sum(1 for char in text or "" if char in _TRADITIONAL)
    if simplified == traditional:
        # Nothing divergent appeared. Traditional is the safer default: it is
        # what the app's own interface is written in.
        return "zh-Hant"
    return "zh-Hans" if simplified > traditional else "zh-Hant"


LANGUAGE_NAMES = {
    "zh-hant": "繁體中文",
    "zh-tw": "繁體中文",
    "zh-hk": "繁體中文",
    "zh-hans": "简体中文",
    "zh-cn": "简体中文",
    "zh": "繁體中文",
    "ja": "日本語",
    "ko": "한국어",
    "en": "English",
    "es": "español",
    "fr": "français",
    "de": "Deutsch",
    "th": "ไทย",
    "vi": "Tiếng Việt",
}


def normalise_target(tag):
    """`zh-Hant-TW` -> `zh-Hant`; anything unknown keeps its base tag."""
    if not tag:
        return None
    parts = str(tag).replace("_", "-").split("-")
    base = parts[0].lower()
    if base == "zh":
        for part in parts[1:]:
            lowered = part.lower()
            if lowered in ("hant", "tw", "hk", "mo"):
                return "zh-Hant"
            if lowered in ("hans", "cn", "sg"):
                return "zh-Hans"
        return "zh-Hant"
    return base


def language_name(tag):
    return LANGUAGE_NAMES.get((tag or "").lower(), tag or "English")


def _same_language(source, target):
    """Would translating be a no-op?

    Chinese is compared at full tag width: a simplified transcript in front of
    a listener who reads traditional is worth converting, and the model does
    that in the same pass it would translate anything else.
    """
    if not source or not target:
        return False
    source, target = source.lower(), target.lower()
    if source.startswith("zh") and target.startswith("zh"):
        return source == target
    return source.split("-")[0] == target.split("-")[0]


# -------------------------------------------------------------- translating


PROMPT = (
    "Translate these song lyric lines into %(language)s.\n"
    "Return ONLY a JSON array of exactly %(count)d strings, one per input "
    "line, in the same order. Natural, singable phrasing that reads as a "
    "lyric - not word for word. Keep a line that is already %(language)s "
    "unchanged. Never merge, split, reorder or drop a line; a line that is "
    "only a sound effect, a count-in or an ad-lib becomes an empty string.\n\n"
    "%(lines)s")


def _parse_array(raw, count):
    body = (raw or "").strip()
    if "```" in body:
        part = body.split("```")[1]
        body = part[4:] if part.startswith("json") else part
    start, end = body.find("["), body.rfind("]")
    if start == -1 or end == -1:
        return None
    try:
        rows = json.loads(body[start:end + 1])
    except ValueError:
        return None
    if not isinstance(rows, list) or len(rows) != count:
        return None
    return ["" if row is None else str(row).strip() for row in rows]


def _translate_chunk(cfg, texts, language, model):
    prompt = PROMPT % {
        "language": language,
        "count": len(texts),
        "lines": "\n".join("%d. %s" % (i + 1, t or "—")
                           for i, t in enumerate(texts)),
    }
    import discovery

    for attempt in range(2):
        try:
            # Low temperature: this is a translation, and the model wandering
            # off into its own imagery is the failure mode to avoid.
            raw = discovery._ask_model(cfg, prompt, model=model, timeout=120,
                                       max_tokens=4000, temperature=0.3)
        except Exception:  # noqa: BLE001
            continue
        rows = _parse_array(raw, len(texts))
        if rows is not None:
            return rows
        # A reply of the wrong length is worse than none: it would put every
        # following translation against the wrong line. Retry once, then give
        # the chunk up rather than guess at the alignment.
        if attempt == 0:
            time.sleep(0.5)
    return None


def translate_lines(texts, target, model=None):
    """Translations aligned 1:1 with `texts`; None for any chunk that failed."""
    import discovery

    cfg = discovery._ai_config()
    if not cfg or not texts:
        return None

    language = language_name(target)
    model = model or TRANSLATE_MODEL
    chunks = [texts[i:i + CHUNK_LINES]
              for i in range(0, len(texts), CHUNK_LINES)]
    results = list(_pool.map(
        lambda chunk: _translate_chunk(cfg, chunk, language, model), chunks))

    out = []
    produced = 0
    for chunk, rows in zip(chunks, results):
        if rows is None:
            out.extend([None] * len(chunk))
        else:
            out.extend(rows)
            produced += 1
    return out if produced else None


# ------------------------------------------------------------------ caching


def _key(title, artist, duration):
    # Bucket the duration: the same recording is reported a second or two apart
    # by different sources, and each bucket should not be a separate cache miss.
    bucket = int(round(float(duration or 0) / 5.0))
    raw = "%s|%s|%d" % (clean_title(title).lower(),
                        clean_artist(artist).lower(), bucket)
    return hashlib.sha1(raw.encode("utf-8")).hexdigest()[:20]


def _cache_path(key):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return CACHE_DIR / (key + ".json")


def _read_cache(key):
    path = _cache_path(key)
    try:
        with open(path, encoding="utf-8") as handle:
            entry = json.load(handle)
    except (OSError, ValueError):
        return None
    if entry.get("v") != CACHE_VERSION:
        return None
    age = time.time() - float(entry.get("fetched") or 0)
    ttl = CACHE_TTL if entry.get("lines") or entry.get("plain") else MISS_TTL
    if age > ttl:
        return None
    return entry


def _write_cache(key, entry):
    path = _cache_path(key)
    temp = str(path) + ".tmp"
    try:
        with open(temp, "w", encoding="utf-8") as handle:
            json.dump(entry, handle, ensure_ascii=False)
        os.replace(temp, path)
    except OSError:
        pass


# -------------------------------------------------------------------- public


def _texts_of(entry):
    lines = entry.get("lines") or []
    if lines:
        return [row["text"] for row in lines]
    return (entry.get("plain") or "").split("\n")


def _run_translation(key, target, model):
    """Translate whatever is cached under `key` and store it. Runs off-thread."""
    try:
        entry = _read_cache(key)
        if not entry:
            return
        produced = translate_lines(_texts_of(entry), target, model=model)
        if not produced:
            return
        with _lock_for(key):
            # Re-read: the fetch path may have rewritten the file meanwhile.
            current = _read_cache(key) or entry
            translations = current.get("translations") or {}
            translations[target] = produced
            current["translations"] = translations
            _write_cache(key, current)
    finally:
        with _pending_guard:
            _pending.discard((key, target))


def _start_translation(key, target, model):
    """True if a translation is now running (or already was)."""
    with _pending_guard:
        if (key, target) in _pending:
            return True
        _pending.add((key, target))
    try:
        _job_pool.submit(_run_translation, key, target, model)
    except RuntimeError:  # pool shut down
        with _pending_guard:
            _pending.discard((key, target))
        return False
    return True


def get(title, artist, duration=None, target=None, model=None, wait=False):
    """Lyrics for one track, with a translation when one is worth making.

    The transcript is never held up by the model. A translation that is not
    cached yet is started in the background and the reply says `translating`,
    so the app can show the words immediately and ask again in a few seconds.
    Pass `wait=True` to block until the translation is done instead.
    """
    key = _key(title, artist, duration)
    target = normalise_target(target)

    with _lock_for(key):
        entry = _read_cache(key)
        if entry is None:
            entry = _fetch(title, artist, duration)
            _write_cache(key, entry)

    lines = entry.get("lines") or []
    plain = entry.get("plain") or ""
    language = entry.get("language")
    translations = entry.get("translations") or {}

    translating = False
    if target and (lines or plain) and not _same_language(language, target):
        # Translating Chinese lyrics into Chinese would waste a model call and
        # print a duplicate column under every line.
        if target not in translations:
            if wait:
                produced = translate_lines(_texts_of(entry), target,
                                           model=model)
                if produced:
                    with _lock_for(key):
                        current = _read_cache(key) or entry
                        translations = current.get("translations") or {}
                        translations[target] = produced
                        current["translations"] = translations
                        _write_cache(key, current)
            else:
                translating = _start_translation(key, target, model)

    column = translations.get(target) if target else None

    rows = []
    for index, row in enumerate(lines):
        item = {"t": row["t"], "text": row["text"]}
        if column and index < len(column) and column[index]:
            item["tr"] = column[index]
        rows.append(item)

    plain_translated = None
    if column and not lines and plain:
        plain_translated = "\n".join(text or "" for text in column)

    return {
        "ok": bool(rows or plain),
        "source": entry.get("source"),
        "synced": bool(rows),
        "lines": rows,
        "plain": plain,
        "plainTranslated": plain_translated,
        "language": language,
        "target": target,
        "translated": bool(column),
        "translating": translating,
        "trackName": entry.get("trackName"),
        "artistName": entry.get("artistName"),
    }


def _fetch(title, artist, duration):
    hit = _search(title, artist, duration)
    if not hit:
        return {"v": CACHE_VERSION, "fetched": time.time(), "lines": [],
                "plain": "", "language": None, "source": None,
                "translations": {}}

    lines = parse_lrc(hit.get("syncedLyrics") or "")
    plain = (hit.get("plainLyrics") or "").strip()
    sample = "\n".join(row["text"] for row in lines) or plain
    return {
        "v": CACHE_VERSION,
        "fetched": time.time(),
        "source": "lrclib",
        "lines": lines,
        "plain": plain,
        "language": detect_language(sample),
        "trackName": hit.get("trackName"),
        "artistName": hit.get("artistName"),
        "translations": {},
    }
