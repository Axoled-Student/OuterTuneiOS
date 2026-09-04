"""One-off interactive Spotify login for the test-suite.

    python tools/apitests/spotify_login.py

Requires SPOTIFY_CLIENT_ID (tools/apitests/.env or the environment) and a
Spotify app whose redirect URIs include http://127.0.0.1:8888/callback.
The resulting tokens are written to tools/apitests/.spotify_tokens.json,
which is git-ignored.
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import spotify_client as sp  # noqa: E402
from harness import load_env  # noqa: E402


def main():
    env = load_env()
    client_id = env.get("SPOTIFY_CLIENT_ID")
    if not client_id:
        print("SPOTIFY_CLIENT_ID is not set.\n"
              "Create an app at https://developer.spotify.com/dashboard, add\n"
              "  http://127.0.0.1:8888/callback\n"
              "to its Redirect URIs, then put the client id in "
              "tools/apitests/.env (see .env.example).")
        return 1

    port = int(env.get("SPOTIFY_CALLBACK_PORT", "8888"))
    tokens = sp.interactive_login(client_id, port=port)
    path = sp.save_tokens(tokens)

    status, me = sp.get("/me", tokens["access_token"])
    if status == 200:
        print("Logged in as %s (%s), product=%s"
              % (me.get("display_name"), me.get("id"), me.get("product")))
    else:
        print("Token obtained but /me returned HTTP %s: %s" % (status, me))

    print("Tokens saved to %s" % path)
    print("Now run: python tools/apitests/test_spotify.py")
    return 0


if __name__ == "__main__":
    sys.exit(main())
