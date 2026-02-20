# Fula OTA

Over-the-air update system for FxBlox devices. Manages Docker-based services for IPFS storage, cluster pinning, and the Fula protocol on ARM64 hardware (RK3588/RK1).

## Architecture Overview

Each FxBlox device runs four Docker containers orchestrated by `docker-compose`:

```
+---------------------+     +-------------------+     +---------------------+
|     fxsupport       |     |       kubo        |     |    ipfs-cluster     |
| (alpine, scripts)   |     | (ipfs/kubo:release|     | (functionland/      |
|                     |     |  bridge network)  |     |  ipfs-cluster)      |
| Carries all config  |     |                   |     |  host network       |
| and scripts in      |     | Ports: 4001, 5001 |     |  Ports: 9094-9096   |
| /linux/ directory   |     |  8081             |     |                     |
+---------------------+     +-------------------+     +---------------------+
         |                           |                          |
         | docker cp to             | IPFS block storage       | Cluster state
         | /usr/bin/fula/           | /uniondrive/ipfs_*       | /uniondrive/ipfs-cluster/
         v                          v                          v
+-------------------------------------------------------------------------+
|                        /uniondrive (merged storage)                     |
|                    union-drive.sh (mergerfs mount)                      |
+-------------------------------------------------------------------------+
         |                                                      |
+--------+--------+     +-------------------+     +-------------+--------+
|    go-fula       |     |    watchtower     |     |  fula.service       |
| (functionland/   |     | (auto-updates)   |     |  (systemd)          |
|  go-fula)        |     | polls Docker Hub |     |  runs fula.sh       |
|  host network    |     | every 3600s      |     |                     |
|  Port: 40001     |     +-------------------+     +---------------------+
+------------------+
```

### Container Details

| Container | Image | Network | Purpose |
|-----------|-------|---------|---------|
| `fula_fxsupport` | `functionland/fxsupport:release` | default | Carries scripts and config files. Acts as a delivery mechanism — `fula.sh` copies `/linux/` from this container to `/usr/bin/fula/` on the host. |
| `ipfs_host` | `ipfs/kubo:release` | bridge | IPFS node. Stores blocks on `/uniondrive`. Config template at `kubo/config`, runtime config at `/home/pi/.internal/ipfs_data/config`. |
| `ipfs_cluster` | `functionland/ipfs-cluster:release` | host | IPFS Cluster follower node. Manages pin replication across the network. Config at `/uniondrive/ipfs-cluster/service.json`. |
| `fula_go` | `functionland/go-fula:release` | host | Fula protocol: blockchain proxy, libp2p blox, WAP server. |
| `fula_updater` | `containrrr/watchtower:latest` | default | Polls Docker Hub hourly for updated images, auto-restarts containers. |

### Networking

- **kubo** runs in Docker bridge networking (ports mapped: `4001:4001`, `5001:5001`)
- **go-fula** and **ipfs-cluster** run with `network_mode: "host"` (direct host networking)
- go-fula cannot reach kubo at `127.0.0.1` from host network — it uses the `docker0` bridge IP (typically `172.17.0.1`), auto-detected in `go-fula/blox/kubo_proxy.go`

### Storage Layout

