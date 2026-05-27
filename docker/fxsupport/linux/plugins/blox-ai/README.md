# Blox AI

On-device AI troubleshooting plugin for Fula edge devices (RK3588). Runs locally on the Rockchip NPU, reads structured device state, proposes fixes with reasoning, and executes user-approved actions through a hardened whitelist.

This plugin repurposes the historically-unused `loyal-agent` slot — old installs get cleaned up automatically by the install script.

## Why this exists

Users keep reporting "my Blox is disconnected." The actual root cause is almost always something the device-side stack can detect (kubo wedged, WG handshake stale, NTP drift, RK3588 undervoltage, ext4 corruption, captive portal, the user's phone offline). Without an on-device troubleshooter, every report meant a manual support roundtrip. Blox AI cuts that loop by diagnosing on the device and surfacing a one-tap fix in the phone app.

## What it ships

| Component | Where | What |
|---|---|---|
| Model | `/uniondrive/blox-ai/model/qwen3-1.7b-rk3588-w8a8.rkllm` | ~2.0-2.4 GB, RKLLM W8A8, Qwen 3 with thinking mode, downloaded SHA-verified on install |
| Runtime | `functionland/blox-ai:latest` container, port 8083 | Inference loop + tool-calling + `/troubleshoot` SSE + `/execute-action` |
| Runbook | `runbook.md` (bind-mounted into container) | Symptom→diagnostic→action recipes the model loads as system prompt |
| Action whitelist | `action_whitelist.json` (bind-mounted) | The HARD boundary the executor enforces; AI cannot invent actions |
| BLE registration | `ble_commands.json` | Registers `ai/*` + `diag/*` BLE commands via the core plugin extension hook |
| Isolation timer | `blox-ai-isolation.{service,timer}` + `isolation_mode.py` | 6h cadence; stages recommendations when device is fully isolated |
| Manifest selector | `model_manifest.py` | Phase 18 rollback path; picks `current` vs `rollback` from `/etc/fula/ai-manifest.json` |
| Runbook reload | `reload_runbook.sh` + `runbook_frontmatter.py` | Phase 17 SIGHUP-based fast iteration (no full container restart) |

## Install / uninstall

The plugin lifecycle is the same as any other Fula plugin — `install.sh` / `uninstall.sh` are called by the core plugin manager. The phone app's plugin install screen handles this end-to-end.

```bash
# Manual install on the device (rare — usually OTA-pushed)
sudo bash docker/fxsupport/linux/plugins/blox-ai/install.sh

# Manual uninstall
sudo bash docker/fxsupport/linux/plugins/blox-ai/uninstall.sh
```

What `install.sh` does:
1. Cleans up any stale `loyal-agent` artifacts from the prior slot.
2. Copies the systemd unit + the BLE-command manifest into place.
3. Touches `/home/pi/commands/.command_plugin_reload` so the core BLE server re-scans plugin commands.
4. Enables + starts `blox-ai.service` and `blox-ai-isolation.timer`.
5. Kicks off `download_model.sh` in the background (~2.3 GB download).

What `uninstall.sh` does (reverse): stops + disables the service + timer, removes systemd units, removes the BLE manifest, touches reload flag. Audit logs (`/var/log/fula/ai-actions.jsonl`, `ai-pending-actions.jsonl`, `ai-feedback.jsonl`) are deliberately LEFT IN PLACE — they outlive the feature for forensic completeness. The ~2.3 GB model file is left in place by default; remove it manually if you want the disk space back.

## How it works (one-paragraph)

When the user taps "Diagnose" in the app, the app POSTs to `ai/troubleshoot` over BLE (or libp2p when reachable). The plugin's BLE proxy forwards to `http://127.0.0.1:8083/troubleshoot`. The container streams SSE events: `thought` (reasoning narration), `tool_call` (model wants to run a `diag/*` probe), `tool_result` (the probe's output), `user_question` (model needs clarification), `verdict` (root cause + severity), `recommended_action` (one or more whitelisted actions with reasoning + HMAC approval tokens). The user reviews the recommendation in a modal — tier-2 actions need one tap, tier-3 need a security code + 2-second press-and-hold. On approval, the app POSTs `ai/execute` with the approval token; the container's executor validates the token (HMAC + nonce + expiry) and the action+args against the whitelist, then runs it. Every step is audited to `/var/log/fula/ai-actions.jsonl` (append-only).

