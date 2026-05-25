"""Phase 17 — runbook.md frontmatter parser.

Pure-Python helper shared by:
- the host-side reload_runbook.sh wrapper (sanity-validates the file
  exists + parses + version is positive before sending SIGHUP to the
  container; refuses to signal if the file is malformed so the container
  isn't asked to swap to a broken runbook), and
- the cross-repo blox-ai container's SIGHUP handler (re-read runbook.md,
  parse frontmatter via this exact function — vendored or git-submoduled
  per the same source-of-truth discipline as the JSON schemas).

Frontmatter is YAML-ish:
    ---
    runbook_version: 1
    schema_version: 1
    last_updated: 2026-05-24
    ---

Why not import a YAML library: this module is intentionally stdlib-only
so the host wrapper can run on any Python 3.x without pip install. The
frontmatter grammar is fixed; we don't need full YAML.
"""
from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Optional


# Recognised frontmatter keys. Unknown keys are tolerated (forward
# compat) but never returned in the parsed dataclass — call sites only
# act on the closed set.
_REQUIRED_KEYS = {"runbook_version", "schema_version", "last_updated"}
_KEY_RE = re.compile(r"^([a-z_][a-z0-9_]*)\s*:\s*(.+?)\s*$")
_FENCE = "---"


class RunbookFrontmatterError(ValueError):
    """Raised when a runbook.md file is malformed at the frontmatter level."""


@dataclass(frozen=True)
class RunbookFrontmatter:
    runbook_version: int
    schema_version: int
    last_updated: str

    def is_newer_than(self, other: Optional["RunbookFrontmatter"]) -> bool:
        """True iff self.runbook_version > other.runbook_version. None
        on the right side means 'no previous runbook seen' → True."""
        if other is None:
            return True
        if self.schema_version != other.schema_version:
            # Schema bumps are breaking changes — refuse to compare,
            # let the container's SIGHUP handler refuse to swap.
            raise RunbookFrontmatterError(
                f"refusing to compare versions across schema_version "
                f"{other.schema_version} → {self.schema_version}; "
                f"container must restart, not SIGHUP-reload"
            )
        return self.runbook_version > other.runbook_version


def parse(text: str) -> RunbookFrontmatter:
    """Parse the frontmatter block out of a runbook.md string.

    Raises RunbookFrontmatterError on any structural problem.
    """
    if not text.startswith(_FENCE + "\n") and not text.startswith(_FENCE + "\r\n"):
        raise RunbookFrontmatterError(
            "runbook.md must begin with a '---' fence on its own line"
        )
    # Find the closing fence
    lines = text.splitlines()
    if not lines or lines[0] != _FENCE:
        raise RunbookFrontmatterError("missing opening '---' fence")
    closing_idx = None
    for i in range(1, len(lines)):
        if lines[i] == _FENCE:
            closing_idx = i
            break
    if closing_idx is None:
        raise RunbookFrontmatterError("missing closing '---' fence")
    if closing_idx == 1:
        raise RunbookFrontmatterError("empty frontmatter block")

    found: dict[str, str] = {}
    for raw in lines[1:closing_idx]:
        # Tolerate blank lines within frontmatter (rare but harmless)
        if not raw.strip():
            continue
        m = _KEY_RE.match(raw)
        if not m:
            raise RunbookFrontmatterError(
                f"unparseable frontmatter line: {raw!r}"
            )
        key, value = m.group(1), m.group(2)
        # Strip optional quotes
        if (value.startswith('"') and value.endswith('"')) or \
           (value.startswith("'") and value.endswith("'")):
            value = value[1:-1]
        found[key] = value

    missing = _REQUIRED_KEYS - found.keys()
    if missing:
        raise RunbookFrontmatterError(
            f"missing required frontmatter keys: {sorted(missing)}"
        )

    try:
        rv = int(found["runbook_version"])
        sv = int(found["schema_version"])
    except ValueError as e:
        raise RunbookFrontmatterError(
            f"runbook_version / schema_version must be integers: {e}"
        )
    if rv < 1:
        raise RunbookFrontmatterError(
            f"runbook_version must be >= 1, got {rv}"
        )
    if sv < 1:
        raise RunbookFrontmatterError(
            f"schema_version must be >= 1, got {sv}"
        )

    return RunbookFrontmatter(
        runbook_version=rv,
        schema_version=sv,
        last_updated=found["last_updated"],
    )


def parse_file(path: str) -> RunbookFrontmatter:
    """Convenience wrapper around parse() for a filesystem path."""
    with open(path, encoding="utf-8") as f:
        return parse(f.read())