```
/uniondrive/                    # mergerfs mount (union of all attached drives)
  ipfs_datastore/blocks/        # IPFS block storage (flatfs)
  ipfs_datastore/datastore/     # IPFS metadata (pebble)
  ipfs-cluster/                 # Cluster state, service.json, identity.json
  ipfs_staging/                 # IPFS staging directory

/home/pi/.internal/             # Device-internal state
  ipfs_data/config              # Deployed kubo config (runtime)
  ipfs_config                   # Template copy (used by initipfs)
  config.yaml                   # Fula device config (pool, authorizer, etc.)

/usr/bin/fula/                  # On-host scripts and configs (copied from fxsupport)
  fula.sh                       # Main orchestrator script
  docker-compose.yml            # Container definitions
  .env                          # Image tags (GO_FULA, FX_SUPPROT, IPFS_CLUSTER)
  .env.cluster                  # Cluster env var overrides
  kubo/config                   # Kubo config template
  kubo/kubo-container-init.d.sh # Kubo init script
  ipfs-cluster/ipfs-cluster-container-init.d.sh  # Cluster init script
  update_kubo_config.py         # Selective kubo config merger
  union-drive.sh                # UnionDrive mount management
  bluetooth.py                  # BLE command handler
  local_command_server.py       # Local TCP command server
  control_led.py                # LED control
  ...
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
    build_and_push_images.sh    # Builds all 3 images and pushes to Docker Hub
    env_release.sh              # Release env vars (image names, tags, branches)
    env_test.sh                 # Test env vars (test tags)
    env_release_amd64.sh        # AMD64 release env vars
    run.sh                      # Local dev docker-compose runner
    fxsupport/
      Dockerfile                # alpine + COPY ./linux -> /linux
      build.sh                  # buildx build + push
      linux/                    # All on-device scripts and configs
        docker-compose.yml      # Container orchestration
        .env                    # Docker image tags
        .env.cluster            # Cluster env var overrides
        fula.sh                 # Main orchestrator (start/stop/restart/rebuild)
        union-drive.sh          # mergerfs mount management
        update_kubo_config.py   # Selective kubo config merger
        kubo/
          config                # Kubo config template
          kubo-container-init.d.sh
        ipfs-cluster/
          ipfs-cluster-container-init.d.sh
        bluetooth.py            # BLE setup and command handling
        local_command_server.py # TCP command server
        control_led.py          # LED control for device status
        plugins/                # Optional plugin system (loyal-agent, streamr-node)
        ...
    go-fula/
      Dockerfile                # Go build stage + alpine runtime
      build.sh                  # Clones go-fula repo, buildx build + push
      go-fula.sh                # Container entrypoint
    ipfs-cluster/
      Dockerfile                # Go build stage + alpine runtime
      build.sh                  # Clones ipfs-cluster repo, buildx build + push
  .github/workflows/
    docker-image.yml            # Release CI: builds all images + uploads .tar to GitHub release
    docker-image-test.yml       # Test CI
  tests/                        # Shell-based test scripts
  install-ubuntu.sh             # Ubuntu installation script
```

## Prerequisites

### Docker Engine

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

```bash
git clone https://github.com/functionland/fula-ota
cd fula-ota/docker/fxsupport/linux
sudo bash ./fula.sh rebuild
sudo bash ./fula.sh start
```

## Building and Pushing Docker Images

### Production Release (pushes to Docker Hub)

```bash
cd docker
source env_release.sh
bash ./build_and_push_images.sh
```

This builds and pushes all three images:
- `functionland/fxsupport:release`
- `functionland/go-fula:release`
- `functionland/ipfs-cluster:release`

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

This exports all three image tags (`fxsupport`, `go-fula`, `ipfs-cluster`) with your tag and writes a matching `.env` file.

#### Step 2: Build test images

**Option A: GitHub Actions (recommended)**

Trigger the `docker-image-test.yml` workflow manually from the Actions tab. This builds `fxsupport` and `go-fula` with the test tag configured in `env_test.sh` and pushes to Docker Hub.

> **Note:** The test workflow currently does NOT build `ipfs-cluster`. Build it locally (Option B) or use the release image for that component.

**Option B: Local build + push to Docker Hub**

```bash
cd docker
source env_test.sh          # or: TEST_TAG=test148 source env_test.sh
bash ./build_and_push_images.sh
```

This builds and pushes all three images:
- `functionland/fxsupport:<tag>`
- `functionland/go-fula:<tag>`
- `functionland/ipfs-cluster:<tag>`

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

