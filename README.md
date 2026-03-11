# Fula OTA

Over-the-air update system for FxBlox devices and PCs. Manages Docker-based services for IPFS storage, cluster pinning, auto-pinning, and the Fula protocol on ARM64 hardware (RK3588/RK1) and x86_64 desktops (Windows/Linux/macOS).

## Architecture Overview

Each Fula node runs nine Docker containers orchestrated by `docker-compose`:

```
+---------------------+     +-------------------+     +---------------------+
|     fxsupport       |     |       kubo        |     |    ipfs-cluster     |
| (alpine, scripts)   |     | (ipfs/kubo:release|     | (functionland/      |
|                     |     |  bridge network)  |     |  ipfs-cluster)      |
| Carries all config  |     |                   |     |  host network       |
| and scripts in      |     | Ports: 4001, 5001 |     |  Ports: 9094-9096   |
| /linux/ directory   |     |  8080, 8081       |     |                     |
+---------------------+     +---+---------------+     +---------------------+
         |                       |           ^
         | docker cp to         | IPFS       | pin/add, pin/ls
         | /usr/bin/fula/       | block      |
         v                      | storage  +-+-----------------+   +-------------------+
+----------------------------+  |          |   fula-pinning    |   |   fula-gateway     |
| /uniondrive (merged)      |  |          | (auto-pin daemon) |   | (S3-compatible     |
| union-drive.sh (mergerfs) |  |          | host network      |   |  storage gateway)  |
+----------------------------+  |          | Port: 3501        |   | host network       |
         |                      |          +---+---+-----------+   | Port: 9000         |
+--------+--------+     +------+------+        |   |               +--------+-----------+
|    go-fula       |     |  kubo-local |   Syncs |   | registry.cid        |
| (functionland/   |     | (ipfs/kubo  |   pins  |   +----> shared file --+
|  go-fula)        |     |  :release)  |   from  |         /internal/fula-gateway/
|  host network    |     |  bridge     |  remote |
|  Port: 40001     |     | Port: 5002  | pinning |
+------------------+     +-------------+         |
                         +---------------------+ |
                         |  watchtower          | |
                         |  auto-update         | |
                         |  every 3600s         | |
                         +---------------------+ |
                         +---------------------+ |
                         |  fula.service        | |
                         |  (systemd)           | |
                         |  runs fula.sh        | |
                         +---------------------+ |
```

### Container Details

| Container | Image | Network | Purpose |
|-----------|-------|---------|---------|
| `fula_fxsupport` | `functionland/fxsupport:release` | default | Carries scripts and config files. Acts as a delivery mechanism — `fula.sh` copies `/linux/` from this container to `/usr/bin/fula/` on the host. |
| `ipfs_host` | `ipfs/kubo:release` | bridge | Main IPFS node. Stores blocks on `/uniondrive`. Config template at `kubo/config`, runtime config at `/home/pi/.internal/ipfs_data/config`. |
| `ipfs_local` | `ipfs/kubo:release` | bridge | Local-only IPFS node for fula-gateway and fula-pinning. Separate IPFS repo at `/internal/ipfs_data_local`. Port 5002 (localhost only). |
| `ipfs_cluster` | `functionland/ipfs-cluster:release` | host | IPFS Cluster follower node. Manages pin replication across the network. Config at `/uniondrive/ipfs-cluster/service.json`. |
| `fula_go` | `functionland/go-fula:release` | host | Fula protocol: blockchain proxy (ports 4020/4021), libp2p blox (port 40001), WAP server (port 3500). |
| `fula_pinning` | `functionland/fula-pinning:release` | host | Auto-pinning daemon. Syncs pins from a remote IPFS Pinning Service to local kubo. Writes `registry.cid` for fula-gateway. See [docker/fula-pinning/README.md](docker/fula-pinning/README.md). |
| `fula_gateway` | `functionland/fula-gateway:release` | host | Local S3-compatible gateway. Serves the paired user's files from local kubo on port 9000 (LAN only). Auth via pairing secret from `box_props.json`. |
| `fula_updater` | `containrrr/watchtower:latest` | default | Polls Docker Hub hourly for updated images, auto-restarts containers. |

### Networking

