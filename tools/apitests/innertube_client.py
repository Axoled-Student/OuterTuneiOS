"""Minimal InnerTube (YouTube Music) client used by the API test-suite.

Mirrors the request shape the iOS app uses (YouTubeMusicService.swift) so the
tests exercise the same contract the app depends on.
"""
import hashlib
import json
import re
import time
import urllib.error
import urllib.request

API = "https://music.youtube.com/youtubei/v1/"
UA_WEB = "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:128.0) Gecko/20100101 Firefox/128.0"


class Client:
    def __init__(self, name, version, cid, ua, os_version=None, login_supported=False):
        self.name = name
        self.version = version
        self.cid = cid
        self.ua = ua
        self.os_version = os_version
        self.login_supported = login_supported


IOS = Client("IOS", "20.10.4", "5",
             "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
             "18.3.2.22D82")
ANDROID_VR = Client("ANDROID_VR", "1.61.48", "28",
                    "com.google.android.apps.youtube.vr.oculus/1.61.48 (Linux; U; Android 12; "
                    "en_US; Oculus Quest 3; Build/SQ3A.220605.009.A1; Cronet/132.0.6808.3)", "12")
WEB_REMIX = Client("WEB_REMIX", "1.20250310.01.00", "67", UA_WEB, None, True)
TVHTML5 = Client("TVHTML5", "7.20250312.16.00", "7",
                 "Mozilla/5.0(SMART-TV; Linux; Tizen 4.0.0.2) AppleWebkit/605.1.15 "
                 "(KHTML, like Gecko) SamsungBrowser/9.2 TV Safari/605.1.15", None, True)


def sapisid_hash(sapisid, origin="https://music.youtube.com"):
    ts = int(time.time())
    digest = hashlib.sha1(f"{ts} {sapisid} {origin}".encode()).hexdigest()
    return f"SAPISIDHASH {ts}_{digest}"


def parse_cookie(cookie):
    out = {}
    for part in cookie.split(";"):
        part = part.strip()
        if "=" in part:
            k, v = part.split("=", 1)
            out[k.strip()] = v.strip()
    return out


def fetch_visitor_data():
    req = urllib.request.Request("https://music.youtube.com/", headers={"User-Agent": UA_WEB})
    html = urllib.request.urlopen(req, timeout=30).read().decode(errors="replace")
    m = re.search(r'"visitorData":"(.*?)"', html)
    return m.group(1) if m else None


def call(path, payload, client, cookie=None, visitor_data=None, data_sync_id=None):
    """POST to an InnerTube endpoint. Returns (status, parsed_json_or_text)."""
    ctx_client = {"clientName": client.name, "clientVersion": client.version,
                  "hl": "en", "gl": "US"}
    if client.os_version:
        ctx_client["osVersion"] = client.os_version
    if visitor_data:
        ctx_client["visitorData"] = visitor_data
    context = {"client": ctx_client}
    if cookie and client.login_supported and data_sync_id:
        context["user"] = {"onBehalfOfUser": data_sync_id}

    body = dict(payload)
    body["context"] = context

    url = f"{API}{path}?prettyPrint=false"
    req = urllib.request.Request(url, data=json.dumps(body).encode(), method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("X-YouTube-Client-Name", client.cid)
    req.add_header("X-YouTube-Client-Version", client.version)
    req.add_header("X-Goog-Api-Format-Version", "1")
    req.add_header("User-Agent", client.ua)
    if client.ua.startswith("Mozilla"):
        req.add_header("Origin", "https://music.youtube.com")
        req.add_header("X-Origin", "https://music.youtube.com")
        req.add_header("Referer", "https://music.youtube.com/")
    if cookie:
        req.add_header("Cookie", cookie)
        jar = parse_cookie(cookie)
        sap = jar.get("SAPISID") or jar.get("__Secure-3PAPISID")
        if sap:
            req.add_header("Authorization", sapisid_hash(sap))

    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:500].decode(errors="replace")
    except Exception as e:  # noqa: BLE001 - surfaced verbatim in the report
        return 0, str(e)


def walk(obj, key, out=None):
    """Collect every value stored under `key` anywhere in a nested structure."""
    if out is None:
        out = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == key:
                out.append(v)
            walk(v, key, out)
    elif isinstance(obj, list):
        for v in obj:
            walk(v, key, out)
    return out


def audio_formats(player_response):
    sd = player_response.get("streamingData", {}) or {}
    fmts = (sd.get("adaptiveFormats") or []) + (sd.get("formats") or [])
    return [f for f in fmts if "audio" in (f.get("mimeType") or "")]
