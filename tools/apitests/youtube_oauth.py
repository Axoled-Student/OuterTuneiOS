"""YouTube TV/device OAuth flow.

The native Music clients (ANDROID_MUSIC / IOS_MUSIC) reject SAPISID cookies
with LOGIN_REQUIRED - they authenticate with an OAuth Bearer token. Those
clients matter because, unlike WEB_REMIX, they do not run YouTube's player JS,
so the formats they are offered carry direct URLs with no signatureCipher to
descramble. That is the difference between premium audio being listed and
premium audio being playable.

These are the public credentials embedded in the YouTube on TV client; they are
not secret and carry no user identity of their own.
"""
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request

CLIENT_ID = "861556708454-d6dlm3lh05idd8npek18k6be8ba3oc68.apps.googleusercontent.com"
CLIENT_SECRET = "SboVhoG9s0rNafixCSGGKXAT"
SCOPE = "https://www.googleapis.com/auth/youtube"

DEVICE_CODE_URL = "https://oauth2.googleapis.com/device/code"
TOKEN_URL = "https://oauth2.googleapis.com/token"
GRANT_DEVICE = "urn:ietf:params:oauth:grant-type:device_code"

TOKEN_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                          ".youtube_oauth.json")

USER_AGENT = ("com.google.android.apps.youtube.music/8.12.53 "
              "(Linux; U; Android 14) gzip")


def _post(url, fields):
    data = urllib.parse.urlencode(fields).encode()
    request = urllib.request.Request(url, data=data, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    request.add_header("User-Agent", USER_AGENT)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            return response.status, json.loads(response.read().decode())
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, {"raw": body[:300]}


def request_device_code():
    status, body = _post(DEVICE_CODE_URL,
                         {"client_id": CLIENT_ID, "scope": SCOPE})
    if status != 200:
        raise RuntimeError("device code request failed: %s %s" % (status, body))
    return body


def poll_for_token(device_code, interval=5, timeout=300):
    deadline = time.time() + timeout
    while time.time() < deadline:
        status, body = _post(TOKEN_URL, {
            "client_id": CLIENT_ID,
            "client_secret": CLIENT_SECRET,
            "device_code": device_code,
            "grant_type": GRANT_DEVICE,
        })
        if status == 200 and "access_token" in body:
            body["obtained_at"] = int(time.time())
            return body
        error = body.get("error")
        if error == "authorization_pending":
            time.sleep(interval)
            continue
        if error == "slow_down":
            interval += 2
            time.sleep(interval)
            continue
        raise RuntimeError("token exchange failed: %s %s" % (status, body))
    raise TimeoutError("timed out waiting for device authorisation")


def refresh(refresh_token):
    status, body = _post(TOKEN_URL, {
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "refresh_token": refresh_token,
        "grant_type": "refresh_token",
    })
    if status != 200:
        raise RuntimeError("refresh failed: %s %s" % (status, body))
    body["obtained_at"] = int(time.time())
    return body


def save(tokens, path=TOKEN_PATH):
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(tokens, fh, indent=2)
    return path


def load(path=TOKEN_PATH):
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def valid_access_token():
    """Return a usable access token, refreshing it when needed."""
    tokens = load()
    if not tokens:
        return None
    age = time.time() - tokens.get("obtained_at", 0)
    if age < tokens.get("expires_in", 3600) - 120:
        return tokens.get("access_token")
    if not tokens.get("refresh_token"):
        return tokens.get("access_token")
    refreshed = refresh(tokens["refresh_token"])
    refreshed.setdefault("refresh_token", tokens["refresh_token"])
    save(refreshed)
    return refreshed.get("access_token")


def main():
    existing = valid_access_token()
    if existing:
        print("Already authorised. Token in %s" % TOKEN_PATH)
        return 0

    info = request_device_code()
    print("=" * 66)
    print("  Open:  %s" % info.get("verification_url"))
    print("  Code:  %s" % info.get("user_code"))
    print("=" * 66)
    print("Waiting for you to approve (up to 5 minutes)...")

    tokens = poll_for_token(info["device_code"],
                            interval=int(info.get("interval", 5)))
    path = save(tokens)
    print("Authorised. Tokens saved to %s" % path)
    print("scope: %s" % tokens.get("scope"))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