- **kubo** and **kubo-local** run in Docker bridge networking (ports mapped: `4001:4001`, `5001:5001`, `5002:5002`)
- **go-fula**, **ipfs-cluster**, **fula-pinning**, and **fula-gateway** run with `network_mode: "host"` (direct host networking)
- go-fula cannot reach kubo at `127.0.0.1` from host network — it uses the `docker0` bridge IP (typically `172.17.0.1`), auto-detected in `go-fula/blox/kubo_proxy.go`
- **Docker Compose bridge caveat**: Compose creates its own bridge interfaces (`br-<hash>`), not `docker0`. Firewall rules must match `-i br-+` (iptables wildcard) in addition to `-i docker0`.
- **fula-gateway** reaches kubo at `127.0.0.1:5001` via host network (kubo's port mapping), serves S3 API on `0.0.0.0:9000` (LAN-only via firewall)
- **PC installer networking**: All services run in bridge mode (`fula-net`) since Docker Desktop doesn't support host networking on Windows/macOS. kubo's LAN and public IP are injected into `Addresses.AppendAnnounce` so it advertises reachable addresses to the DHT.

### Storage Layout

```
/uniondrive/                    # mergerfs mount (union of all attached drives)
  ipfs_datastore/blocks/        # IPFS block storage (flatfs)
  ipfs_datastore/datastore/     # IPFS metadata (pebble)
  ipfs-cluster/                 # Cluster state, service.json, identity.json
  ipfs_staging/                 # IPFS staging directory

/home/pi/.internal/             # Device-internal state (Armbian)
  ipfs_data/config              # Deployed kubo config (runtime)
  ipfs_data_local/config        # Local kubo config (runtime)
  ipfs_config                   # Template copy (used by initipfs)
  config.yaml                   # Fula device config (pool, authorizer, etc.)
  box_props.json                # Pairing credentials (JWT, secret, endpoint)
  fula-gateway/registry.cid     # Bucket registry CID (written by fula-pinning)

/usr/bin/fula/                  # On-host scripts and configs (copied from fxsupport)
  fula.sh                       # Main orchestrator script
  docker-compose.yml            # Container definitions
  .env                          # Image tags (GO_FULA, FX_SUPPROT, IPFS_CLUSTER)
  .env.cluster                  # Cluster env var overrides
  kubo/config                   # Kubo config template
  kubo/kubo-container-init.d.sh # Kubo init script
  kubo-local/config-local       # Local kubo config template
  kubo-local/kubo-local-container-init.d.sh  # Local kubo init script
  ipfs-cluster/ipfs-cluster-container-init.d.sh  # Cluster init script
  update_kubo_config.py         # Selective kubo config merger
  union-drive.sh                # UnionDrive mount management
  bluetooth.py                  # BLE command handler
  local_command_server.py       # Local TCP command server
  control_led.py                # LED control
  readiness-check.py            # Health monitoring and auto-recovery
  commands.sh                   # File-based command handler (reboot, LED, partition)
  firewall.sh                   # iptables firewall rules
  plugins/                      # Plugin system
  ...
```

### Identity System

Each Fula node has two peer IDs derived from a single private key:

- **Cluster Peer ID**: The original `peer.IDFromPrivateKey(identity)` — used for on-chain pool membership and IPFS Cluster identity
- **Kubo Peer ID**: HMAC-SHA256 derived with domain `"fula-kubo-identity-v1"` — used for IPFS kubo identity (prevents collision with cluster)

go-fula uses the cluster peer ID for `discoverPoolAndChain()` membership checks, while kubo uses the derived peer ID.

### Auto-Pinning (fula-pinning)

The `fula-pinning` daemon replicates data from the remote Fula Storage API to this device's local IPFS node. The local blox is a **sync consumer only** — uploads go to the remote Fula Gateway S3 server, not to this device:

```
User uploads via S3 API -> remote Fula Gateway -> stores in Gateway's Kubo + pins on Remote Pinning Service
                                                                                       |
fula-pinning daemon (this device) <-- fetches pin list every 3 min (user's JWT) -------+
        |
        +---> pins missing CIDs on local Kubo (fetches data via IPFS P2P network)
```

**User isolation**: The daemon uses the paired user's JWT (`auto_pin_token`) to query the pinning service. The service only returns pins belonging to that token, so the local kubo only pins the paired user's data.

**Configuration**: Pairing credentials are stored in `/home/pi/.internal/box_props.json`:
```json
{
  "auto_pin_token": "user-jwt-token",
  "auto_pin_endpoint": "https://api.pinata.cloud/psa",
  "auto_pin_pairing_secret": "local-api-secret"
}
```

The daemon monitors this file every 30 seconds — pair/unpair/rotate tokens without restarting the container. When unpaired (empty token/endpoint), the daemon idles.

**Local HTTP API** (port 3501, requires `Bearer {pairing_secret}`):
- `GET /api/v1/auto-pin/status` — pinned count, last/next sync times
- `POST /api/v1/auto-pin/report-missing` — request immediate pinning of specific CIDs

See [docker/fula-pinning/README.md](docker/fula-pinning/README.md) for full documentation.

### Local S3 Gateway (fula-gateway)

The `fula-gateway` container is a standalone Rust binary (`fula-local-gateway`) that provides an S3-compatible API for local file access. It uses `fula-core` and `fula-blockstore` crates from [fula-api](https://github.com/functionland/fula-api) as shared libraries, but contains no cloud code.

```
FxFiles (client-side encryption/decryption)
    |
    +-- Remote: S3 API -> s3.cloud.fx.land:443 -> remote fula-cli -> remote kubo
    |
    +-- Local (LAN): S3 API -> blox-ip:9000 -> local fula-gateway -> local kubo
                                                     ^
                                              registry.cid written by
                                              fula-pinning daemon
```

**Key features**:
- **Bearer-only auth**: Uses `auto_pin_pairing_secret` from `box_props.json`. When unpaired, auth is disabled (safe — port 9000 is LAN-only via firewall).
- **User scoping**: Derives owner ID from BLAKE3 hash of JWT `sub` claim. All bucket operations are scoped to the paired user.
- **Multipart uploads**: Full lifecycle support (`create_multipart_upload`, `upload_part`, `complete_multipart_upload`). Creates unified DAG via `put_ipld()` for multi-part files.
- **CID watcher**: Polls `/internal/fula-gateway/registry.cid` every 30 seconds, reloads bucket registry when CID changes.
- **Content CID header**: Always returns `X-Fula-Content-Cid` header on object responses.
- **Registry persistence**: Uses `persist_registry()` (no token) for local operation.
- **mDNS**: go-fula advertises `s3Port=9000` in mDNS TXT records so FxFiles discovers the local gateway automatically.

**Firewall**: Port 9000 is restricted to RFC1918 private addresses only (192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12).

### Health Monitoring (Armbian)

The `readiness-check.py` script runs as a systemd service and provides comprehensive health monitoring:

- **Container health**: Monitors all 8 containers, detects crashes and error logs
- **Config validation**: Detects YAML invalid control characters, auto-restores from backup if corrupted
- **PeerID collision detection**: Detects and fixes kubo/cluster PeerID collisions by regenerating cluster identity
- **Proxy health**: Checks go-fula proxy ports (4020, 40001) reachability
- **Disk space**: Triggers `docker system prune` if <1GB free
- **Kubo config**: Strips deprecated Provider/Reprovider fields (kubo 0.40+)
- **LED status**: Green=healthy, Yellow=restarting, Blue=restarted, Red=critical failure
- **Auto-recovery**: Up to 4 restart attempts, then activates WireGuard fallback and triggers re-partition after 12+ hours of failure

### Plugin System

Optional plugins extend device functionality. Each plugin includes `install.sh`, `start.sh`, `stop.sh`, `uninstall.sh`, a `docker-compose.yml`, and an `info.json` manifest.

| Plugin | Purpose | Requirements |
|--------|---------|-------------|
| **streamr-node** | Runs a Streamr node to earn $DATA token rewards | Port 32200 forwarding |
| **loyal-agent** | Local AI agent using NPU (deepseek-llm-7b-chat model) | 32GB RAM, 10GB storage, ARM64 only |

Active plugins are tracked in `/home/pi/active-plugins.txt`. The PC installer excludes hardware-specific plugins (e.g. `loyal-agent`).

### Command Handler

The `commands.sh` script watches `/home/pi/commands/` via `inotifywait` for file-based commands:

| Command File | Action |
|-------------|--------|
| `.command_partition` | Runs `resize.sh` for disk repartitioning |
| `.command_repairfs` | Runs `repairfs.sh` for external storage filesystem repair |
| `.command_led` | Sets LED color/duration (file content: `color duration`) |
| `.command_reboot` | Triggers system reboot |

## PC Installer

The `pc-installer/` directory contains an Electron desktop application that brings the full Fula node stack to Windows, Linux, and macOS PCs via Docker Desktop.

### Key Differences from Armbian

| Aspect | Armbian (fula.sh) | PC Installer (Electron) |
|--------|-------------------|------------------------|
| Runtime | Bash scripts on bare metal | Electron GUI + Node.js managers |
| Docker networking | Mixed (host for go-fula, bridge for kubo) | All bridge (`fula-net`) |
| Firewall | `iptables` rules | Windows Firewall rules via Squirrel hooks |
| Storage paths | Fixed: `/home/pi`, `/media/pi` | User-chosen `dataDir` + `storageDir` |
| Health monitoring | `readiness-check.py` (systemd) | Real-time `HealthMonitor` + tray icon colors |
| mDNS | Python `advertisement.py` | Node.js `bonjour-service` with interface detection |
| Hardware ID | ARM cpuinfo hash | SHA-256 of first non-internal MAC address |
| UI | CLI only | Setup wizard (6 steps) + dashboard |

### Architecture

```
src/main/
  index.js              # Main entry, IPC handlers, lifecycle orchestration
  constants.js          # Ports, container names, bootstrap peers
  config-store.js       # Electron-store config persistence
  docker-manager.js     # Docker Compose lifecycle, waitForDocker(), ghost container cleanup
  health-monitor.js     # Continuous health checks, auto-recovery, Docker recovery
  tray-manager.js       # System tray icon + context menu (color = health status)
  storage-manager.js    # Directory tree init, template copying
  mdns-advertiser.js    # mDNS advertisement via bonjour-service
  update-manager.js     # Stale image detection
  plugin-manager.js     # Plugin extraction from fxsupport container
  logger.js             # Winston-based logging (file + console)

src/renderer/
  wizard/               # Setup wizard UI (terms, Docker check, storage, ports, pull, launch)
  dashboard/            # Dashboard UI (containers, logs, health, plugins)
```

### Features

- **Setup wizard**: 6-step guided setup (terms, Docker check, storage selection, port availability, image pull, launch)
- **System tray**: Color-coded health status (green/yellow/red/blue/cyan/grey)
- **Health monitor**: Continuous checks for container health, kubo API, relay connection, bootstrap peers, proxy ports, cluster errors, config validity, disk space, PeerID collision
- **Docker Desktop recovery**: Detects unresponsive Docker daemon, kills and relaunches Docker Desktop, waits for recovery. Health monitor triggers recovery after 3 consecutive failures.
- **mDNS**: Advertises `_fulatower._tcp` with device properties (bloxPeerIdString, authorizer, hardwareID, ipfsClusterID, s3Port). Polls go-fula `/properties` every 60s to update.
- **kubo network hardening**: Injects LAN + public IP into `AppendAnnounce`, forces `Libp2pForceReachability=private` for relay-v2 (AutoNAT can't work in Docker bridge)
- **Template sync**: `scripts/sync-shared-templates.js` copies kubo/cluster configs from Armbian sources, transforming bridge DNS names where needed (`127.0.0.1:5001` -> `kubo:5001`)
- **Windows install hooks**: Squirrel installer creates Start Menu shortcuts, adds Windows Firewall rules (mDNS UDP 5353, services TCP 3500/4001/9000/9094) via UAC-elevated PowerShell

### Data Directory Layout (PC)

```
{dataDir}/                       # e.g. E:\.fula or %LOCALAPPDATA%\FulaData
  config/
    docker-compose.pc.yml        # Container orchestration
    .env.pc                      # Image tags and paths
    .env.cluster                 # Cluster identity and bootstrap
    .env.gofula                  # go-fula env (HARDWARE_ID injected at runtime)
    kubo/config                  # Kubo config template
    kubo-local/config-local      # Local kubo config template
    ipfs-cluster/                # Cluster init script
  internal/
    config.yaml                  # Fula device config
    box_props.json               # Pairing credentials
    ipfs_data/config             # Kubo runtime config
    ipfs_data_local/config       # Local kubo runtime config
    fula-gateway/registry.cid    # Bucket registry CID
    plugins/                     # Extracted plugins
  storage/                       # IPFS block storage (or separate storageDir)
  logs/
    fula-node.log                # Application logs
```

## Update Propagation Flow

How code changes in this repo reach devices:

```
1. Push to GitHub repo
2. GitHub Actions builds Docker images (on release) OR manual build
3. Images pushed to Docker Hub (functionland/fxsupport:release, etc.)
4. Watchtower on device detects updated images (polls hourly)
5. fula.service triggers: fula.sh start
6. First restart() — runs with CURRENT on-device files
7. docker cp fula_fxsupport:/linux/. /usr/bin/fula/ — copies NEW files from updated fxsupport image
8. If fula.sh itself changed -> second restart() — runs with NEW files
```

### Config Merge Flow (kubo)

On every `fula.sh start` (before `docker-compose up`):

1. `update_kubo_config.py` (or inline fallback in `fula.sh`) runs
2. Reads the **template** (`/usr/bin/fula/kubo/config`) and the **deployed** config (`/home/pi/.internal/ipfs_data/config`)
3. Merges only **managed fields** (Bootstrap, Peering, Swarm, Experimental, Routing, etc.) from template into deployed config
4. **Preserved fields** (Identity, Datastore paths, API/Gateway addresses) are never touched
5. Dynamic `StorageMax` is calculated as 80% of `/uniondrive` total space (minimum 800GB floor)
6. Writes updated deployed config, then runs `docker-compose up`

### Config Flow (ipfs-cluster)

1. `.env.cluster` is loaded by docker-compose as `env_file` (injects env vars into container)
2. `.env.cluster` is also bind-mounted at `/.env.cluster` inside the container
3. `ipfs-cluster-container-init.d.sh` runs as entrypoint:
   - Waits for pool name from `config.yaml`
   - Generates cluster secret from pool name
   - Runs `jq` to patch `service.json` with connection_manager, pubsub, batching, timeouts, informer settings
   - Starts `ipfs-cluster-service daemon` with bootstrap address

## Repository Structure

```
fula-ota/
  docker/
    build_and_push_images.sh    # Builds all images and pushes to Docker Hub
    env_release.sh              # ARM64 release env vars (image names, tags)
    env_release_amd64.sh        # AMD64 release env vars
    env_test.sh                 # ARM64 test env vars
    env_test_amd64.sh           # AMD64 test env vars
    run.sh                      # Local dev docker-compose runner
    fxsupport/
      Dockerfile                # alpine + COPY ./linux -> /linux
      build.sh                  # buildx build + push
      linux/                    # All on-device scripts and configs
        docker-compose.yml      # Container orchestration (9 services)
        .env                    # Docker image tags
        .env.cluster            # Cluster env var overrides
        fula.sh                 # Main orchestrator (start/stop/restart/rebuild)
        union-drive.sh          # mergerfs mount management
        update_kubo_config.py   # Selective kubo config merger
        readiness-check.py      # Health monitoring and auto-recovery (1500+ lines)
        commands.sh             # File-based command handler (reboot, LED, partition)
        firewall.sh             # iptables firewall rules
        kubo/
          config                # Kubo config template
          kubo-container-init.d.sh
        kubo-local/
          config-local          # Local kubo config template
          kubo-local-container-init.d.sh
        ipfs-cluster/
          ipfs-cluster-container-init.d.sh
        bluetooth.py            # BLE setup and command handling
        local_command_server.py # TCP command server
        control_led.py          # LED control for device status
        plugins/                # Plugin system (loyal-agent, streamr-node)
        ...
    fula-pinning/
      Dockerfile                # Go build stage + alpine runtime
      build.sh                  # buildx build + push
      *.go                      # Daemon source: config, sync loop, HTTP server, kubo/pinning clients
      README.md                 # Full service documentation
    fula-gateway/
      build.sh                  # buildx build from fula-local-gateway/
      download_image.sh         # Pull pre-built image from Docker Hub
      fula-local-gateway/       # Standalone Rust binary
        Cargo.toml              # Uses fula-core + fula-blockstore as git deps
        Dockerfile              # Rust build stage + debian runtime
        src/
          main.rs               # CLI, config loading, kubo wait loop
          server.rs             # Axum router, CID watcher spawn
          auth.rs               # Bearer-token middleware
          box_props.rs          # JWT sub extraction, BLAKE3 owner ID
          state.rs              # AppState, IPFS connection, CID watcher
          handlers/             # S3 API handlers (bucket, object, multipart, service)
          ...
    go-fula/
      Dockerfile                # Go build stage + alpine runtime
      build.sh                  # Clones go-fula repo, buildx build + push
      go-fula.sh                # Container entrypoint
    ipfs-cluster/
      Dockerfile                # Go build stage + alpine runtime
      build.sh                  # Clones ipfs-cluster repo, buildx build + push
  pc-installer/                 # Electron desktop app for Windows/Linux/macOS
    package.json                # Electron 40, electron-forge
    forge.config.js             # Build config (Squirrel/DEB/ZIP)
    scripts/
      sync-shared-templates.js  # Copies Armbian configs with bridge transforms
    templates/                  # PC-specific Docker compose, env files
    src/
      main/                     # Electron main process (10 manager modules)
      renderer/                 # Wizard + Dashboard UI
      preload.js                # IPC bridge
  .github/workflows/
    docker-image.yml            # Release CI: ARM64 images + tar upload
    docker-image-test.yml       # ARM64 test build (all services)
    docker-image-selective-test.yml  # Selective service test build
    docker-image-amd64-test.yml     # AMD64 test build
    docker-image-amd64-release.yml  # AMD64 release build
    pc-installer-release.yml    # PC installer build (Windows .exe + Linux .deb)
  tests/                        # Shell-based test scripts
    README.md                   # Test documentation
    test-config-validation.sh   # Scan for stale config references
    test-docker-setup.sh        # Validate Docker Compose syntax and env vars
    test-container-dependencies.sh  # Analyze service dependencies and startup order
    test-fula-sh-functions.sh   # Test fula.sh install/update/run operations
    test-docker-services.sh     # Test container runtime behavior
    test-uniondrive-readiness.sh    # Test uniondrive and readiness-check
    test-go-fula-system-integration.sh  # WiFi, hotspot, storage, network tests
    test-device-hardening.sh    # Full production update flow on real RK3588
  install-ubuntu.sh             # Ubuntu/Debian automated installer
```

## Prerequisites

### Docker Engine (Armbian/Linux)

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
```

Optionally manage Docker as a non-root user ([docs](https://docs.docker.com/engine/install/linux-postinstall/#manage-docker-as-a-non-root-user)):

```bash
sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker
```

### Docker Desktop (PC Installer)

The PC installer requires [Docker Desktop](https://www.docker.com/products/docker-desktop/) on Windows and macOS. The setup wizard checks for Docker Desktop and provides install instructions if missing.

### Docker Compose

```bash
sudo curl -L "https://github.com/docker/compose/releases/download/v2.16.0/docker-compose-$(uname -s)-$(uname -m)" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose
```

### NetworkManager

```bash
sudo systemctl start NetworkManager
sudo systemctl enable NetworkManager
```

### Dependencies

```bash
sudo apt-get install gcc python3-dev python-is-python3 python3-pip
sudo apt-get install python3-gi python3-gi-cairo gir1.2-gtk-3.0
sudo apt install net-tools dnsmasq-base rfkill lshw
```

### Automount (Armbian only)

Raspberry Pi OS handles auto-mounting natively. On Armbian, set up automount:

#### 1. Install dependencies

```bash
sudo apt install net-tools dnsmasq-base rfkill git
```

#### 2. Create automount script

```bash
sudo nano /usr/local/bin/automount.sh
```

```bash
#!/bin/bash

MOUNTPOINT="/media/pi"
DEVICE="/dev/$1"
MOUNTNAME=$(echo $1 | sed 's/[^a-zA-Z0-9]//g')
mkdir -p ${MOUNTPOINT}/${MOUNTNAME}

FSTYPE=$(blkid -o value -s TYPE ${DEVICE})

if [ ${FSTYPE} = "ntfs" ]; then
    mount -t ntfs -o uid=pi,gid=pi,dmask=0000,fmask=0000 ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
elif [ ${FSTYPE} = "vfat" ]; then
    mount -t vfat -o uid=pi,gid=pi,dmask=0000,fmask=0000 ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
else
    mount ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
    chown pi:pi ${MOUNTPOINT}/${MOUNTNAME}
fi
```

```bash
sudo chmod +x /usr/local/bin/automount.sh
```

#### 3. Create udev rules and service

```bash
sudo nano /etc/udev/rules.d/99-automount.rules
```

```
ACTION=="add", KERNEL=="sd[a-z][0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}="automount@%k.service"
ACTION=="add", KERNEL=="nvme[0-9]n[0-9]p[0-9]", TAG+="systemd", ENV{SYSTEMD_WANTS}="automount@%k.service"

ACTION=="remove", KERNEL=="sd[a-z][0-9]", RUN+="/bin/systemctl stop automount@%k.service"
ACTION=="remove", KERNEL=="nvme[0-9]n[0-9]p[0-9]", RUN+="/bin/systemctl stop automount@%k.service"
```

```bash
sudo nano /etc/systemd/system/automount@.service
```

```ini
[Unit]
Description=Automount disks
BindsTo=dev-%i.device
After=dev-%i.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/automount.sh %I
ExecStop=/usr/bin/sh -c '/bin/umount /media/pi/$(echo %I | sed 's/[^a-zA-Z0-9]//g'); /bin/rmdir /media/pi/$(echo %I | sed 's/[^a-zA-Z0-9]//g')'
```

```bash
sudo udevadm control --reload-rules
sudo systemctl daemon-reload
```

## Device Installation

### Armbian (ARM64)

```bash
git clone https://github.com/functionland/fula-ota
cd fula-ota/docker/fxsupport/linux
sudo bash ./fula.sh rebuild
sudo bash ./fula.sh start
```

### Ubuntu/Debian (automated)

```bash
curl -fsSL https://raw.githubusercontent.com/functionland/fula-ota/main/install-ubuntu.sh | sudo bash
```

The `install-ubuntu.sh` script handles: OS detection, dependency installation, Docker setup, repo cloning, automount configuration, and systemd service enablement. Supports Ubuntu 22.04+ (Jammy, Lunar, Mantic, Noble).

### Windows/macOS/Linux PC

Download the installer from [GitHub Releases](https://github.com/functionland/fula-ota/releases):
- Windows: `.exe` (Squirrel installer)
- Linux: `.deb` package

The setup wizard guides through Docker Desktop verification, storage selection, port checks, image pulling, and service launch.

## Building and Pushing Docker Images

### Production Release (pushes to Docker Hub)

```bash
cd docker
source env_release.sh        # ARM64
# or: source env_release_amd64.sh   # AMD64
bash ./build_and_push_images.sh
```

This builds and pushes all images:
- `functionland/fxsupport:release`
- `functionland/go-fula:release`
- `functionland/ipfs-cluster:release`
- `functionland/fula-pinning:release`
- `functionland/fula-gateway:release`

### Test Build and Deploy Workflow

Use test-tagged images (e.g. `test147`) to validate changes on a device before promoting to `release`.

#### Step 1: Set the test tag

`env_test.sh` defaults to `test147`. Override at runtime without editing the file:

```bash
cd docker

# Use default tag (test147):
source env_test.sh

# Or override:
TEST_TAG=test148 source env_test.sh
```

This exports all image tags with your tag and writes a matching `.env` file.

#### Step 2: Build test images

**Option A: GitHub Actions (recommended)**

Trigger one of these workflows manually from the Actions tab:
- `docker-image-test.yml` — builds all ARM64 images with the test tag
- `docker-image-amd64-test.yml` — builds all AMD64 images
- `docker-image-selective-test.yml` — selectively build individual services (checkbox per service, custom tag override)

**Option B: Local build + push to Docker Hub**

```bash
cd docker
source env_test.sh          # or: TEST_TAG=test148 source env_test.sh
bash ./build_and_push_images.sh
```

**Option C: On-device build (no Docker Hub push)**

```bash
# Build fxsupport (seconds — just file copies)
cd /tmp/fula-ota/docker/fxsupport
sudo docker build --load -t functionland/fxsupport:test147 .

# Build go-fula (requires Go compilation)
cd /tmp/fula-ota/docker/go-fula
git clone -b main https://github.com/functionland/go-fula
sudo docker build --load -t functionland/go-fula:test147 .

# Build ipfs-cluster (requires Go compilation)
cd /tmp/fula-ota/docker/ipfs-cluster
git clone -b master https://github.com/ipfs-cluster/ipfs-cluster
sudo docker build --load -t functionland/ipfs-cluster:test147 .
```

#### Step 3: Deploy to device

If you built with Options A or B (images pushed to Docker Hub), just update `.env` and restart:

```bash
# 1. Update .env to use test tags
sudo tee /usr/bin/fula/.env << 'EOF'
GO_FULA=functionland/go-fula:test147
FX_SUPPROT=functionland/fxsupport:test147
IPFS_CLUSTER=functionland/ipfs-cluster:test147
FULA_PINNING=functionland/fula-pinning:test147
FULA_GATEWAY=functionland/fula-gateway:test147
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
EOF

# 2. Restart fula — it will pull test147 images from Docker Hub and start them
sudo systemctl restart fula
```

That's it. `fula.sh` runs `docker-compose pull --env-file .env` which pulls whatever tags are in `.env`. Watchtower also respects the running container's tag — it will check for updates to `:test147`, not `:release`.

The `docker cp` step (which copies files from `fula_fxsupport` to `/usr/bin/fula/`) is also safe: the `fxsupport:test147` image was built with `env_test.sh`, so the `.env` baked inside it already has test tags.

> **Note**: `FULA_PINNING` and `FULA_GATEWAY` are optional in `.env`. The `docker-compose.yml` uses default fallbacks (e.g. `${FULA_GATEWAY:-functionland/fula-gateway:release}`), so older `.env` files without these variables will still work.

**If you built on-device (Option C)**, you must also block Docker Hub so `fula.sh` doesn't pull release images over your local builds:

```bash
# Block Docker Hub BEFORE restarting
sudo bash -c 'echo "127.0.0.1 index.docker.io registry-1.docker.io" >> /etc/hosts'
sudo systemctl restart fula
```

#### Step 4: Verify

```bash
# Check running images have correct tags
sudo docker ps --format '{{.Names}}\t{{.Image}}'
# Expected: fula_go -> functionland/go-fula:test147, etc.

# Check logs
sudo docker logs fula_go --tail 50
sudo docker logs ipfs_host --tail 50
sudo docker logs ipfs_cluster --tail 50
```

#### Step 5: Revert to production

```bash
# 1. If Docker Hub was blocked, unblock it
sudo sed -i '/index.docker.io/d' /etc/hosts

# 2. Restore release .env
sudo tee /usr/bin/fula/.env << 'EOF'
GO_FULA=functionland/go-fula:release
FX_SUPPROT=functionland/fxsupport:release
IPFS_CLUSTER=functionland/ipfs-cluster:release
FULA_PINNING=functionland/fula-pinning:release
FULA_GATEWAY=functionland/fula-gateway:release
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
EOF

# 3. Restart fula (will pull release images)
sudo systemctl restart fula
```

#### Gotchas

- **On-device builds need Docker Hub blocked**: `fula.sh` runs `docker-compose pull` on every restart if internet is available. This pulls from Docker Hub using tags from `.env`. For remote-built test images (Options A/B), this is fine — it pulls your `:test147` images. But for on-device builds (Option C), the pull would overwrite your local images with Docker Hub versions. Block Docker Hub in `/etc/hosts` for on-device builds.
- **Watchtower tag matching**: Watchtower checks for updates to the exact tag the container is running. Containers running `:test147` won't be replaced with `:release`.
- **`docker cp` and `.env`**: On every restart, `fula.sh` copies files from `fula_fxsupport` container to `/usr/bin/fula/`, including `.env`. This is safe when using test images built through `env_test.sh` (the `.env` inside the image matches your test tags). Use `stop_docker_copy.txt` only if you manually edited `.env` on-device without rebuilding fxsupport.
- **`stop_docker_copy.txt` expires after 24 hours**: If needed, this file in `/home/pi/` blocks the `docker cp` step. Expires after 24h — touch it again to extend.
- **Docker Compose bridge != docker0**: Docker Compose creates its own bridge interfaces (`br-<hash>`), not `docker0`. Firewall rules matching `-i docker0` don't cover Compose bridges. Must also match `-i br-+` (iptables wildcard). This can cause kubo->go-fula proxy traffic to be silently dropped.
- **`((var++))` with `set -e`**: In bash, post-increment `((0++))` evaluates to 0 (falsy), returning exit code 1, which kills the script under `set -e`. Use pre-increment `((++var))` instead.

## Testing Changes on a Live Device

### Method 1: Build fxsupport locally on device (recommended for script/config changes)

If you only changed files under `docker/fxsupport/linux/` (scripts, configs, env files):

```bash
# On the device:
cd /tmp && git clone --depth 1 https://github.com/functionland/fula-ota.git
cd /tmp/fula-ota/docker/fxsupport
sudo docker build --load -t functionland/fxsupport:release .
sudo docker stop fula_updater
sudo systemctl restart fula
```

### Method 2: Build all images locally on device

```bash
# Build fxsupport (seconds)
cd /tmp/fula-ota/docker/fxsupport
sudo docker build --load -t functionland/fxsupport:release .

# Build ipfs-cluster (requires Go compilation)
cd /tmp/fula-ota/docker/ipfs-cluster
git clone -b master https://github.com/ipfs-cluster/ipfs-cluster
sudo docker build --load -t functionland/ipfs-cluster:release .

# Build go-fula (requires Go compilation)
cd /tmp/fula-ota/docker/go-fula
git clone -b main https://github.com/functionland/go-fula
sudo docker build --load -t functionland/go-fula:release .

# Stop watchtower, restart
sudo docker stop fula_updater
sudo systemctl restart fula
```

### Method 3: Copy files directly (skip Docker build entirely)

For rapid iteration, copy files directly and prevent `fula.sh` from overwriting them via `docker cp`:

```bash
# 1. Copy changed files
sudo cp /tmp/fula-ota/docker/fxsupport/linux/.env.cluster /usr/bin/fula/.env.cluster
sudo cp /tmp/fula-ota/docker/fxsupport/linux/ipfs-cluster/ipfs-cluster-container-init.d.sh /usr/bin/fula/ipfs-cluster/ipfs-cluster-container-init.d.sh
sudo cp /tmp/fula-ota/docker/fxsupport/linux/kubo/config /usr/bin/fula/kubo/config
sudo cp /tmp/fula-ota/docker/fxsupport/linux/fula.sh /usr/bin/fula/fula.sh
sudo cp /tmp/fula-ota/docker/fxsupport/linux/update_kubo_config.py /usr/bin/fula/update_kubo_config.py

# 2. Block docker cp from overwriting your files (valid for 24 hours)
touch /home/pi/stop_docker_copy.txt

# 3. Restart using your files
sudo /usr/bin/fula/fula.sh restart

# 4. When done testing, remove the block so normal OTA updates resume
rm /home/pi/stop_docker_copy.txt
```

## Testing

The `tests/` directory contains shell-based test scripts organized into three categories:

### Validation Tests
- `test-config-validation.sh` — Scans scripts and configs for stale references
- `test-docker-setup.sh` — Validates Docker Compose syntax and environment variables
- `test-container-dependencies.sh` — Analyzes service dependencies and startup order

### Core Component Tests
- `test-fula-sh-functions.sh` — Tests fula.sh install/update/run operations
- `test-docker-services.sh` — Tests container runtime behavior
- `test-uniondrive-readiness.sh` — Tests uniondrive service and readiness-check.py

### System Integration Tests
- `test-go-fula-system-integration.sh` — WiFi, hotspot, storage, network tests
- `test-device-hardening.sh` — Full production update flow on real RK3588 hardware

Run tests from the project root:
```bash
./tests/test-config-validation.sh
./tests/test-docker-setup.sh
# Device tests (require hardware):
sudo bash ./tests/test-device-hardening.sh --build --deploy --verify --finish
```

See [tests/README.md](tests/README.md) for full documentation.

## CI/CD Workflows

| Workflow | Trigger | Purpose |
|----------|---------|---------|
| `docker-image.yml` | GitHub release | ARM64 release build, uploads watchtower tar |
| `docker-image-test.yml` | Manual | ARM64 test build (all services) |
| `docker-image-selective-test.yml` | Manual | Selective service build (checkbox per service) |
| `docker-image-amd64-test.yml` | Manual | AMD64 test build |
| `docker-image-amd64-release.yml` | GitHub release | AMD64 release build |
| `pc-installer-release.yml` | GitHub release | Windows .exe + Linux .deb installer build |

### Verification Commands

```bash
# Kubo StorageMax (should be ~80% of drive size, min 800GB)
cat /home/pi/.internal/ipfs_data/config | jq '.Datastore.StorageMax'

# Kubo AcceleratedDHTClient
cat /home/pi/.internal/ipfs_data/config | jq '.Routing.AcceleratedDHTClient'
# Expected: true

# Cluster connection_manager
cat /uniondrive/ipfs-cluster/service.json | jq '.cluster.connection_manager'
# Expected: high_water: 400, low_water: 100

# Cluster concurrent_pins
cat /uniondrive/ipfs-cluster/service.json | jq '.pin_tracker.stateless.concurrent_pins'
# Expected: 5

# Cluster batching
cat /uniondrive/ipfs-cluster/service.json | jq '.consensus.crdt.batching'
# Expected: max_batch_size: 100, max_batch_age: "1m"

# Fula-pinning status (requires pairing secret)
curl -s -H "Authorization: Bearer YOUR_PAIRING_SECRET" http://127.0.0.1:3501/api/v1/auto-pin/status | jq .
# Expected: {"paired":true,"total_pinned":N,...}

# Fula-pinning logs
docker logs fula_pinning --tail 20

# Fula-gateway health (no auth)
curl -s http://127.0.0.1:9000/healthz
# Expected: 200 OK

# Fula-gateway bucket listing (requires pairing secret)
curl -s -H "Authorization: Bearer YOUR_PAIRING_SECRET" http://127.0.0.1:9000/ | head -20
# Expected: XML bucket listing

# Fula-gateway logs
docker logs fula_gateway --tail 20

# Registry CID (written by fula-pinning, read by fula-gateway)
cat /home/pi/.internal/fula-gateway/registry.cid

# IPFS repo stats
docker exec ipfs_host ipfs repo stat

# IPFS DHT status (should show full routing table with AcceleratedDHTClient)
docker exec ipfs_host ipfs stats dht

# Cluster peers
docker exec ipfs_cluster ipfs-cluster-ctl peers ls | wc -l
```

## fula.sh Commands

Command | Description
--- | ---
`start` | Start all containers (runs config merge, docker-compose up).
`restart` | Same as start.
`stop` | Stop all containers (docker-compose down).
`rebuild` | Full rebuild: install dependencies, copy files, docker-compose build.
`update` | Pull latest docker images.
`install` | Run the initial installer.
`help` | List all commands.

## Key Configuration Files

### `.env.cluster` - Cluster Environment Overrides

Env vars injected into the ipfs-cluster container. Key settings:

| Variable | Value | Purpose |
|----------|-------|---------|
| `CLUSTER_CONNMGR_HIGHWATER` | 400 | Max peer connections (prevents 60-node ceiling) |
| `CLUSTER_CONNMGR_LOWWATER` | 100 | Connection pruning target |
| `CLUSTER_MONITORPINGINTERVAL` | 60s | How often peers ping the monitor |
| `CLUSTER_STATELESS_CONCURRENTPINS` | 5 | Parallel pin operations (lower for ARM I/O) |
| `CLUSTER_IPFSHTTP_PINTIMEOUT` | 15m0s | Timeout for individual pin operations |
| `CLUSTER_PINRECOVERINTERVAL` | 8m0s | How often to retry failed pins |

### `kubo/config` - Kubo Config Template

Template for IPFS node configuration. Managed fields are merged into the deployed config on every restart. Key settings:

- `AcceleratedDHTClient: true` - Full Amino DHT routing table with parallel lookups
- `StorageMax: "800GB"` - Static fallback; dynamically set to 80% of drive on startup
- `ConnMgr.HighWater: 200` - IPFS swarm connection limit
- `Libp2pStreamMounting: true` - Required for go-fula p2p protocol forwarding

### `update_kubo_config.py` - Config Merger

Selectively merges managed fields from template into deployed config while preserving device-specific settings (Identity, Datastore). Runs on every `fula.sh start`.

## Notes

- **Watchtower** polls Docker Hub every 3600 seconds (1 hour). After pushing new images, devices update within the next polling cycle.
- **`stop_docker_copy.txt`** — when this file exists in `/home/pi/` and was modified within the last 24 hours, `fula.sh` skips the `docker cp` step. Useful for testing local file changes without them being overwritten.
- **Kubo** uses the upstream `ipfs/kubo:release` image (not custom-built). Only the config template and init script are customized.
- **go-fula**, **ipfs-cluster**, and **fula-pinning** are custom-built from source in their respective Dockerfiles using Go 1.25.
- **fula-gateway** is a standalone Rust binary built from `docker/fula-gateway/fula-local-gateway/`. It uses `fula-core` and `fula-blockstore` crates from [fula-api](https://github.com/functionland/fula-api) as shared libraries but contains no cloud code.
- **fula-pinning** and **fula-gateway** run with `no-new-privileges:true` (no elevated privileges needed).
- All other containers except kubo run with `privileged: true` and `CAP_ADD: ALL`.
- **Dead containers**: Docker Compose can leave Dead containers with project labels. These prevent `--no-recreate` from creating new containers. `fula.sh` and the PC installer purge ghost containers via `docker ps -a --filter "label=com.docker.compose.project=fula" -q | xargs -r docker rm -f` before starting.
