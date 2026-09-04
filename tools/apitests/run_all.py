"""Run every API suite. Exit code is non-zero if any test failed."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import test_innertube
import test_recommender
import test_signature_cipher
import test_spotify
import test_stream_fetch

if __name__ == "__main__":
    codes = [test_innertube.run(), test_stream_fetch.run(), test_signature_cipher.run(),
             test_spotify.run(), test_recommender.run()]
    sys.exit(1 if any(codes) else 0)
