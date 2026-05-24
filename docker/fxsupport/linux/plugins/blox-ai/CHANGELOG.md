# Blox AI plugin — changelog

Format follows [Keep a Changelog](https://keepachangelog.com/). All dates UTC.

## [Unreleased] — Blox AI plan completion (Phases 6–22)

### Added — Plugin substrate (Phase 6)
- Repurposed the unused `loyal-agent` plugin slot as `blox-ai`. Old-slot artifacts cleaned up automatically by `install.sh`.
- `info.json`, `docker-compose.yml`, lifecycle scripts.
- `ble_commands.json` registers `ai/*` + `diag/*` via the Phase 1.9 core plugin-extension hook.

### Added — Runbook + whitelist (Phase 7)
- `runbook.md` (~50 KB) of symptom→diagnostic→action recipes.
- `action_whitelist.json` enumerating tier-1/2/3 actions + per-action argument constraints.
- docker-compose volume mounts for `/run:ro`, `/var/log/fula`, docker.sock, runbook, whitelist.

### Added — Model swap (Phase 8)
- Qwen2.5-3B-Instruct RKLLM W8A8 replaces prior Deepseek-LLM-7B-Chat (model URL + SHA in `download_model.sh`).
- Size threshold lowered to 2.5 GB minimum.
- SHA verification duplicated in `start.sh` (Codex catch).
- Hoisted placeholder-fail check in `install.sh` so unreplaced `__SET_BEFORE_RELEASE__` markers fail fast.
- Old Deepseek model file deleted after successful Qwen verification (user override — disk reclamation priority).

### Added — Container API contract (Phase 9)
- `api/sse_events.schema.json` v3 — discriminated union over 10 SSE event variants.
- `api/diag_responses.schema.json` — 11 `diag/*` endpoint shapes.
- `api/README.md` — cross-repo container contract.

### Added — Action executor + audit (Phase 10)
- `api/execute_action_request.schema.json` + `api/audit_log_line.schema.json`.
- HMAC approval token contract (per-container-start rotation + nonce LRU).
- Tier-3 security code at `/etc/fula/blox-ai/security-code` (default `1234`, user-rotatable).
- `fula.sh` boot setup creates `/run/fula-ai`, `/etc/fula/blox-ai`, security-code file with idempotent guards.
- Audit log `/var/log/fula/ai-actions.jsonl` (append-only, 50 MB rotation).

### Added — Conversational state + phone context (Phase 11)
- SSE schema bumped to v3: `session_started`, `user_question`, `user_reply_received`.
- `api/user_reply_request.schema.json`, `api/phone_context.schema.json`, `api/phone_context_request.schema.json`.
- Privacy contract: phone_context never persisted, never echoed in logs.

### Added — App chat UI + approval + phone-context share (Phase 12, apps/box uncommitted)
- `ApprovalModal.tsx` with tier-2 single-tap + tier-3 security code + 2-second press-and-hold.
- `BloxAIChat.tsx` renders all 10 SSE event variants.
- `phoneLogger.ts` with NetInfo subscriber, AsyncStorage ring buffers, `gatherContext()`.
- `SharePhoneContextModal.tsx` previews payload before send.

### Added — Stability adds (Phase 13)
- `check_container_oom()` writes `/run/fula-containers.state` matching Phase 9 schema.
- `check_power_health()` reads RK3588 sysfs + dmesg → `/run/fula-power.state`.
- Kubo / cluster API hang escalation behind `KUBO_HANG_ESCALATION=1` env flag.

### Added — Isolated-mode staging (Phase 14)
- `isolation_mode.py` + `blox-ai-isolation.{service,timer}` (6h cadence, `Persistent=true`).
- LED slow-blink magenta via existing `.command_led` flag-file (no new core LED needed).
- `/var/log/fula/ai-pending-actions.jsonl` (10 MB one-deep rotation).

### Added — Pending actions panel (Phase 15, apps/box uncommitted)
- `PendingActionsPanel.tsx` + `parsePendingResponse.ts` defensive parser.

### Added — End-of-session feedback (Phase 16)
- `api/feedback_request.schema.json` + `api/feedback_log_line.schema.json`.
- `ai/feedback` BLE command (18 commands total now).
- Session-detached acceptance: feedback received after session eviction is still logged with empty verdict/actions.
- apps/box uncommitted: `FeedbackModal.tsx` + `buildFeedbackPayload.ts` with CR/LF-strip + trim.

### Added — Runbook fast-iteration plumbing (Phase 17)
- `runbook_frontmatter.py` stdlib parser; `reload_runbook.sh` SIGHUP wrapper.
- Schema-version bump forces full restart (refuses SIGHUP swap); downgrade-protection on `is_newer_than()`.
- Verified on lab device (`pi@192.168.68.107`, RK3588).

### Added — Model rollback path (Phase 18)
- `api/ai_manifest.schema.json` — manifest with required `current` + `rollback` ModelEntries.
- `model_manifest.py` selector emits shell-eval'able overrides for `download_model.sh`.
- `download_model.sh` reads manifest pre-amble; hardcoded URL+SHA stay as fallback.
- Verified on lab device.

### Added — Fine-tune pipeline sub-plan (Phase 19)
- Sub-plan document at `~/.claude/plans/fula-ai-training-pipeline.md` decomposes the LoRA train → RKLLM compile → CDN publish flow into 9 sub-phases.

### Added — Transcript intake server (Phase 20)
- New repo `functionland/fula-ai-training` (pushed). FastAPI server, anonymized-transcript schema, defense-in-depth PII scanner, idempotent on-disk persistence, per-IP + global rate limit, X-Forwarded-For trust gated by env var.
- Source IP never persisted alongside transcripts; generic 400 errors prevent schema fingerprinting; bucket isolation via write-only IAM identity.

### Added — On-device anonymizer + opt-in upload (Phase 21, apps/box uncommitted)
- `anonymizeTranscript.ts` strips IPv4/IPv6/peerId/CID/home-path/SSID/BSSID, converts ISO timestamps to relative offsets.
- IPv6 regex aligned across JS + Python (handles `::` compression).
- `UploadTranscriptModal.tsx` — preview anonymized JSON, default-cancel-on-dismiss, no auto-retry on failure, no per-device history kept.
- `TRANSCRIPT_UPLOAD_URL` constant + targeted tests for the HTTPS-only / fx.land-only invariants.
- Cross-runtime drift gate: paired tests in apps/box jest + server pytest using the same fixture file ensure JS anonymizer output is exactly what the server schema accepts.

### Added — Documentation (Phase 22)
- `plugins/blox-ai/README.md` — overview + install/uninstall + privacy posture + security boundary + troubleshooting table.
- `plugins/blox-ai/PLAYBOOK.md` — operator triage runbook (canary roll-out cadence, rollback procedure, runbook reload, audit log interpretation, isolation-mode tuning, transcript-server rejection waves).
- `plugins/blox-ai/CHANGELOG.md` — this file.

### Test coverage at plan close
- fula-ota: **485 pytest** across 22 phases + earlier work, all green locally (one environmental `test_relay_drift` failure unrelated to plan).
- fula-ai-training: **30 pytest** on the intake server (server happy-path, all schema violations, PII scanner classes, idempotency, rate limit, cross-runtime drift gate).
- apps/box: **161 jest** across Phase 12 + 15 + 16 + 21 helpers + baseline. (Two failed Phase 5 suites unrelated to plan.)
- Lab evidence: `E:/fxblox/evidence/phase-{13,14,17-18}/` populated for the phases that touched the host directly.

### Branches / repos pushed at plan close
- `functionland/fula-ota` branch `blox-ai`: pushed (commits `fd0cb4e` Phases 13–14, `475c6e5` Phases 16–18; Phase 22 docs pending commit).
- `functionland/fula-ai-training` branch `main`: pushed (initial scaffold commit `e7bbb0e`; Phase 21 cross-runtime fixture pending commit).
- `apps/box`: working tree only across Phase 12 + 15 + 16 + 21 — needs a bundled commit decision before final release.
