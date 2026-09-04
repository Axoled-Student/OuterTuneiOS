"""Tiny dependency-free test harness used by the API test suites.

Deliberately not pytest: these run against the live YouTube Music / Spotify
APIs from CI and from a dev machine, and the report is meant to be read by a
human comparing a "before" and "after" run.
"""
import os
import sys
import traceback

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
DIM = "\033[2m"
RESET = "\033[0m"

if os.name == "nt" and not os.environ.get("FORCE_COLOR"):
    try:
        import colorama  # noqa: F401
    except ImportError:
        GREEN = RED = YELLOW = DIM = RESET = ""


def load_env():
    """Read tools/apitests/.env (KEY=VALUE, # comments) layered under os.environ."""
    env = {}
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, value = line.split("=", 1)
                env[key.strip()] = value.strip().strip('"').strip("'")
    for key, value in os.environ.items():
        if value:
            env[key] = value
    return env


class Failure(Exception):
    pass


class Test:
    def __init__(self, name):
        self.name = name
        self.notes = []
        self.warnings = []

    def require(self, condition, message):
        if not condition:
            raise Failure(message)

    def note(self, message):
        self.notes.append(message)

    def warn(self, message):
        self.warnings.append(message)


class _TestContext:
    def __init__(self, suite, name):
        self.suite = suite
        self.test = Test(name)

    def __enter__(self):
        return self.test

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self.suite._record(self.test, "pass", None)
        elif exc_type is Failure:
            self.suite._record(self.test, "fail", str(exc))
        else:
            detail = "".join(traceback.format_exception_only(exc_type, exc)).strip()
            self.suite._record(self.test, "error", detail)
        return True  # never abort the rest of the suite


class Suite:
    def __init__(self, title):
        self.title = title
        self.results = []
        print(f"\n{'=' * 72}\n{title}\n{'=' * 72}")

    def test(self, name):
        return _TestContext(self, name)

    def skip(self, name, reason=""):
        self.results.append(("skip", name, reason))
        print(f"{YELLOW}SKIP{RESET} {name}" + (f" {DIM}({reason}){RESET}" if reason else ""))

    def _record(self, test, outcome, detail):
        self.results.append((outcome, test.name, detail))
        icon = {"pass": f"{GREEN}PASS{RESET}", "fail": f"{RED}FAIL{RESET}",
                "error": f"{RED}ERR {RESET}"}[outcome]
        print(f"{icon} {test.name}")
        for note in test.notes:
            for line in str(note).split("\n"):
                print(f"     {DIM}{line}{RESET}")
        for warning in test.warnings:
            print(f"     {YELLOW}! {warning}{RESET}")
        if detail:
            for line in str(detail).split("\n"):
                print(f"     {RED}{line}{RESET}")

    def report(self):
        counts = {"pass": 0, "fail": 0, "error": 0, "skip": 0}
        for outcome, _, _ in self.results:
            counts[outcome] += 1
        print(f"\n{'-' * 72}")
        print(f"{self.title}: {counts['pass']} passed, {counts['fail']} failed, "
              f"{counts['error']} errored, {counts['skip']} skipped")
        print("-" * 72)
        return 1 if (counts["fail"] or counts["error"]) else 0


def main_of(*suite_runners):
    """Run several suite entry points, return a shell exit code."""
    codes = [runner() for runner in suite_runners]
    return 1 if any(codes) else 0


if __name__ == "__main__":
    sys.exit(0)
