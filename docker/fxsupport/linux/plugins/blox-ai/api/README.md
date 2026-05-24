# Blox AI API contract (Phase 9)

This directory holds the JSON Schema contracts that the cross-repo
`functionland/blox-ai` Docker image MUST satisfy. Bind-mounted into the
container at `/etc/fula/blox-ai/api/` (read-only) by
[../docker-compose.yml](../docker-compose.yml).

## Files

- **`sse_events.schema.json`** — Discriminated union over 6 event types
  emitted by `POST /troubleshoot`'s SSE stream. The container MUST
  validate each event before emit; malformed events leave the LLM
  ungrounded and crash the app's transcript renderer.

- **`diag_responses.schema.json`** — Per-endpoint response shapes for
  the 11 `GET /diag/*` endpoints. The container MUST validate response
  bodies before returning. `diag/summary` is intentionally a ROLL-UP
  (overall + per-subsystem severity) — not a literal union of the other
  diag responses — to keep the LLM's context cost low on the first
  diagnostic turn.

## What the container MUST do

1. **Load both schemas at container start.** Refuse to start if either
   schema fails JSON Schema Draft 2020-12 validation.

2. **Validate every emitted SSE event** against `sse_events.schema.json`
   before sending to the client. Treat validation failure as an
   internal bug (log + emit a synthetic `error` event with
   `code: "SCHEMA_VIOLATION"` and `recoverable: false`).

3. **Validate every `diag/*` response body** against the matching
   `$defs` entry in `diag_responses.schema.json` before returning HTTP
   200. Schema-failing responses become HTTP 500.

4. **Treat `tool_call.payload.tool` enum as the source of truth for
   which `diag/*` tools exist.** Don't introduce new tool names in the
   container without first updating `sse_events.schema.json` +
   `ble_commands.json` in fula-ota.

## What this Phase ships (and what it doesn't)

Phase 9 ships only 6 SSE event types:
`thought`, `tool_call`, `tool_result`, `verdict`, `recommended_action`, `error`.

NOT shipped here (intentionally — separate phases):
- `execution_result` — Phase 10 (`/execute-action` endpoint)
- `user_question`, `user_reply_received` — Phase 11 (conversational
  multi-turn)

If you find yourself wanting to emit one of those in Phase 9 code,
something's wrong with the phase scoping. Surface to fula-ota.

## Cross-repo sync

The schemas are versioned via `$id` URL (`...sse_events.v1.schema.json`)
+ a top-level `schema_version: 1` field. Breaking changes bump both.

For the cross-repo container's CI:
- **Preferred**: vendor the two schema files via a `git submodule` or a
  CI step that `curl`s the raw github URLs from fula-ota's main branch.
  Pin to a fula-ota release tag for reproducibility.
- **Acceptable**: copy-paste with a comment marker linking back to the
  fula-ota source, plus a CI check that detects drift.

The schemas' `$id` is the authoritative identifier — keep it stable
across container restarts so cross-repo validators can pin to it.

## Phase 10 additions (current)

`sse_events.schema.json` bumped to `schema_version: 2` and `$id` to
`...v2.schema.json`. Additions:
- `execution_result` event variant — emitted by `POST /execute-action`
  after the executor finishes (success, failure, or rejection).

New schema files:
- `execute_action_request.schema.json` — request body for
  `POST /execute-action`. Shape: `{action_id, approval_token, security_code?}`.
- `audit_log_line.schema.json` — line shape for
  `/var/log/fula/ai-actions.jsonl`. Container writes one line per
  request (executed OR rejected) for forensic completeness.

### Executor contract (cross-repo container MUST implement)

**1. HMAC approval token, per-container-start rotation.**
- At container start: read 32 bytes from `/dev/urandom`, write hex to
  `/run/fula-ai/approval-secret` mode 0600 root:root.
- When emitting a `recommended_action` event: sign
  `(action_id|expires_at|nonce)` with HMAC-SHA256 of the secret;
  serialize as `base64url(json({action_id, expires_at, nonce, hmac}))`.
- `expires_at` is iso8601 UTC = now + 300 s (5-minute window).
- `nonce` is a fresh `secrets.token_urlsafe(16)` per token.

**2. Token validation on /execute-action.**
- Decode the base64url JSON.
- Reject if `expires_at < now` → `rejected_reason: approval_token_expired`.
- Reject if nonce was previously seen this container-lifetime (in-memory
  LRU keyed by nonce, TTL = 5 min) → `rejected_reason: approval_token_replayed`.
- Reject if HMAC verification fails →
  `rejected_reason: approval_token_invalid`.
- Reject if `action_id` in token doesn't match request →
  `rejected_reason: approval_token_invalid`.

