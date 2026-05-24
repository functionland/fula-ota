"""Phase 16 tests — end-of-session feedback BLE command + schemas.

Phase 16 deliverable (fula-ota side):
1. NEW feedback_request.schema.json (POST /feedback body)
2. NEW feedback_log_line.schema.json (/var/log/fula/ai-feedback.jsonl line)
3. ble_commands.json adds ai/feedback (18 total now)
4. api/README.md gets a Phase 16 contract section

Design discipline kept from earlier phases:
- closed schemas (additionalProperties:false)
- closed enum on rating (-1, 0, 1) — 0 is explicit-skip, NOT modal-dismissed
- comment max 2000 chars (matches container's truncation cap)
- no central upload channel here — that's Phase 21
- session-detached feedback STILL accepted (verdict_summary='', actions_taken=[])
"""

import json
import os

import jsonschema
import pytest


_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_PLUGIN_DIR = os.path.join(
    _REPO_ROOT, "docker", "fxsupport", "linux", "plugins", "blox-ai",
)
_API_DIR = os.path.join(_PLUGIN_DIR, "api")
_FEEDBACK_REQ = os.path.join(_API_DIR, "feedback_request.schema.json")
_FEEDBACK_LOG = os.path.join(_API_DIR, "feedback_log_line.schema.json")
_BLE_MANIFEST = os.path.join(_PLUGIN_DIR, "ble_commands.json")
_API_README = os.path.join(_API_DIR, "README.md")


def _load(path):
    with open(path) as f:
        return json.load(f)


def _validate(payload, schema):
    jsonschema.validate(
        payload, schema,
        format_checker=jsonschema.Draft202012Validator.FORMAT_CHECKER,
    )


# ---------------------------------------------------------------------------
# feedback_request schema
# ---------------------------------------------------------------------------

def test_feedback_request_schema_exists_and_versioned():
    schema = _load(_FEEDBACK_REQ)
    assert schema["schema_version"] == 1
    assert "feedback_request.v1.schema.json" in schema["$id"]
    assert schema["additionalProperties"] is False
    assert set(schema["required"]) == {"session_id", "rating"}


def test_feedback_request_accepts_minimal_thumbs_up():
    _validate(
        {"session_id": "abc-123", "rating": 1},
        _load(_FEEDBACK_REQ),
    )


def test_feedback_request_accepts_thumbs_down_with_comment():
    _validate(
        {"session_id": "abc", "rating": -1, "comment": "didn't help — still offline"},
        _load(_FEEDBACK_REQ),
    )


def test_feedback_request_accepts_explicit_skip():
    _validate(
        {"session_id": "abc", "rating": 0},
        _load(_FEEDBACK_REQ),
    )


def test_feedback_request_rejects_unknown_rating():
    schema = _load(_FEEDBACK_REQ)
    for bad in (2, -2, 5, 0.5, "yes", None):
        with pytest.raises(jsonschema.ValidationError):
            _validate({"session_id": "a", "rating": bad}, schema)


def test_feedback_request_rejects_missing_session_id():
    schema = _load(_FEEDBACK_REQ)
    with pytest.raises(jsonschema.ValidationError):
        _validate({"rating": 1}, schema)


def test_feedback_request_rejects_extra_fields():
    """Closed schema discipline — extra fields cannot sneak in via the BLE proxy."""
    schema = _load(_FEEDBACK_REQ)
    with pytest.raises(jsonschema.ValidationError):
        _validate(
            {"session_id": "a", "rating": 1, "phone_context": {"foo": "bar"}},
            schema,
        )


def test_feedback_request_caps_comment_length():
    schema = _load(_FEEDBACK_REQ)
    # max 2000 — boundary
    _validate({"session_id": "a", "rating": 1, "comment": "x" * 2000}, schema)
    with pytest.raises(jsonschema.ValidationError):
        _validate({"session_id": "a", "rating": 1, "comment": "x" * 2001}, schema)


# ---------------------------------------------------------------------------
# feedback_log_line schema
# ---------------------------------------------------------------------------

def test_feedback_log_line_schema_exists_and_versioned():
    schema = _load(_FEEDBACK_LOG)
    assert schema["schema_version"] == 1
    assert "feedback_log_line.v1.schema.json" in schema["$id"]
    assert schema["additionalProperties"] is False


def test_feedback_log_line_required_fields_match_spec():
    schema = _load(_FEEDBACK_LOG)
    assert set(schema["required"]) == {
        "ts", "session_id", "user_rating", "verdict_summary",
        "actions_taken", "anonymized_transcript_uploaded",
    }


def test_feedback_log_line_accepts_full_entry():
    _validate({
        "ts": "2026-05-24T10:15:30Z",
        "session_id": "sess-1",
        "user_rating": 1,
        "verdict_summary": "kubo wedged; restart fixed it",
        "actions_taken": [
            {"action_id": "a1", "action": "docker.restart",
             "tier": 2, "executed": True},
        ],
        "comment": "worked great",
        "anonymized_transcript_uploaded": False,
    }, _load(_FEEDBACK_LOG))


