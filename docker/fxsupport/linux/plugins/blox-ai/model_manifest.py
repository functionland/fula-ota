"""Phase 18 — model manifest loader + active-entry selector.

Stdlib-only helper that download_model.sh shells out to. Returns the
ACTIVE ModelEntry's url + sha256 + model_version on stdout so the
calling shell script can `eval` it. Falls back to a synthesized
default entry when no manifest is present on disk (legacy installs
and devices that haven't received their first manifest yet).

Output format (intentionally `KEY=VALUE` newline-separated so shell
can `eval` safely; values are quoted and never contain CR/LF):

    MODEL_VERSION='2026-05-15'
    MODEL_URL='https://...'
    MODEL_SHA256='<hex>'
    MODEL_SIZE_BYTES='3100000000'
    MANIFEST_SOURCE='manifest_current'

MANIFEST_SOURCE values:
    manifest_current  — manifest present, rollback_required=false
    manifest_rollback — manifest present, rollback_required=true
    fallback          — no manifest, used hardcoded download_model.sh values
    fallback_invalid  — manifest present but malformed; used fallback to be safe

Refuses to crash on bad input — the worst outcome is 'plugin falls
back to the hardcoded model URL', which is exactly what devices ran
before Phase 18.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import dataclass
from typing import Optional


_DEFAULT_MANIFEST_PATH = "/etc/fula/ai-manifest.json"

# Mirror the JSON Schema constraints in code so the loader can validate
# without pulling in jsonschema (which isn't guaranteed installed on the
# host's system python). These MUST stay in sync with ai_manifest.schema.json.
_SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
_VERSION_RE = re.compile(r"^[A-Za-z0-9._-]+$")
_HTTPS_PREFIX = "https://"

_REQUIRED_TOP_KEYS = {"schema_version", "current", "rollback", "rollback_required"}
_REQUIRED_ENTRY_KEYS = {"model_version", "url", "sha256", "size_bytes"}

_SUPPORTED_SCHEMA_VERSION = 1


class ManifestError(ValueError):
    """Raised on any structural problem with the manifest file."""


@dataclass(frozen=True)
class ModelEntry:
    model_version: str
    url: str
    sha256: str
    size_bytes: int


@dataclass(frozen=True)
class SelectedModel:
    entry: ModelEntry
    source: str  # one of MANIFEST_SOURCE values above


def _validate_entry(raw: dict, where: str) -> ModelEntry:
    if not isinstance(raw, dict):
        raise ManifestError(f"{where}: not a JSON object")
    missing = _REQUIRED_ENTRY_KEYS - raw.keys()
    if missing:
        raise ManifestError(f"{where}: missing keys {sorted(missing)}")
    mv = raw["model_version"]
    if not isinstance(mv, str) or not _VERSION_RE.match(mv) or len(mv) > 64:
        raise ManifestError(f"{where}.model_version: invalid {mv!r}")
    url = raw["url"]
    if not isinstance(url, str) or not url.startswith(_HTTPS_PREFIX) or len(url) > 2048:
        raise ManifestError(f"{where}.url: must be https:// and <=2048 chars")
    sha = raw["sha256"]
    if not isinstance(sha, str) or not _SHA256_RE.match(sha):
        raise ManifestError(f"{where}.sha256: not a 64-char lowercase hex")
    size = raw["size_bytes"]
    if not isinstance(size, int) or isinstance(size, bool) or size < 1_000_000_000 or size > 20_000_000_000:
        raise ManifestError(f"{where}.size_bytes: must be int in [1e9, 2e10]")
    return ModelEntry(model_version=mv, url=url, sha256=sha, size_bytes=size)


def parse(text: str) -> tuple[ModelEntry, ModelEntry, bool]:
    """Parse + structurally validate a manifest. Returns (current, rollback, rollback_required).

    Raises ManifestError on any problem.
    """
    try:
        data = json.loads(text)
    except json.JSONDecodeError as e:
        raise ManifestError(f"invalid JSON: {e}") from e
    if not isinstance(data, dict):
        raise ManifestError("manifest root must be a JSON object")
    missing = _REQUIRED_TOP_KEYS - data.keys()
    if missing:
        raise ManifestError(f"missing top-level keys: {sorted(missing)}")
    sv = data.get("schema_version")
    if sv != _SUPPORTED_SCHEMA_VERSION:
        raise ManifestError(
            f"unsupported schema_version {sv!r}; expected {_SUPPORTED_SCHEMA_VERSION}"
        )
    current = _validate_entry(data["current"], "current")
    rollback = _validate_entry(data["rollback"], "rollback")
    rr = data["rollback_required"]
    if not isinstance(rr, bool):
        raise ManifestError(f"rollback_required: must be boolean, got {type(rr).__name__}")
    return current, rollback, rr


def select(manifest_text: Optional[str],
           fallback_url: str,
           fallback_sha256: str,
           fallback_version: str = "fallback-hardcoded",
           fallback_size_bytes: int = 3_000_000_000) -> SelectedModel:
    """Decide which model entry to use.

    `manifest_text` is the raw contents of the on-disk manifest file
    (or None if the file is missing). On any parse error we synthesize
    a `SelectedModel` from the fallback args — that way a device with
    a corrupted manifest still falls back to the same model it would
    have run pre-Phase-18.
    """
    if manifest_text is None:
        return SelectedModel(
            entry=ModelEntry(fallback_version, fallback_url,
                             fallback_sha256, fallback_size_bytes),
            source="fallback",
        )
    try:
        current, rollback, rr = parse(manifest_text)
    except ManifestError:
        return SelectedModel(
            entry=ModelEntry(fallback_version, fallback_url,
                             fallback_sha256, fallback_size_bytes),
            source="fallback_invalid",
        )
    if rr:
        return SelectedModel(entry=rollback, source="manifest_rollback")
    return SelectedModel(entry=current, source="manifest_current")


def _emit_shell(selected: SelectedModel) -> str:
    e = selected.entry
    # Single-quote each value; reject any value containing a single quote
    # (none of the validated fields can contain one given the regexes
    # above, but defense-in-depth).
    for v in (e.model_version, e.url, e.sha256, selected.source):
        if "'" in v or "\n" in v or "\r" in v:
            raise ManifestError(f"value contains shell-unsafe char: {v!r}")
    return (
        f"MODEL_VERSION='{e.model_version}'\n"
        f"MODEL_URL='{e.url}'\n"
        f"MODEL_SHA256='{e.sha256}'\n"
        f"MODEL_SIZE_BYTES='{e.size_bytes}'\n"
        f"MANIFEST_SOURCE='{selected.source}'\n"
    )


def main(argv: Optional[list] = None) -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--manifest-path", default=_DEFAULT_MANIFEST_PATH)
    p.add_argument("--fallback-url", required=True,
                   help="Hardcoded URL used when no manifest exists.")
    p.add_argument("--fallback-sha256", required=True,
                   help="Hardcoded SHA used when no manifest exists.")
    p.add_argument("--fallback-version", default="fallback-hardcoded")
    p.add_argument("--fallback-size-bytes", type=int, default=3_000_000_000)
    args = p.parse_args(argv)

    try:
        with open(args.manifest_path, encoding="utf-8") as f:
            text = f.read()
    except OSError:
        text = None

    selected = select(
        manifest_text=text,
        fallback_url=args.fallback_url,
        fallback_sha256=args.fallback_sha256,
        fallback_version=args.fallback_version,
        fallback_size_bytes=args.fallback_size_bytes,
    )
    sys.stdout.write(_emit_shell(selected))
    return 0


if __name__ == "__main__":
    sys.exit(main())
