# Fula Pinning Service

Auto-pinning daemon that syncs content from a remote [IPFS Pinning Service API](https://ipfs.github.io/pinning-services-api-spec/) to the local Kubo node. Ensures that data uploaded via the Fula Storage API (or any pinning-service-compatible client) is automatically replicated to this device's IPFS storage.

## Architecture

```
                         ┌──────────────────────────┐
                         │   Remote Pinning Service  │
                         │  (e.g. Pinata, Web3.storage)│
                         └────────────┬─────────────┘
                                      │ GET /pins (paginated)
                                      │ Bearer {user JWT}
                    ┌─────────────────┴──────────────────┐
                    │         fula-pinning daemon         │
                    │                                     │
                    │  ┌───────────┐   ┌──────────────┐  │
                    │  │ Sync Loop │   │ HTTP Server   │  │
                    │  │ (3 min)   │   │ :3501         │  │
                    │  └─────┬─────┘   └──────┬───────┘  │
                    │        │                │           │
                    │  ┌─────┴────────────────┴──────┐   │
                    │  │   Priority Queue (cap=100)  │   │
                    │  └─────────────────────────────┘   │
                    └─────────────────┬──────────────────┘
                                      │ POST /api/v0/pin/add
                                      │      /api/v0/pin/ls
                                      │      /api/v0/id
                                      v
                         ┌──────────────────────────┐
                         │     Local Kubo (IPFS)     │
                         │     :5001 HTTP API        │
                         └──────────────────────────┘
```

### Lifecycle

1. On startup, reads config from `/internal/box_props.json` (mounted from host)
2. If **not paired** (no token/endpoint), idles and polls config every 30 seconds
3. Once **paired**, starts the sync daemon and HTTP server
4. Every sync cycle: fetches all remote pins, compares with local Kubo pins, pins any missing CIDs
5. If config changes (token refresh, unpair/re-pair), daemon restarts automatically

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KUBO_API` | `http://127.0.0.1:5001` | Kubo HTTP API URL |
| `AUTO_PIN_PORT` | `3501` | HTTP server listen port |
| `SYNC_INTERVAL` | `3m` | Time between sync cycles |
| `PROPS_FILE` | `/internal/box_props.json` | Path to config file |

### Config File (`box_props.json`)

The daemon reads its pairing credentials from a JSON file (typically `/internal/box_props.json`, bind-mounted from `/home/pi/.internal/` on the host):

```json
{
  "auto_pin_token": "eyJhbGciOiJIUzI1NiIs...",
  "auto_pin_endpoint": "https://api.pinata.cloud/psa",
  "auto_pin_pairing_secret": "local-secret-for-http-api"
}
```

| Field | Required | Description |
|-------|----------|-------------|
| `auto_pin_token` | Yes (for pairing) | Bearer token for the remote pinning service. Typically the user's JWT. |
| `auto_pin_endpoint` | Yes (for pairing) | IPFS Pinning Service API base URL |
| `auto_pin_pairing_secret` | No | Secret for authenticating local HTTP API requests (status, report-missing) |

The daemon is **paired** when both `auto_pin_token` and `auto_pin_endpoint` are non-empty. Config is re-read every 30 seconds — update the file to pair, unpair, or rotate tokens without restarting the container.

## Docker Compose Integration

In `docker-compose.yml`:

```yaml
fula-pinning:
  image: ${FULA_PINNING:-functionland/fula-pinning:release}
  container_name: fula_pinning
  restart: unless-stopped
  network_mode: "host"
  volumes:
    - /home/pi/.internal:/internal:rw,rshared
  depends_on:
    - kubo
  environment:
    - KUBO_API=http://127.0.0.1:5001
    - AUTO_PIN_PORT=3501
    - SYNC_INTERVAL=3m
  labels:
    - "com.centurylinklabs.watchtower.enable=true"
```

Key points:
- **`network_mode: "host"`** — accesses Kubo at `127.0.0.1:5001` directly (Kubo's port is mapped to host)
- **Watchtower label** — auto-updated when new images are pushed to Docker Hub
- **`depends_on: kubo`** — ensures Kubo container starts first (daemon also waits for Kubo health check)

## HTTP API

All endpoints require `Authorization: Bearer {pairing_secret}` header (the `auto_pin_pairing_secret` from config).

### GET /api/v1/auto-pin/status

Returns current daemon status.

**Response:**
```json
{
  "paired": true,
  "total_pinned": 42,
  "total_pending": 3,
  "last_sync_at": "2026-01-15T12:00:00Z",
  "next_sync_at": "2026-01-15T12:03:00Z"
}
```

| Field | Description |
|-------|-------------|
| `paired` | Always `true` when daemon is running (unpaired = no server) |
| `total_pinned` | Number of CIDs pinned locally |
| `total_pending` | Items in the priority queue |
| `last_sync_at` | Timestamp of last completed sync cycle |
| `next_sync_at` | Estimated next sync cycle |

### POST /api/v1/auto-pin/report-missing

Request immediate pinning of specific CIDs (bypasses the sync interval). Useful when an app detects missing content.

**Request:**
```json
{
  "cids": ["bafybeigdyrzt5sfp7udm7hu76uh7y26nf3efuylqabf3oclgtqy55fbzdi", "QmXxxx..."]
}
```

**Response:**
```json
{
  "queued": 2
}
```

**Limits:**
- Max 100 CIDs per request
- 1MB request body limit
- CIDs must start with `baf` or `Qm` and be 10-200 characters
- Queue capacity: 100 (excess CIDs are dropped)

## Sync Algorithm

Each sync cycle:

1. **Fetch remote pins** — paginated `GET /pins?limit=1000` from the pinning service, using `before` cursor for pagination
2. **Fetch local pins** — `POST /api/v0/pin/ls?type=recursive` from Kubo
3. **Diff** — find CIDs present in remote but not in local
4. **Pin missing** — `POST /api/v0/pin/add?arg={cid}&recursive=true` for each missing CID
5. **Log results** — `pinned=N skipped=N failed=N`

Priority queue items (from `report-missing`) are processed between sync cycles and take precedence over the ticker.

## Data Flow: End to End

How a file uploaded via the Fula Storage API reaches this device:

```
1. Client uploads via S3 PUT → remote Fula Gateway server (not this device)
2. Gateway stores block in its own Kubo instance → returns CID
3. Gateway sends pin request to Remote Pinning Service (user's JWT as Bearer)
4. Remote Pinning Service records: "CID X is pinned for user Y"
   ...
5. fula-pinning daemon (this device) fetches pin list from Remote Pinning Service
6. Finds CID X is not pinned locally
7. Calls kubo.PinAdd(CID X, recursive=true)
8. Kubo fetches block data via IPFS P2P network (Bitswap/DHT)
9. Block is now stored and pinned locally
```

**Important**: The local FxBlox is a **sync consumer only** — it never receives uploads directly. All uploads go to the remote Fula Gateway S3 server. This device discovers new content by polling the remote pinning service and then fetches the data over the IPFS network.

**User isolation**: The daemon authenticates to the pinning service using the paired user's JWT (`auto_pin_token`). The pinning service only returns pins belonging to that token, so this device only pins the paired user's data — never other users' content.

## Building

### Docker

```bash
cd docker/fula-pinning
docker build -t fula-pinning .
```

### Local (for development)

```bash
cd docker/fula-pinning
go build -o fula-pinning .
./fula-pinning
```

Requires Go 1.25+.

## Monitoring

The `readiness-check.py` service monitors `fula_pinning` alongside other containers. If the container has been created at least once (exists in `docker ps -a`), it's included in the health check loop. If it stops running, readiness-check triggers a `fula.service` restart.

## Troubleshooting

**Daemon not starting (logs show "not paired, waiting for config...")**
- Check that `/home/pi/.internal/box_props.json` exists and contains valid `auto_pin_token` and `auto_pin_endpoint`
- The file is polled every 30 seconds — no restart needed after editing

**Sync failures ("failed to fetch remote pins")**
- Verify the pinning service endpoint is reachable: `curl -H "Authorization: Bearer TOKEN" ENDPOINT/pins`
- Check DNS resolution (container uses `8.8.8.8` and `8.8.4.4`)
- Token may have expired — update `auto_pin_token` in `box_props.json`

**Pin failures ("failed to pin CID")**
- Kubo may be unreachable: `curl -X POST http://127.0.0.1:5001/api/v0/id`
- CID may not be available on the IPFS network (no peers have the data)
- Kubo storage may be full: `docker exec ipfs_host ipfs repo stat`

**Container not monitored by readiness-check**
- The container must have run at least once to appear in `docker ps -a`
- After first successful start, readiness-check will monitor it on subsequent cycles

**Logs**
```bash
docker logs fula_pinning --tail 100
docker logs fula_pinning --since 1h
```