```bash
# 1. Update .env to use test tags
sudo tee /usr/bin/fula/.env << 'EOF'
GO_FULA=functionland/go-fula:test147
FX_SUPPROT=functionland/fxsupport:test147
IPFS_CLUSTER=functionland/ipfs-cluster:test147
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
EOF

# 2. Stop watchtower so it doesn't auto-update back to release images
sudo docker stop fula_updater

# 3. Block Docker Hub to prevent fula.sh from pulling release images on restart
sudo bash -c 'echo "127.0.0.1 index.docker.io registry-1.docker.io" >> /etc/hosts'

# 4. Prevent fula.sh from overwriting .env via docker cp (valid 24 hours)
touch /home/pi/stop_docker_copy.txt

# 5. Pull test images (if built remotely — do this BEFORE blocking Docker Hub)
#    Skip this if you built on-device in Step 2 Option C
sudo docker pull functionland/go-fula:test147
sudo docker pull functionland/fxsupport:test147
sudo docker pull functionland/ipfs-cluster:test147

# 6. Restart fula with test images
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
# 1. Unblock Docker Hub
sudo sed -i '/index.docker.io/d' /etc/hosts

# 2. Restore release .env
sudo tee /usr/bin/fula/.env << 'EOF'
GO_FULA=functionland/go-fula:release
FX_SUPPROT=functionland/fxsupport:release
IPFS_CLUSTER=functionland/ipfs-cluster:release
WPA_SUPLICANT_PATH=/etc
CURRENT_USER=pi
EOF

# 3. Remove the docker cp block
rm -f /home/pi/stop_docker_copy.txt

# 4. Restart fula (will pull release images)
sudo systemctl restart fula

# 5. Re-enable watchtower
sudo docker start fula_updater
```

#### Gotchas

- **`fula.service` has `Restart=always`**: If fula crashes or restarts while Docker Hub is reachable, `fula.sh` will `docker-compose pull` and overwrite your test images with release. Always block Docker Hub in `/etc/hosts` during testing.
- **Watchtower tag matching**: Watchtower updates images by matching the exact tag. If your containers are running `:test147`, watchtower won't replace them with `:release`. But if the containers are tagged `:release`, watchtower will pull the latest `:release` from Docker Hub.
- **`docker cp` overwrites `.env`**: On every restart, `fula.sh` copies `.env` from the `fula_fxsupport` container to `/usr/bin/fula/`. Use `stop_docker_copy.txt` to prevent this.
- **`stop_docker_copy.txt` expires after 24 hours**: If the file's mtime is older than 24h, `fula.sh` ignores it and resumes `docker cp`. Touch it again to extend.
- **`ipfs-cluster` not in test CI**: The `docker-image-test.yml` workflow only builds `fxsupport` and `go-fula`. To test a custom `ipfs-cluster` image, build locally or add it to the workflow.

## Testing Changes on a Live Device

To test code changes from this repo on a device that is already running the production Docker images, **without** pushing to Docker Hub:

### Method 1: Build fxsupport locally on device (recommended for script/config changes)

If you only changed files under `docker/fxsupport/linux/` (scripts, configs, env files), this is the fastest approach since fxsupport is just an alpine image with file copies:

```bash
# On the device:

# 1. Get the latest code
cd /tmp && git clone --depth 1 https://github.com/functionland/fula-ota.git
# Or if already cloned:
cd /tmp/fula-ota && git pull

# 2. Build fxsupport image locally (takes seconds)
cd /tmp/fula-ota/docker/fxsupport
sudo docker build --load -t functionland/fxsupport:release .

# 3. Stop watchtower so it doesn't pull the old image from Docker Hub
sudo docker stop fula_updater

# 4. Restart fula — docker cp will now copy YOUR files from the local image
sudo systemctl restart fula
```

### Method 2: Build all images locally on device

If you also changed `go-fula` or `ipfs-cluster` code (Go compilation, takes longer):

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
- **go-fula** and **ipfs-cluster** are custom-built from source in their respective Dockerfiles using Go 1.25.
- All containers except kubo run with `privileged: true` and `CAP_ADD: ALL`.
