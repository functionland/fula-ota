"""Shared pytest fixtures.

readiness-check.py is a script (with a hyphenated filename) not a package,
so we load it via importlib at import time and expose `readiness` to all
tests. Top-level side effects in the script (logging.basicConfig) are
harmless under pytest.
"""

import importlib.util
import os
import sys

SCRIPT_PATH = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "docker", "fxsupport", "linux", "readiness-check.py",
)


def _load_readiness_module():
    spec = importlib.util.spec_from_file_location("readiness_check", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load readiness-check.py from {SCRIPT_PATH}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules["readiness_check"] = mod
    spec.loader.exec_module(mod)
    return mod


# Load once at collection time so failures surface immediately.
readiness = _load_readiness_module()