When the device is fully isolated (no libp2p traffic + no BLE session for >6 hours + discovery unreachable), the systemd timer fires `isolation_mode.py`, which runs an autonomous self-diagnostic, stages up to 3 recommendations in `/var/log/fula/ai-pending-actions.jsonl`, and sets the LED slow-blinking magenta. When the user reconnects, the app reads `ai/pending` and surfaces the staged recommendations in a "while you were away" banner.

## Privacy posture

- **No central network calls** from the plugin itself. Everything except the optional Phase 21 transcript upload (which the phone app — NOT the plugin — initiates, per user opt-in, with full payload preview) stays on the device.
- **Phone-side context** sent via `ai/phone-context` is in-memory in the container's session dict and never persists or appears in any log file. Container's logging discipline strips SSID/BSSID/IP from any validation error that echoes the value.
- **Audit logs are local.** `/var/log/fula/ai-*.jsonl` files. Pull via the BLE log fetcher when needed; no auto-upload.
- **The model is local.** No cloud inference, no per-prompt network. The only outbound call the plugin's install path makes is the SHA-verified model download from the CDN.

## Security boundary (the only thing that really matters)

`action_whitelist.json` is the trust boundary. The model can propose any action it wants; the container's executor only runs actions whose name + args match the whitelist + per-action constraint table. Tier-3 (destructive: reboot, partition expand, ipfs reset) requires a security code stored at `/etc/fula/blox-ai/security-code` (default `1234`; user-rotatable via `sudo nano`). The HMAC approval token rotates per container start and is single-use (nonce LRU); a replayed token after the container restarts is rejected.

Two things this design does NOT defend against, by deliberate trade-off:
- A compromised container has docker.sock access (required for the `docker.restart` family of tier-2 actions) and could escalate that to host root. Mitigation: trust the container image's supply chain, pin to SHA-published builds.
- A motivated attacker with the rotated security code AND a paired BLE session can run tier-3 actions. The code is a confirmation gate, not a cryptographic lock.

## LAN HTTP transport — trust-LAN posture (Plan HTTP)

Blox AI exposes port 8083 to the LAN (`firewall.sh` allows RFC1918 only;
no internet exposure). The phone app prefers LAN HTTP over BLE when both
sides are on the same network — same SSE protocol, just orders of
magnitude faster than the ~6 KB/s BLE proxy.

The exposed surface (port `${BLOX_AI_PORT:-8083}`) is reachable from any
host on the same LAN. **This is intentional**, but it carries a real
trust assumption.

### What's authenticated
- `/execute-action` — HMAC token issued per `/troubleshoot` session,
  rotated per container restart, bound to action_id + nonce + expiry.
- Tier-3 actions (reboot, partition expand, ipfs reset) additionally
  require the security code at `/etc/fula/blox-ai/security-code`.

### What's NOT authenticated (known gap)
- `/troubleshoot`, `/troubleshoot/user-reply`, `/troubleshoot/phone-context`,
  `/cancel`, `/feedback`, `/pending`, `/diag/*`, `/status`, `/health`.

A LAN attacker can:
- start their own `/troubleshoot` session and receive HMAC tokens valid
  for THAT session,
- call `/execute-action` with those tokens → execute tier-2 actions on
  the real blox (container restarts, etc.),
- read diagnostic state via `/diag/*`,
- DoS active legitimate sessions via `/cancel`.

The phone-side verification (`authorizer === appPeerId` from mDNS) blocks
the app from talking to a foreign blox, but it doesn't prevent a
foreign client from talking to YOUR blox.

### Trust model
- **Assumed-trusted**: your home/office LAN. The blox is on a network you
  control.
- **NOT trusted for LAN HTTP**: public WiFi (coffee shops, hotels,
  airports, conference centers), shared WiFi (apartment complexes,
  dorms). If you put the blox on a hostile network, the BLE-only path
  is the safer choice.

