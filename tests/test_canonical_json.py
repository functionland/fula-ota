"""Canonical-JSON tests.

The Python _canonical_json in readiness-check.py must produce the EXACT
same UTF-8 bytes as the TypeScript canonicalJSON in
libp2p-relay/cloudflare/src/verify.ts for every payload. The Worker uses
ed25519-verify(serializedInput, signature, pubkey); the box's
heartbeat-sender signs the equivalent serialization in Python. Any
divergence here = every heartbeat fails signature check.

The expected outputs below are also the outputs the TS test
(cloudflare/test/verify.test.ts) asserts against. Keep them in sync.
"""

import json

import pytest

from conftest import readiness


CASES = [
    ("null", None, "null"),
    ("true", True, "true"),
    ("false", False, "false"),
    ("int 42", 42, "42"),
    ("string", "hello", '"hello"'),
    ("empty array", [], "[]"),
    ("empty object", {}, "{}"),
    ("array of ints", [1, 2, 3], "[1,2,3]"),
    ("array of strings", ["a", "b"], '["a","b"]'),
    ("object sorted keys", {"b": 1, "a": 2}, '{"a":2,"b":1}'),
    (
        "nested object deep sort",
        {"z": {"y": 1, "x": 2}, "a": [3, 4]},
        '{"a":[3,4],"z":{"x":2,"y":1}}',
    ),
    ("string with quote", {"x": 'a"b'}, '{"x":"a\\"b"}'),
    ("string with backslash", {"x": "a\\b"}, '{"x":"a\\\\b"}'),
    (
        "heartbeat-shaped payload",
        {
            "peerId": "12D3KooWE6gC66XWxKacdna5LX4ymwnCCMpaddBFkB8At3WedRaZ",
            "timestamp": "2026-05-13T05:30:00.000Z",
            "data": {
                "type": "box",
                "reservedOn": ["relay.dev.fx.land"],
                "libp2pAddrs": ["/dns/relay.dev.fx.land/.../p2p-circuit/p2p/.."],
            },
        },
        (
            '{"data":{"libp2pAddrs":["/dns/relay.dev.fx.land/.../p2p-circuit/p2p/.."],'
            '"reservedOn":["relay.dev.fx.land"],"type":"box"},'
            '"peerId":"12D3KooWE6gC66XWxKacdna5LX4ymwnCCMpaddBFkB8At3WedRaZ",'
            '"timestamp":"2026-05-13T05:30:00.000Z"}'
        ),
    ),
]


@pytest.mark.parametrize("name,inp,expected", CASES, ids=lambda x: x if isinstance(x, str) else "")
def test_canonical_json_matches_expected(name, inp, expected):
    """Each case produces the byte-identical output expected by the TS side."""
    assert readiness._canonical_json(inp) == expected


def test_canonical_json_int_vs_float():
    """1 → "1", 1.0 → "1.0" — types matter for cross-language byte-equality."""
    assert readiness._canonical_json(1) == "1"
    assert readiness._canonical_json(1.0) == "1.0"


def test_canonical_json_non_ascii():
    """ensure_ascii=False so non-ASCII matches TS JSON.stringify behavior."""
    # café — TS JSON.stringify outputs the raw UTF-8 bytes, not \\u escapes.
    result = readiness._canonical_json({"name": "café"})
    assert result == '{"name":"café"}'


def test_canonical_json_unsupported_type_raises():
    with pytest.raises(TypeError):
        readiness._canonical_json(b"raw bytes")  # bytes not allowed


def test_canonical_json_key_sort_is_stable():
    """Keys must sort lexicographically, not insertion order."""
    out = readiness._canonical_json({"z": 1, "a": 2, "m": 3})
    assert out == '{"a":2,"m":3,"z":1}'


def test_canonical_json_real_signing_payload_matches_signed_data():
    """Sanity: building the exact signing input used by post_heartbeat()
    produces output we can JSON-parse and verify field ordering on."""
    payload = {
        "peerId": "P",
        "timestamp": "T",
        "data": {"type": "box", "reservedOn": [], "libp2pAddrs": []},
    }
    serialized = readiness._canonical_json(payload)
    parsed = json.loads(serialized)
    # JSON parse is unordered; assert structural equality.
    assert parsed == payload
    # Re-canonicalize the parsed form must produce identical bytes.
    assert readiness._canonical_json(parsed) == serialized
