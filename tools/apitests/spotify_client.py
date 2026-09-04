"""Spotify Web API helpers for the test-suite, plus a local PKCE login helper.

"Bring your own account" means the user registers their own Spotify app and we
never ship a client secret. Authorization Code + PKCE is the only flow that
works for a public native client, so that is what both the tests and the iOS
app use.
"""
import base64
import hashlib
import http.server
import json
import os
import secrets
import threading
import urllib.error
import urllib.parse
import urllib.request
import webbrowser

AUTH_URL = "https://accounts.spotify.com/authorize"
TOKEN_URL = "https://accounts.spotify.com/api/token"
API = "https://api.spotify.com/v1"

# Everything the recommendation engine needs, and nothing more.
SCOPES = " ".join([
    "user-read-private",
    "user-read-email",
    "user-top-read",
    "user-read-recently-played",
    "user-library-read",
    "user-follow-read",
    "playlist-read-private",
    "playlist-read-collaborative",
])


def _b64url(raw):
    return base64.urlsafe_b64encode(raw).decode().rstrip("=")


def make_pkce_pair():
    verifier = _b64url(secrets.token_bytes(64))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    return verifier, challenge


def get(path, token, params=None):
    """GET an API path. Returns (status, parsed_json_or_text)."""
    url = API + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    req = urllib.request.Request(url)
    req.add_header("Authorization", "Bearer " + token)
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read().decode()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        body = e.read().decode(errors="replace")
        try:
            return e.code, json.loads(body)
        except ValueError:
            return e.code, body[:400]
    except Exception as e:  # noqa: BLE001
        return 0, str(e)


def exchange_code(client_id, code, verifier, redirect_uri):
    data = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": redirect_uri,
        "client_id": client_id,
        "code_verifier": verifier,
    }).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


def refresh_token(client_id, refresh):
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": refresh,
        "client_id": client_id,
    }).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read().decode())


class _CallbackHandler(http.server.BaseHTTPRequestHandler):
    result = {}

    def do_GET(self):  # noqa: N802
        query = urllib.parse.urlparse(self.path).query
        _CallbackHandler.result = dict(urllib.parse.parse_qsl(query))
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        ok = "code" in _CallbackHandler.result
        self.wfile.write(
            ("<html><body style='font-family:system-ui;padding:3rem'>"
             "<h2>%s</h2><p>You can close this tab and return to the terminal.</p>"
             "</body></html>" % ("Spotify login complete." if ok else "Spotify login failed."))
            .encode())

    def log_message(self, *args):
        pass


def interactive_login(client_id, port=8888):
    """Run the PKCE flow against a throwaway localhost server. Returns a token dict."""
    redirect_uri = "http://127.0.0.1:%d/callback" % port
    verifier, challenge = make_pkce_pair()
    state = secrets.token_urlsafe(16)
    params = {
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": redirect_uri,
        "state": state,
        "scope": SCOPES,
        "code_challenge_method": "S256",
        "code_challenge": challenge,
    }
    url = AUTH_URL + "?" + urllib.parse.urlencode(params)

    server = http.server.HTTPServer(("127.0.0.1", port), _CallbackHandler)
    thread = threading.Thread(target=server.handle_request, daemon=True)
    thread.start()

    print("Opening your browser to authorise Spotify...")
    print("If it does not open, visit:\n  %s\n" % url)
    webbrowser.open(url)
    thread.join(timeout=300)
    server.server_close()

    result = _CallbackHandler.result
    if "code" not in result:
        raise RuntimeError("no authorization code received: %s" % result)
    if result.get("state") != state:
        raise RuntimeError("state mismatch - possible CSRF, aborting")
    return exchange_code(client_id, result["code"], verifier, redirect_uri)


def save_tokens(tokens, path=None):
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                ".spotify_tokens.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(tokens, fh, indent=2)
    return path


def load_tokens(path=None):
    path = path or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                ".spotify_tokens.json")
    if not os.path.exists(path):
        return None
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)
