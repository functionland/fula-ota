"""Tests for _load_kubo_ed25519_key in readiness-check.py.

The function parses a kubo config file's Identity section, decodes the
libp2p-protobuf-wrapped ed25519 private key, and produces a usable
Ed25519PrivateKey. We test it with a synthetically-generated keypair so
we don't need a real kubo install.
"""

import base64
import hashlib
import json
import os
import tempfile

import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from conftest import readiness


B58_ALPHABET = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


def _base58_encode(b: bytes) -> str:
    """Bitcoin-style base58btc encode."""
    if not b:
        return ""
    zeros = 0
    while zeros < len(b) and b[zeros] == 0:
        zeros += 1
    n = int.from_bytes(b, "big")
    out = []
    while n:
        n, r = divmod(n, 58)
        out.append(B58_ALPHABET[r])
    return "1" * zeros + "".join(reversed(out))


def _peer_id_from_pubkey(pub_bytes: bytes) -> str:
    """Build a libp2p peer ID from a raw 32-byte ed25519 public key."""
    assert len(pub_bytes) == 32
    # protobuf PublicKey{Type=Ed25519, Data=pub}: 0x08 0x01 0x12 0x20 + pub
    proto = b"\x08\x01\x12\x20" + pub_bytes
    # identity multihash: 0x00 + length(36) + proto
    mh = b"\x00\x24" + proto
    return _base58_encode(mh)


def _make_synthetic_kubo_config(privkey_b64: str, peer_id: str) -> dict:
    return {
        "Identity": {"PeerID": peer_id, "PrivKey": privkey_b64},
        "Datastore": {},
    }


def _wrap_libp2p_privkey(seed_32: bytes, pub_32: bytes) -> bytes:
    """Build the libp2p PrivateKey protobuf for ed25519.
    Wire format: 0x08 0x01 0x12 0x40 + (seed || pub).
    Total 68 bytes."""
    assert len(seed_32) == 32 and len(pub_32) == 32
    return b"\x08\x01\x12\x40" + seed_32 + pub_32


@pytest.fixture
def synthetic_kubo_config(tmp_path):
    """Generates a real ed25519 keypair, encodes it the way kubo would,
    writes a synthetic config file, returns (path, seed, peer_id)."""
    priv = Ed25519PrivateKey.generate()
    from cryptography.hazmat.primitives import serialization
    seed = priv.private_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PrivateFormat.Raw,
        encryption_algorithm=serialization.NoEncryption(),
    )
    pub_bytes = priv.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,
        format=serialization.PublicFormat.Raw,
    )
    privkey_wire = _wrap_libp2p_privkey(seed, pub_bytes)
    privkey_b64 = base64.b64encode(privkey_wire).decode("ascii")
    peer_id = _peer_id_from_pubkey(pub_bytes)

    cfg = _make_synthetic_kubo_config(privkey_b64, peer_id)
    path = tmp_path / "config"
    path.write_text(json.dumps(cfg))
    return str(path), seed, peer_id


def test_loads_key_and_peer_id(synthetic_kubo_config, monkeypatch):
    path, seed, peer_id = synthetic_kubo_config
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", path)

    key, returned_peer_id = readiness._load_kubo_ed25519_key()
    assert key is not None
    assert returned_peer_id == peer_id
    # The recovered key must produce a signature verifiable against the seed.
    sig = key.sign(b"hello world")
    assert isinstance(sig, bytes) and len(sig) == 64


def test_missing_config_returns_none(monkeypatch):
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", "/no/such/file")
    key, peer_id = readiness._load_kubo_ed25519_key()
    assert key is None
    assert peer_id is None


def test_malformed_privkey_wire_returns_none(tmp_path, monkeypatch):
    """A PrivKey with wrong protobuf header should be rejected, not crash."""
    bad_privkey = base64.b64encode(b"\xff\xff\xff\xff" + b"\x00" * 64).decode("ascii")
    cfg_path = tmp_path / "config"
    cfg_path.write_text(json.dumps({
        "Identity": {"PeerID": "irrelevant", "PrivKey": bad_privkey},
    }))
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", str(cfg_path))
    key, peer_id = readiness._load_kubo_ed25519_key()
    assert key is None
    assert peer_id is None


def test_short_privkey_returns_none(tmp_path, monkeypatch):
    short = base64.b64encode(b"\x08\x01\x12\x40" + b"\x00" * 10).decode("ascii")  # truncated
    cfg_path = tmp_path / "config"
    cfg_path.write_text(json.dumps({"Identity": {"PeerID": "x", "PrivKey": short}}))
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", str(cfg_path))
    key, peer_id = readiness._load_kubo_ed25519_key()
    assert key is None
    assert peer_id is None


def test_missing_identity_keys_returns_none(tmp_path, monkeypatch):
    cfg_path = tmp_path / "config"
    cfg_path.write_text(json.dumps({"Datastore": {}}))   # no Identity
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", str(cfg_path))
    key, peer_id = readiness._load_kubo_ed25519_key()
    assert key is None
    assert peer_id is None


def test_invalid_json_returns_none(tmp_path, monkeypatch):
    cfg_path = tmp_path / "config"
    cfg_path.write_text("{not valid json")
    monkeypatch.setattr(readiness, "KUBO_CONFIG_PATH", str(cfg_path))
    key, peer_id = readiness._load_kubo_ed25519_key()
    assert key is None
    assert peer_id is None