**3. Whitelist enforcement.**
- Load `/etc/fula/action_whitelist.json` at container start (NOT `/etc/fula/blox-ai/action_whitelist.json` — that path is a Phase 10 documentation error caught by Codex post-impl HIGH; the actual `docker-compose.yml` mount target is `/etc/fula/action_whitelist.json` since Phase 7).
- Reject if `action` not in tier_1 / tier_2 / tier_3 lists →
  `rejected_reason: action_not_in_whitelist`.
- Reject if `args` violate `argument_constraints` →
  `rejected_reason: args_constraint_violation`.
- Tier-3 actions: require `security_code` field, compare against
  contents of `/etc/fula/blox-ai/security-code` (read on each request,
  no caching, strip trailing whitespace). Missing/empty file →
  `rejected_reason: security_code_file_missing`. Mismatch →
  `rejected_reason: security_code_invalid`.

**4. Serialize execution.**
- Global asyncio.Lock (or equivalent) — one action at a time per
  container. If another execution is in flight, return
  `rejected_reason: executor_busy` with HTTP 429.

**5. Append-only audit log.**
- Open `/var/log/fula/ai-actions.jsonl` with `O_APPEND`. Never truncate
  or seek.
- Write one line per request (executed OR rejected) per
  `audit_log_line.schema.json`.
- Truncate stdout/stderr to 2048 bytes each before logging (Gemini HIGH
  — log injection + disk exhaustion mitigation).
- NEVER log: the secret, the full approval_token, secrets in args,
  the security_code value.
- Rotate at 50 MB (matches Phase 1's events.jsonl convention).

**6. Execution.**
- For `maps_to_core: true` actions (`reset`, `partition`, `node_delete`,
  `ipfs_delete`, `force_update`, `restart_fula`, `restart_uniondrive`):
  touch the flag file at `/home/pi/commands/.command_<name>` via the
  docker.sock bind-mounted into a tiny exec helper, OR use the existing
  BLE command server's protocol. See container implementation notes.
- For `docker.restart` / `systemctl.restart` / `systemctl.reset-failed`
  / `wireguard.bounce` / `ntp.resync`: run the corresponding command
  via `docker exec` (for docker.restart) or `nsenter --target 1`
  (for systemctl on host). Strict regex validation on every arg
  before shell composition (Gemini HIGH — nsenter is the ultimate
  privilege escalation surface).

### HTTP status mapping (Codex post-impl MEDIUM-HIGH)

Every `/execute-action` request MUST be audited BEFORE returning a
response. The HTTP status conveys the outcome category:

| Status | When |
|---|---|
| `200` | Request was authorized + action subprocess ran. SSE `execution_result` carries `success: bool` (true even if exit_code != 0 — that's an action failure, not a request failure). |
| `400` | Schema validation failed (malformed request body, missing fields). |
| `401` | `approval_token` invalid (HMAC mismatch) OR expired OR replayed. Audit logs the specific `rejected_reason`. |
| `403` | Action not in whitelist OR args violate constraints OR tier-3 security_code missing/invalid OR security-code file missing. |
| `429` | Another action in flight (`executor_busy`). Client should retry after the in-flight action's `expected_duration_s`. |
| `500` | Internal error in the executor itself (e.g. failed to write audit log). |

Nonce consumption ordering: consume the nonce ONLY after HMAC + expiry pass.
Otherwise an attacker who knows the action_id format can pre-burn legitimate nonces.

### Trust boundary (explicit)

`docker.sock` mounted into this container ALREADY implies host-root-
equivalent capability. The HMAC approval-token scheme is NOT defense-
in-depth against a compromised container — anyone who compromises the
container can spawn privileged containers via docker.sock anyway. The
HMAC is defense against the **confused deputy**: a malicious or buggy
phone client (or a poisoned LLM session) sending `/execute-action`
calls the user never approved. The token must originate from a
`recommended_action` event THIS container emitted in this lifetime.

### Tier-3 security code: what it protects + what it doesn't

`/etc/fula/blox-ai/security-code` is a confirmation gate, NOT a
cryptographic lock. Default value `1234` provides essentially zero
protection against a motivated attacker who has bypassed BLE pairing.
It protects against:
- Accidental destructive taps in the app UI.
- A buggy or malicious phone client that knows the BLE protocol but
  doesn't know the device's specific code (after rotation).

It does NOT protect against:
- A motivated attacker with the rotated code (e.g. shoulder-surfing).
- A compromised container (which can read the file directly).
- A compromised phone client paired with the device.

**Users SHOULD rotate the code**: `sudo nano /etc/fula/blox-ai/security-code`
on the device, restart the blox-ai container (or just edit and let the
next tier-3 read pick it up). The phone app's tier-3 confirmation
dialog accepts any 4-digit code, so the user sets a code they remember.

## Phase 11+ extensions

Phase 11 will add `user_question` + `user_reply_received` for the
multi-turn conversational flow. Same `schema_version` bump treatment
(v3 + $id .v3.) per the closed-schema discipline.
