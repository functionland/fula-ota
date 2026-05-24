"""Shared pytest fixtures.

readiness-check.py is a script (with a hyphenated filename) not a package,
so we load it via importlib at import time and expose `readiness` to all
tests. Top-level side effects in the script (logging.basicConfig) are
harmless under pytest. local_command_server.py is loaded the same way for
symmetry, so tests can `from conftest import local_command_server`.
"""

import importlib.util
import os
import sys

_LINUX_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "docker", "fxsupport", "linux",
)
SCRIPT_PATH = os.path.join(_LINUX_DIR, "readiness-check.py")
LOCAL_COMMAND_SERVER_PATH = os.path.join(_LINUX_DIR, "local_command_server.py")
RECOVER_PATH = os.path.join(_LINUX_DIR, "readiness-check-recover.py")


def _load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ImportError(f"could not load {path}")
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


# Load once at collection time so failures surface immediately.
readiness = _load_module("readiness_check", SCRIPT_PATH)
local_command_server = _load_module("local_command_server", LOCAL_COMMAND_SERVER_PATH)
# readiness-check-recover.py executes time.sleep(30) inside main(). Loading the
# module here only imports definitions — main() runs only under __name__ == __main__.
recover = _load_module("readiness_check_recover", RECOVER_PATH)
