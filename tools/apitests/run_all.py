"""Run every API suite. Exit code is non-zero if any test failed."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import test_innertube
import test_spotify

if __name__ == "__main__":
    codes = [test_innertube.run(), test_spotify.run()]
    sys.exit(1 if any(codes) else 0)