def test_feedback_log_line_accepts_session_detached_entry():
    """Session evicted from container memory before feedback arrived —
    log line still valid with empty verdict_summary + empty actions_taken."""
    _validate({
        "ts": "2026-05-24T10:15:30Z",
        "session_id": "sess-orphan",
        "user_rating": -1,
        "verdict_summary": "",
        "actions_taken": [],
        "anonymized_transcript_uploaded": False,
    }, _load(_FEEDBACK_LOG))


def test_feedback_log_line_rejects_invalid_action_tier():
    schema = _load(_FEEDBACK_LOG)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "ts": "2026-05-24T10:15:30Z",
            "session_id": "s",
            "user_rating": 0,
            "verdict_summary": "",
            "actions_taken": [
                {"action_id": "a", "action": "x", "tier": 4, "executed": True},
            ],
            "anonymized_transcript_uploaded": False,
        }, schema)


def test_feedback_log_line_caps_actions_taken_size():
    schema = _load(_FEEDBACK_LOG)
    too_many = [
        {"action_id": f"a{i}", "action": "x", "tier": 2, "executed": True}
        for i in range(11)
    ]
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "ts": "2026-05-24T10:15:30Z",
            "session_id": "s",
            "user_rating": 1,
            "verdict_summary": "",
            "actions_taken": too_many,
            "anonymized_transcript_uploaded": False,
        }, schema)


def test_feedback_log_line_anonymized_field_required():
    """Must be explicitly set on every write — defaulting to false is the
    container's job, but the schema enforces presence so we can never read
    a log line and be unsure whether transcript was uploaded."""
    schema = _load(_FEEDBACK_LOG)
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "ts": "2026-05-24T10:15:30Z",
            "session_id": "s",
            "user_rating": 1,
            "verdict_summary": "",
            "actions_taken": [],
        }, schema)


def test_feedback_log_line_no_phone_context_field():
    """Privacy contract from Phase 11 carries over: phone_context-bearing
    fields MUST NOT appear in feedback log either (closed schema enforces
    via additionalProperties:false)."""
    schema = _load(_FEEDBACK_LOG)
    assert "phone_context" not in schema["properties"]
    with pytest.raises(jsonschema.ValidationError):
        _validate({
            "ts": "2026-05-24T10:15:30Z",
            "session_id": "s",
            "user_rating": 1,
            "verdict_summary": "",
            "actions_taken": [],
            "anonymized_transcript_uploaded": False,
            "phone_context": {"wifi_ssid": "leak"},
        }, schema)


# ---------------------------------------------------------------------------
# ble_commands.json — ai/feedback registered
# ---------------------------------------------------------------------------

def test_ble_manifest_has_feedback_command():
    d = _load(_BLE_MANIFEST)
    by_name = {c["name"]: c for c in d["commands"]}
    assert "ai/feedback" in by_name
    cmd = by_name["ai/feedback"]
    assert cmd["type"] == "exec"
    assert cmd["proxy_url"] == "http://127.0.0.1:8083/feedback"
    assert cmd["timeout_s"] == 10


def test_ble_manifest_count_is_at_least_18_after_phase_16():
    d = _load(_BLE_MANIFEST)
    assert len(d["commands"]) >= 18


def test_ai_feedback_not_in_require_approval_path():
    """Feedback is local-only — no HMAC approval token, no security_code.
    Sanity: ai/feedback MUST NOT carry require_approval like ai/execute does."""
    d = _load(_BLE_MANIFEST)
    by_name = {c["name"]: c for c in d["commands"]}
    cmd = by_name["ai/feedback"]
    assert cmd.get("require_approval") is not True


# ---------------------------------------------------------------------------
# api/README.md — Phase 16 contract section
# ---------------------------------------------------------------------------

def test_readme_has_phase_16_section():
    with open(_API_README) as f:
        text = f.read()
    assert "Phase 16 additions" in text
    assert "feedback_request.schema.json" in text
    assert "feedback_log_line.schema.json" in text
    assert "POST /feedback" in text
    assert "/var/log/fula/ai-feedback.jsonl" in text


def test_readme_documents_session_detached_acceptance():
    """The container's 'accept feedback after session eviction' behaviour
    is non-obvious — must be documented so the cross-repo container author
    doesn't 404 these requests."""
    with open(_API_README) as f:
        text = f.read()
    # Loosely match the contract wording
    assert "evicted" in text or "STILL accept" in text


def test_readme_calls_out_no_central_upload():
    with open(_API_README) as f:
        text = f.read()
    assert "NOT a central upload channel" in text or "NOT a central" in text
