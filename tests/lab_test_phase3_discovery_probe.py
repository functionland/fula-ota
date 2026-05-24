"""One-off probe to check what discovery.fula.network/relays returns from
Python requests on the lab device, matching the exact headers Phase 3 will use.

Run on device: python3 /tmp/lab_test_phase3_discovery_probe.py
"""
import requests
import time

URL = "https://discovery.fula.network/relays"
HEADERS = {
    "user-agent": "fula-readiness-check/1.0",
    "x-fula-client": "edge",
}

for verb in ("HEAD", "GET"):
    t0 = time.monotonic()
    try:
        if verb == "HEAD":
            r = requests.head(URL, timeout=5, headers=HEADERS, allow_redirects=False)
        else:
            r = requests.get(URL, timeout=5, headers=HEADERS, allow_redirects=False)
        ms = int((time.monotonic() - t0) * 1000)
        print(f"{verb} status={r.status_code} time={ms}ms len={len(r.content)} server={r.headers.get('server', '?')}")
        if r.status_code != 200:
            preview = r.text[:200] if hasattr(r, 'text') else '<head-no-body>'
            print(f"  body_preview: {preview!r}")
    except Exception as e:
        print(f"{verb} failed: {type(e).__name__}: {str(e)[:200]}")