Hardening these unauthenticated endpoints is tracked as **Plan SEC**
follow-up (will require auth on `/troubleshoot` + per-device-paired
token issuance). Not addressed in Plan HTTP.

### Operator playbook

**Change the tier-3 security code from default `1234`:**
```bash
echo <new-4-digit-code> | sudo tee /etc/fula/blox-ai/security-code
sudo chmod 0600 /etc/fula/blox-ai/security-code
```

**Test LAN reachability from a peer host** (workstation/laptop on the
same LAN as the blox — do NOT run on the blox itself):
```bash
bash docker/fxsupport/linux/plugins/blox-ai/custom/lan_smoke_from_peer.sh <blox-ip>
```
The script refuses to run if it detects it's on the blox (because
localhost-to-localhost curl proves nothing about firewall reachability).

**Per-device port override** (only if 8083 collides with another service
on the LAN side — uncommon):
```bash
sudo nano /home/pi/.internal/plugins/blox-ai/.env   # set BLOX_AI_PORT=8084 (or whatever)
sudo bash /usr/bin/fula/firewall.sh                 # re-apply iptables with the new port
sudo systemctl restart blox-ai.service              # restart container with new host bind
```
The container's INTERNAL port stays 8083 — BLE proxy + uvicorn defaults
+ `ble_commands.json` all depend on that. The override changes ONLY the
host-side LAN bind. Customizing the port also requires the phone app to
know about it; today the app defaults to 8083 (mDNS TXT field
`bloxAiPort` for port discovery is planned but not shipped yet).

## Troubleshooting the troubleshooter

| Symptom | Check |
|---|---|
| App reports "AI plugin not installed" | `systemctl status blox-ai.service` — if dead, `journalctl -u blox-ai.service -n 100` |
| Model loading fails on container start | `journalctl -u blox-ai.service` for RKLLM errors; `ls -la /uniondrive/blox-ai/model/` for size + SHA |
| `ai/execute` returns 401 | Token expired (5min window) OR replayed. User must tap Approve again on a fresh `recommended_action` event |
| `ai/execute` returns 403 | Action not in whitelist OR args fail constraint OR tier-3 security-code wrong/missing |
| Manifest rollback not taking effect | `cat /etc/fula/ai-manifest.json`; check `MANIFEST_SOURCE=` line in install log after `systemctl restart blox-ai.service` |
| Runbook edit not visible in AI output | `bash docker/fxsupport/linux/plugins/blox-ai/reload_runbook.sh` then `journalctl -u blox-ai.service -n 20` for `runbook_reload` event |
| Stale audit log filling disk | Logs rotate at 50 MB primary + 5 backups; check `ls -la /var/log/fula/` — if `.1`–`.5` rotation isn't kicking in, the container's rotation discipline is broken (file a bug) |

## Where things live

```
docker/fxsupport/linux/plugins/blox-ai/
├── README.md                 (this file)
├── info.json                 plugin manifest for the core lifecycle
├── install.sh / uninstall.sh / start.sh / stop.sh
├── blox-ai.service           host-side systemd unit for the container
├── docker-compose.yml        bind mounts: /run:ro, /var/log/fula, docker.sock, runbook, whitelist
├── custom/
│   └── download_model.sh     SHA-verified RKLLM download + Phase 18 manifest hook
├── ble_commands.json         registers ai/* + diag/* via the core extension hook
├── action_whitelist.json     the HARD trust boundary
├── runbook.md                AI system-prompt content (loaded at start; SIGHUP-reloadable)
├── runbook_frontmatter.py    stdlib parser shared between host + container
├── reload_runbook.sh         SIGHUP wrapper for fast iteration
├── model_manifest.py         Phase 18 rollback selector
├── isolation_mode.py         Phase 14 autonomous self-diagnostic
├── blox-ai-isolation.service
├── blox-ai-isolation.timer
└── api/
    ├── README.md             ALL per-endpoint contracts (READ THIS BEFORE TOUCHING THE CONTAINER)
    └── *.schema.json         closed JSON Schema Draft 2020-12 contracts for every endpoint + log line
```

For container-side implementation requirements (the cross-repo `functionland/blox-ai` Docker image), the source of truth is `api/README.md`. Don't put container contracts in this file.
