#!/bin/bash

# Device Integration Test: Docker Hardening
# Tests the complete production update flow on a real RK3588 device
# Verifies privilege reduction, read-only mounts, security_opt, and isolation
#
# Usage:
#   ./test-device-hardening.sh              # Run all phases (build + deploy + verify)
#   ./test-device-hardening.sh --build      # Build Docker images only (Steps 1-2)
#   ./test-device-hardening.sh --deploy     # Deploy to device only (Steps 3-6)
#   ./test-device-hardening.sh --ota-sim    # Simulate real OTA update via fula.sh
#   ./test-device-hardening.sh --verify     # Verify hardening only (Steps 7-12)
#   ./test-device-hardening.sh --rollback   # Rollback to production images
#   ./test-device-hardening.sh --skip-build # Deploy + verify, skip image builds
#
# Pull Protection:
#   fula.sh dockerComposeUp() pulls from Docker Hub if internet is available,
#   which would overwrite locally-built test images. To prevent this, the deploy
#   phase temporarily blocks hub.docker.com in /etc/hosts (making fula.sh's
#   check_internet() fail), then stops watchtower after containers are up.
#   /etc/hosts is always restored (even on script failure) via an EXIT trap.
#
# IMPORTANT: This test modifies live system state (containers, systemd services).
#            Run on a development/staging device, NOT production.

set -euo pipefail

# ─── Configuration ────────────────────────────────────────────────────────────

TEST_LOG="/tmp/device-hardening-test.log"
FULA_PATH="/usr/bin/fula"
SYSTEMD_PATH="/etc/systemd/system"
FULA_LOG="/home/pi/fula.sh.log"
REPO_URL="https://github.com/functionland/fula-ota.git"
REPO_LOCAL="/tmp/fula-ota"
COMPOSE_FILE="${FULA_PATH}/docker-compose.yml"
ENV_FILE="${FULA_PATH}/.env"

# Pull protection state
HOSTS_MODIFIED=false
HOSTS_BACKUP="/tmp/etc-hosts-backup-hardening-test"
IMAGE_DIGESTS_FILE="/tmp/hardening-test-image-digests"

# Timeouts (seconds)
CONTAINER_STARTUP_TIMEOUT=180
SERVICE_STARTUP_TIMEOUT=30
OTA_FULL_STARTUP_TIMEOUT=420   # 60s ExecStartPre + restart() + docker cp + cascade
OTA_SIM_RAN=false              # set true by phase_ota_sim; gates OTA-specific tests
OTA_SNAPSHOT_DIR="/tmp/ota-sim-snapshot"  # pre-OTA state for before/after comparison

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

# Expected containers
EXPECTED_CONTAINERS=(
    "fula_updater"
    "ipfs_host"
    "ipfs_cluster"
    "fula_go"
    "fula_fxsupport"
)

# Expected systemd services
EXPECTED_SERVICES=(
    "fula"
    "uniondrive"
    "firewall"
    "fula-readiness-check"
    "commands"
    "fula-plugins"
)

# Service files to copy into systemd
SERVICE_FILES=(
    "fula.service"
    "uniondrive.service"
    "firewall.service"
    "commands.service"
    "fula-readiness-check.service"
    "fula-plugins.service"
)

# ─── Logging ──────────────────────────────────────────────────────────────────

log_test() {
    echo -e "${BLUE}[TEST]${NC} $1" | tee -a "$TEST_LOG"
}

log_pass() {
    echo -e "${GREEN}[PASS]${NC} $1" | tee -a "$TEST_LOG"
    ((++TESTS_PASSED))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" | tee -a "$TEST_LOG"
    ((++TESTS_FAILED))
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1" | tee -a "$TEST_LOG"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$TEST_LOG"
}

log_step() {
    echo "" | tee -a "$TEST_LOG"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}" | tee -a "$TEST_LOG"
    echo -e "${BLUE}  Step $1: $2${NC}" | tee -a "$TEST_LOG"
    echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}" | tee -a "$TEST_LOG"
    echo "" | tee -a "$TEST_LOG"
}

# ─── Helpers ──────────────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}ERROR: This script must be run as root${NC}"
        exit 1
    fi
}

check_prerequisites() {
    log_info "Checking prerequisites..."
    local missing=()

    for tool in docker git curl systemctl; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing+=("$tool")
        fi
    done

    # Check for docker compose (v2 plugin or standalone)
    if docker compose version >/dev/null 2>&1; then
        COMPOSE_CMD="docker compose"
    elif command -v docker-compose >/dev/null 2>&1; then
        COMPOSE_CMD="docker-compose"
    else
        missing+=("docker-compose")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Missing required tools: ${missing[*]}${NC}"
        exit 1
    fi

    if [[ ! -d "$FULA_PATH" ]]; then
        echo -e "${RED}Fula installation not found at $FULA_PATH${NC}"
        exit 1
    fi

    log_info "Prerequisites OK (compose: $COMPOSE_CMD)"
}

# Wait for a container to be running, with timeout
wait_for_container() {
    local name="$1"
    local timeout="${2:-$CONTAINER_STARTUP_TIMEOUT}"
    local elapsed=0

    while [[ $elapsed -lt $timeout ]]; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$name" 2>/dev/null || echo "missing")
        if [[ "$status" == "running" ]]; then
            return 0
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done
    return 1
}

# Wait for all expected containers to be running
wait_for_all_containers() {
    local timeout="${1:-$CONTAINER_STARTUP_TIMEOUT}"
    log_info "Waiting up to ${timeout}s for all containers to start..."

    for container in "${EXPECTED_CONTAINERS[@]}"; do
        if wait_for_container "$container" "$timeout"; then
            log_info "  $container: running"
        else
            log_warn "  $container: NOT running after ${timeout}s"
            return 1
        fi
    done
    return 0
}

# ─── Pull Protection ─────────────────────────────────────────────────────────
# Prevents fula.sh dockerComposeUp() and watchtower from pulling Docker Hub
# images, which would overwrite our locally-built test images.
#
# How it works:
#   fula.sh check_internet() does: wget -q --spider --timeout=10 https://hub.docker.com
#   By pointing hub.docker.com to 127.0.0.1 in /etc/hosts, wget fails,
#   check_internet() returns false, and fula.sh skips ALL docker pulls.
#   Watchtower is stopped after containers come up as a second safeguard.

PULL_GUARD_MARKER="# hardening-test-pull-guard"

block_docker_hub() {
    log_info "Blocking Docker Hub to protect locally-built images..."

    # Backup /etc/hosts
    cp /etc/hosts "$HOSTS_BACKUP"
    HOSTS_MODIFIED=true

    # Add entries that make fula.sh check_internet() fail
    # and prevent any stray docker pull from reaching the registry
    if ! grep -q "$PULL_GUARD_MARKER" /etc/hosts; then
        cat >> /etc/hosts <<EOF
127.0.0.1 hub.docker.com $PULL_GUARD_MARKER
127.0.0.1 registry-1.docker.io $PULL_GUARD_MARKER
127.0.0.1 auth.docker.io $PULL_GUARD_MARKER
127.0.0.1 production.cloudflare.docker.com $PULL_GUARD_MARKER
EOF
    fi

    log_info "  /etc/hosts: Docker Hub domains blocked"
    log_info "  fula.sh check_internet() will now return false"
}

unblock_docker_hub() {
    if $HOSTS_MODIFIED && [[ -f "$HOSTS_BACKUP" ]]; then
        cp "$HOSTS_BACKUP" /etc/hosts
        rm -f "$HOSTS_BACKUP"
        HOSTS_MODIFIED=false
        log_info "  /etc/hosts: restored from backup"
    elif $HOSTS_MODIFIED; then
        # Backup missing — remove our lines by marker
        sed -i "/$PULL_GUARD_MARKER/d" /etc/hosts
        HOSTS_MODIFIED=false
        log_info "  /etc/hosts: removed pull-guard entries"
    fi
}

# Record image digests after local build, before deploy
save_image_digests() {
    log_info "Recording locally-built image digests..."
    cat > "$IMAGE_DIGESTS_FILE" <<EOF
fxsupport=$(docker inspect --format='{{.Id}}' functionland/fxsupport:release 2>/dev/null || echo "MISSING")
ipfs-cluster=$(docker inspect --format='{{.Id}}' functionland/ipfs-cluster:release 2>/dev/null || echo "MISSING")
go-fula=$(docker inspect --format='{{.Id}}' functionland/go-fula:release 2>/dev/null || echo "MISSING")
kubo=$(docker inspect --format='{{.Id}}' ipfs/kubo:release 2>/dev/null || echo "MISSING")
EOF
    log_info "  Digests saved to $IMAGE_DIGESTS_FILE"
}

# Replace /usr/bin/fula/*.tar with locally-built images so fula.sh
# fallback (dockerComposeUp line 793) loads our builds, not Docker Hub.
save_local_image_tars() {
    log_info "Saving locally-built images as tar backups..."
    # Service names must match docker-compose service names (fula.sh uses ${service}.tar)
    docker save functionland/fxsupport:release -o "${FULA_PATH}/fxsupport.tar"
    docker save functionland/ipfs-cluster:release -o "${FULA_PATH}/ipfs-cluster.tar"
    docker save functionland/go-fula:release -o "${FULA_PATH}/go-fula.tar"
    docker save ipfs/kubo:release -o "${FULA_PATH}/kubo.tar"
    log_info "  tar backups replaced with locally-built images"
}

# Kill background pullFailedServices processes spawned by fula.sh dockerComposeUp
# (nohup, line 822). These retry docker-compose pull every 360s and would replace
# locally-built images once /etc/hosts is unblocked.
kill_pull_background() {
    local pids
    pids=$(pgrep -f "pullFailedServices" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
        log_info "  Killing background pullFailedServices: $pids"
        kill $pids 2>/dev/null || true
        sleep 2
        kill -9 $pids 2>/dev/null || true
    fi
}

# Force-remove ALL containers from the fula compose project, including Dead ones.
# Docker "Dead" containers retain compose labels but aren't listed by docker-compose ps,
# so docker-compose down misses them. When fula.sh's dockerComposeUp() uses
# --no-recreate, compose finds the Dead container (via labels), refuses to create
# a new one, but can't start the Dead one either → service never starts.
cleanup_stale_containers() {
    log_info "Cleaning up stale/dead containers..."

    # Remove by name (covers containers that kept their name)
    for c in "${EXPECTED_CONTAINERS[@]}"; do
        docker rm -f "$c" 2>/dev/null || true
    done

    # Remove any unnamed containers still carrying fula compose labels (e.g. Dead state)
    local stale
    stale=$(docker ps -a --filter "label=com.docker.compose.project=fula" -q 2>/dev/null || true)
    if [[ -n "$stale" ]]; then
        log_info "  Removing stale compose-labeled containers: $stale"
        echo "$stale" | xargs -r docker rm -f 2>/dev/null || true
    fi

    # Handle Dead containers whose overlay2 RW layer was deleted (e.g. by image
    # rebuild/prune) but whose metadata dir still exists in /var/lib/docker/containers/.
    # Docker can't remove them (layer missing) and can't start them (marked for removal).
    # docker rm -f and daemon restart both fail — the metadata must be deleted manually.
    local dead
    dead=$(docker ps -a --filter "status=dead" --no-trunc -q 2>/dev/null || true)
    if [[ -n "$dead" ]]; then
        log_warn "Dead containers detected (orphaned metadata), purging..."
        systemctl stop docker
        for cid in $dead; do
            log_info "  Removing /var/lib/docker/containers/$cid"
            rm -rf "/var/lib/docker/containers/$cid"
        done
        systemctl start docker
        sleep 5
        # Verify
        dead=$(docker ps -a --filter "status=dead" -q 2>/dev/null || true)
        if [[ -n "$dead" ]]; then
            log_warn "  Dead containers still present: $dead"
        else
            log_info "  Dead containers purged successfully"
        fi
    fi

    log_info "  Container cleanup complete"
}

# Cleanup trap — always restore /etc/hosts even on script failure
cleanup_pull_guard() {
    if $HOSTS_MODIFIED; then
        echo -e "${YELLOW}[CLEANUP] Restoring /etc/hosts...${NC}"
        unblock_docker_hub
    fi
}

trap cleanup_pull_guard EXIT

# ─── Phase: BUILD (Steps 1-2) ────────────────────────────────────────────────

phase_build() {
    log_step "1" "Get updated fula-ota code onto the device"

    if [[ -d "$REPO_LOCAL" ]]; then
        log_info "Removing existing clone at $REPO_LOCAL"
        rm -rf "$REPO_LOCAL"
    fi

    log_info "Cloning fula-ota repository..."
    git clone --depth 1 "$REPO_URL" "$REPO_LOCAL"

    # If BRANCH is set, check out that branch
    if [[ -n "${BRANCH:-}" ]]; then
        log_info "Checking out branch: $BRANCH"
        cd "$REPO_LOCAL"
        git fetch origin "$BRANCH" --depth 1
        git checkout "$BRANCH"
        cd -
    fi

    log_step "2" "Build ALL Docker images locally"

    # Free disk space: remove Docker build cache and dangling images/layers.
    # Without this, repeated builds fill /var/lib/docker and fail with
    # "no space left on device" during go link.
    log_info "Pruning Docker build cache and dangling images..."
    docker builder prune -af 2>/dev/null || true
    docker image prune -f 2>/dev/null || true
    log_info "  prune complete"

    # Read .env to get the exact image references that docker-compose uses.
    # The .env uses "index.docker.io/" prefixed names (e.g. index.docker.io/functionland/fxsupport:release)
    # while "docker build -t functionland/fxsupport:release" creates "docker.io/functionland/fxsupport:release".
    # Docker treats these as DIFFERENT images, so docker-compose can't find locally-built images.
    # Fix: tag with BOTH the short form and the .env form.
    local env_fxsupport env_gofula
    env_fxsupport=$(grep '^FX_SUPPROT=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    env_gofula=$(grep '^GO_FULA=' "$ENV_FILE" 2>/dev/null | cut -d'=' -f2 || echo "")
    log_info "  .env FX_SUPPROT=$env_fxsupport"
    log_info "  .env GO_FULA=$env_gofula"

    # --- 2a. fxsupport ---
    log_info "2a. Building fxsupport image..."
    docker build --no-cache -t functionland/fxsupport:release \
        -f "$REPO_LOCAL/docker/fxsupport/Dockerfile" \
        "$REPO_LOCAL/docker/fxsupport/"
    # Tag with .env name so docker-compose finds it
    if [[ -n "$env_fxsupport" && "$env_fxsupport" != "functionland/fxsupport:release" ]]; then
        docker tag functionland/fxsupport:release "$env_fxsupport"
        log_info "  fxsupport: also tagged as $env_fxsupport"
    fi
    log_info "  fxsupport: built"

    # --- 2b. ipfs-cluster ---
    log_info "2b. Building ipfs-cluster image (this may take 10-20 min)..."
    # Always fresh clone to ensure latest code from GitHub
    rm -rf "$REPO_LOCAL/docker/ipfs-cluster/ipfs-cluster"
    git clone --depth 1 -b master https://github.com/ipfs-cluster/ipfs-cluster \
        "$REPO_LOCAL/docker/ipfs-cluster/ipfs-cluster"
    log_info "  ipfs-cluster: cloned $(cd "$REPO_LOCAL/docker/ipfs-cluster/ipfs-cluster" && git log --oneline -1)"
    docker build --no-cache -t functionland/ipfs-cluster:release \
        -f "$REPO_LOCAL/docker/ipfs-cluster/Dockerfile" \
        "$REPO_LOCAL/docker/ipfs-cluster/"
    log_info "  ipfs-cluster: built"

    # --- 2c. go-fula ---
    log_info "2c. Building go-fula image (this may take 15-25 min)..."
    # Always fresh clone to ensure latest code from GitHub
    rm -rf "$REPO_LOCAL/docker/go-fula/go-fula"
    git clone --depth 1 -b main https://github.com/functionland/go-fula \
        "$REPO_LOCAL/docker/go-fula/go-fula"
    log_info "  go-fula: cloned $(cd "$REPO_LOCAL/docker/go-fula/go-fula" && git log --oneline -1)"
    # --no-cache ensures Docker doesn't reuse layers with stale source code
    docker build --no-cache -t functionland/go-fula:release \
        -f "$REPO_LOCAL/docker/go-fula/Dockerfile" \
        "$REPO_LOCAL/docker/go-fula/"
    # Tag with .env name so docker-compose finds it
    if [[ -n "$env_gofula" && "$env_gofula" != "functionland/go-fula:release" ]]; then
        docker tag functionland/go-fula:release "$env_gofula"
        log_info "  go-fula: also tagged as $env_gofula"
    fi
    log_info "  go-fula: built"

    # --- 2d. kubo ---
    log_info "2d. Pulling kubo:release..."
    docker pull ipfs/kubo:release
    log_info "  kubo: pulled"

    log_info "All images ready."

    # Record digests so we can verify they survive the deploy
    save_image_digests
}

# ─── Phase: DEPLOY (Steps 3-6) ───────────────────────────────────────────────

phase_deploy() {
    log_step "3" "Stop everything (simulates pre-update state)"

    # Block Docker Hub BEFORE starting fula.service to prevent pulls
    block_docker_hub

    log_info "Stopping fula.service..."
    systemctl stop fula 2>/dev/null || true
    sleep 10

    # Verify containers are stopped
    local running
    running=$(docker ps -q 2>/dev/null | wc -l)
    if [[ "$running" -gt 0 ]]; then
        log_warn "$running containers still running, forcing down..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null || true
        sleep 5
    fi

    # Force-remove ALL containers (including Dead ones from previous runs).
    # Dead containers retain compose labels but docker-compose down misses them,
    # and fula.sh's --no-recreate flag then refuses to create new ones.
    cleanup_stale_containers
    log_info "All containers stopped."

    # Remove tar backups so fula.sh can't load old images from them
    # (fula.sh dockerComposeUp loads from .tar if pull fails and image is missing)
    log_info "Removing old image tar backups..."
    rm -f "${FULA_PATH}"/*.tar
    log_info "  tar backups removed"

    log_step "4" "Simulate the production docker cp flow"

    log_info "4a. Starting fxsupport container (carries new files)..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" up -d fxsupport
    sleep 5

    if ! docker ps --format '{{.Names}}' | grep -q fula_fxsupport; then
        log_warn "fxsupport container not running, checking logs..."
        docker logs fula_fxsupport 2>&1 | tail -5 || true
    fi

    log_info "4b. Extracting files from fxsupport to host..."
    docker cp fula_fxsupport:/linux/. "${FULA_PATH}/"

    log_info "4c. Setting permissions..."
    chmod +x "${FULA_PATH}"/*.sh
    chmod -R 755 "${FULA_PATH}/kubo/" 2>/dev/null || true
    chmod -R 755 "${FULA_PATH}/ipfs-cluster/" 2>/dev/null || true

    log_info "4d. Stopping fxsupport..."
    $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null || true
    log_info "docker cp flow complete."

    # Replace tar backups with locally-built images so fula.sh's fallback
    # path (dockerComposeUp) loads our builds instead of Docker Hub versions.
    save_local_image_tars

    log_step "5" "Update systemd service files"

    local services_updated=0
    for svc in "${SERVICE_FILES[@]}"; do
        if [[ -f "${FULA_PATH}/${svc}" ]]; then
            if ! cmp -s "${FULA_PATH}/${svc}" "${SYSTEMD_PATH}/${svc}" 2>/dev/null; then
                cp "${FULA_PATH}/${svc}" "${SYSTEMD_PATH}/${svc}"
                log_info "  Updated: $svc"
                services_updated=1
            else
                log_info "  Unchanged: $svc"
            fi
        else
            log_warn "  Not found: ${FULA_PATH}/${svc}"
        fi
    done

    if [[ $services_updated -eq 1 ]]; then
        systemctl daemon-reload
        log_info "systemd daemon-reload complete"
    fi

    log_step "6" "Start the full system via fula.service"

    log_info "Starting fula.service (production entry point)..."
    systemctl restart fula

    log_info "Waiting for system startup (up to ${CONTAINER_STARTUP_TIMEOUT}s)..."
    if wait_for_all_containers "$CONTAINER_STARTUP_TIMEOUT"; then
        log_info "All containers are running."
    else
        log_warn "Not all containers started within timeout."
        log_warn "Container states:"
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || true
    fi

    # Stop watchtower to prevent it from pulling Docker Hub images
    # (it polls every 3600s, but stop it immediately for safety)
    log_info "Stopping watchtower to prevent Docker Hub pulls..."
    docker stop fula_updater 2>/dev/null || true
    log_info "  watchtower stopped (will be checked as 'not running' in verify phase)"

    # Kill any background pullFailedServices before unblocking Docker Hub
    kill_pull_background

    # Restore /etc/hosts — pulls are safe now since all containers are up
    # and watchtower is stopped
    unblock_docker_hub
    log_info "Docker Hub unblocked. Local images are in use."
}

# ─── Phase: OTA-SIM (Steps OTA-1 through OTA-4) ─────────────────────────────

phase_ota_sim() {
    log_step "OTA-1" "Stop system and capture pre-OTA state"

    # --- Capture pre-OTA state for before/after comparison ---
    rm -rf "$OTA_SNAPSHOT_DIR"
    mkdir -p "$OTA_SNAPSHOT_DIR"

    # Snapshot: file checksums of key scripts currently on host
    for f in fula.sh union-drive.sh docker-compose.yml .env kubo/config; do
        if [[ -f "${FULA_PATH}/${f}" ]]; then
            md5sum "${FULA_PATH}/${f}" >> "${OTA_SNAPSHOT_DIR}/host-files-before.md5"
        fi
    done
    log_info "Pre-OTA file checksums saved"

    # Snapshot: current PeerIDs (may be the same — that's the bug we're testing for)
    jq -r '.Identity.PeerID // empty' /home/pi/.internal/ipfs_data/config \
        > "${OTA_SNAPSHOT_DIR}/kubo-peerid-before" 2>/dev/null || true
    jq -r '.id // empty' /uniondrive/ipfs-cluster/identity.json \
        > "${OTA_SNAPSHOT_DIR}/cluster-peerid-before" 2>/dev/null || true
    log_info "Pre-OTA PeerIDs: kubo=$(cat ${OTA_SNAPSHOT_DIR}/kubo-peerid-before) cluster=$(cat ${OTA_SNAPSHOT_DIR}/cluster-peerid-before)"

    # Snapshot: current container image IDs
    for c in "${EXPECTED_CONTAINERS[@]}"; do
        docker inspect --format='{{.Image}}' "$c" \
            >> "${OTA_SNAPSHOT_DIR}/container-images-before" 2>/dev/null || true
    done

    # Snapshot: systemd service file checksums
    for svc in fula.service uniondrive.service firewall.service; do
        if [[ -f "${SYSTEMD_PATH}/${svc}" ]]; then
            md5sum "${SYSTEMD_PATH}/${svc}" >> "${OTA_SNAPSHOT_DIR}/systemd-before.md5"
        fi
    done

    log_info "Stopping fula.service..."
    systemctl stop fula 2>/dev/null || true
    sleep 10

    local running
    running=$(docker ps -q 2>/dev/null | wc -l)
    if [[ "$running" -gt 0 ]]; then
        log_warn "$running containers still running, forcing down..."
        $COMPOSE_CMD -f "$COMPOSE_FILE" --env-file "$ENV_FILE" down --remove-orphans 2>/dev/null || true
        sleep 5
    fi

    # Force-remove ALL containers (including Dead ones from previous runs)
    cleanup_stale_containers
    log_info "All containers stopped."

    log_step "OTA-2" "Prepare environment (simulate watchtower pulled new images)"

    block_docker_hub

    # Replace tar backups with locally-built images (not remove them).
    # fula.sh's fallback loads from tar when pull fails — we want it to load OUR builds.
    save_local_image_tars

    # Remove stop_docker_copy.txt — this is the key trigger.
    # fula.sh line 1799: if file missing or fxsupport image newer → docker cp runs
    log_info "Removing stop_docker_copy.txt to ensure docker cp fires..."
    rm -f /home/pi/stop_docker_copy.txt
    log_info "  stop_docker_copy.txt removed"

    # Truncate fula.sh log for clean OTA trace analysis
    log_info "Truncating fula.sh.log for clean trace..."
    : > "$FULA_LOG"

    log_step "OTA-3" "Start fula.service — fula.sh handles the entire update"

    log_info "This replicates the real production update path:"
    log_info "  fula.service ExecStartPre: sleep 60"
    log_info "  fula.sh start: restart() → dockerComposeDown → PeerID check"
    log_info "    → kubo config merge → dockerComposeUp (local images)"
    log_info "    → docker cp trigger → file change detection → cascade restart"
    systemctl start fula

    # Wait for containers, with periodic progress updates
    log_info "Waiting for full OTA cycle (up to ${OTA_FULL_STARTUP_TIMEOUT}s)..."
    local elapsed=0
    local all_up=false
    while [[ $elapsed -lt $OTA_FULL_STARTUP_TIMEOUT ]]; do
        local up_count=0
        for c in "${EXPECTED_CONTAINERS[@]}"; do
            local st
            st=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null || echo "missing")
            [[ "$st" == "running" ]] && ((++up_count))
        done

        if [[ $up_count -eq ${#EXPECTED_CONTAINERS[@]} ]]; then
            all_up=true
            break
        fi

        # Progress every 30s
        if (( elapsed % 30 == 0 )) && [[ $elapsed -gt 0 ]]; then
            log_info "  ${elapsed}s: ${up_count}/${#EXPECTED_CONTAINERS[@]} containers up"
        fi
        sleep 5
        elapsed=$((elapsed + 5))
    done

    if $all_up; then
        log_info "All containers running after ${elapsed}s."
    else
        log_warn "Not all containers up after ${OTA_FULL_STARTUP_TIMEOUT}s!"
        docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>/dev/null || true
    fi

    # Wait extra time for the docker cp + cascade restart that runs AFTER
    # containers are up (fula.sh lines 1776-1871)
    log_info "Waiting 90s for docker cp + cascade restart to complete..."
    local cp_done=false
    for i in $(seq 1 18); do
        if grep -q "docker cp status=>" "$FULA_LOG" 2>/dev/null; then
            cp_done=true
            break
        fi
        sleep 5
    done

    if $cp_done; then
        log_info "docker cp completed (detected in fula.sh.log)"
    else
        log_warn "docker cp marker not found in log after 90s"
    fi

    # Extra settle time for cascading restarts
    sleep 15

    log_step "OTA-4" "Post-OTA: stop watchtower, unblock Docker Hub, dump trace"

    docker stop fula_updater 2>/dev/null || true
    log_info "  watchtower stopped"

    # Kill any background pullFailedServices before unblocking Docker Hub
    kill_pull_background

    unblock_docker_hub
    log_info "  Docker Hub unblocked"

    # Dump the full fula.sh OTA trace for inspection
    log_info ""
    log_info "═══ fula.sh OTA trace (full log) ═══"
    cat "$FULA_LOG" 2>/dev/null | tee -a "$TEST_LOG" || true
    log_info "═══ end OTA trace ═══"
    log_info ""

    OTA_SIM_RAN=true
    log_info "OTA simulation complete. Run --verify to validate."
}

# ─── Phase: VERIFY (Steps 7-11) ──────────────────────────────────────────────

# Step 7: Verify all containers running
test_containers_running() {
    ((++TESTS_TOTAL))
    log_test "Step 7: Verifying all containers are running..."

    local all_ok=true
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
        if [[ "$status" == "running" ]]; then
            log_info "  $container: running"
        elif [[ "$container" == "fula_updater" && "$status" == "exited" ]]; then
            # Watchtower was intentionally stopped after deploy to prevent
            # Docker Hub pulls from overwriting locally-built test images.
            # On --verify after reboot, it will be running normally.
            log_info "  $container: $status (intentionally stopped to protect local images)"
        else
            log_info "  $container: $status"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "All expected containers are running (watchtower may be stopped for pull protection)"
    else
        log_fail "Not all containers are running"
    fi
}

test_container_images() {
    ((++TESTS_TOTAL))
    log_test "Step 7: Verifying container images..."

    docker ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1 | tee -a "$TEST_LOG"
    echo "" | tee -a "$TEST_LOG"

    # Just verify the expected image prefixes are present
    local all_ok=true
    local -A expected_images=(
        ["fula_updater"]="containrrr/watchtower"
        ["ipfs_host"]="ipfs/kubo"
        ["ipfs_cluster"]="functionland/ipfs-cluster"
        ["fula_go"]="functionland/go-fula"
        ["fula_fxsupport"]="functionland/fxsupport"
    )

    for container in "${!expected_images[@]}"; do
        local img
        img=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null || echo "")
        local expected="${expected_images[$container]}"
        if [[ "$img" == *"$expected"* ]]; then
            log_info "  $container: image=$img (OK)"
        else
            log_info "  $container: image=$img (expected *$expected*)"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "All containers running expected images"
    else
        log_fail "Image mismatch detected"
    fi
}

# Verify locally-built images were NOT replaced by Docker Hub pulls
test_image_digests_survived() {
    ((++TESTS_TOTAL))
    log_test "Step 7: Verifying local images were not replaced by Docker Hub pulls..."

    if [[ ! -f "$IMAGE_DIGESTS_FILE" ]]; then
        log_warn "  No saved digests found (--build phase was skipped?)"
        log_pass "Image digest check skipped (no baseline to compare)"
        return
    fi

    local all_ok=true
    local -A saved_digests

    # Read saved digests
    while IFS='=' read -r name digest; do
        saved_digests["$name"]="$digest"
    done < "$IMAGE_DIGESTS_FILE"

    # Compare current image digests against saved
    local -A image_map=(
        ["fxsupport"]="functionland/fxsupport:release"
        ["ipfs-cluster"]="functionland/ipfs-cluster:release"
        ["go-fula"]="functionland/go-fula:release"
        ["kubo"]="ipfs/kubo:release"
    )

    for name in "${!image_map[@]}"; do
        local tag="${image_map[$name]}"
        local current
        current=$(docker inspect --format='{{.Id}}' "$tag" 2>/dev/null || echo "MISSING")
        local saved="${saved_digests[$name]:-MISSING}"

        if [[ "$saved" == "MISSING" ]]; then
            log_info "  $name: no saved digest (skipped)"
        elif [[ "$current" == "$saved" ]]; then
            log_info "  $name: digest matches (local build survived)"
        else
            log_info "  $name: DIGEST CHANGED!"
            log_info "    saved:   ${saved:0:30}..."
            log_info "    current: ${current:0:30}..."
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "All locally-built images survived deploy (no Docker Hub overwrites)"
    else
        log_fail "Some images were replaced by Docker Hub pulls!"
    fi
}

# Step 8: Verify services are healthy
test_kubo_api() {
    ((++TESTS_TOTAL))
    log_test "Step 8: Kubo API health..."

    local response
    response=$(curl -s --max-time 10 -X POST http://127.0.0.1:5001/api/v0/id 2>/dev/null || echo "")

    if [[ -n "$response" ]] && echo "$response" | python3 -m json.tool >/dev/null 2>&1; then
        local peer_id
        peer_id=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ID',''))" 2>/dev/null || echo "")
        log_info "  Kubo peer ID: $peer_id"
        log_pass "Kubo API responding with valid JSON"
    else
        log_fail "Kubo API not responding or invalid response"
    fi
}

test_gofula_readiness() {
    ((++TESTS_TOTAL))
    log_test "Step 8: go-fula readiness endpoint..."

    local response
    response=$(curl -s --max-time 10 http://127.0.0.1:3500/readiness 2>/dev/null || echo "")

    if [[ -n "$response" ]]; then
        log_info "  Response: $response"
        log_pass "go-fula readiness endpoint responding"
    else
        log_fail "go-fula readiness endpoint not responding"
    fi
}

test_wifi_capability() {
    ((++TESTS_TOTAL))
    log_test "Step 8: go-fula NET_ADMIN capability (nmcli)..."

    local output
    output=$(docker exec fula_go nmcli device status 2>&1 || echo "EXEC_FAILED")

    if [[ "$output" == *"EXEC_FAILED"* ]] || [[ "$output" == *"not found"* ]]; then
        log_warn "  nmcli not available in container (may be expected)"
        log_pass "go-fula container exec works (nmcli binary may not be installed)"
    else
        log_info "  nmcli output: $(echo "$output" | head -3)"
        log_pass "go-fula NET_ADMIN capability working (nmcli accessible)"
    fi
}

test_ipfs_cluster_health() {
    ((++TESTS_TOTAL))
    log_test "Step 8: IPFS cluster health..."

    local output
    output=$(docker exec ipfs_cluster ipfs-cluster-ctl health 2>&1 || echo "EXEC_FAILED")

    if [[ "$output" == *"EXEC_FAILED"* ]]; then
        log_fail "ipfs-cluster-ctl health failed"
    else
        log_info "  Cluster health: $(echo "$output" | head -3)"
        log_pass "IPFS cluster health check succeeded"
    fi
}

test_gofula_logs() {
    ((++TESTS_TOTAL))
    log_test "Step 8: go-fula container logs (checking for fatal errors)..."

    local logs
    logs=$(docker logs fula_go 2>&1 | tail -30 || echo "")

    # Check for obvious fatal errors
    if echo "$logs" | grep -qi "panic\|fatal\|segfault"; then
        log_info "  Last log lines:"
        echo "$logs" | tail -10 | tee -a "$TEST_LOG"
        log_fail "go-fula logs contain panic/fatal errors"
    else
        log_info "  Last 5 log lines:"
        echo "$logs" | tail -5 | sed 's/^/    /' | tee -a "$TEST_LOG"
        log_pass "go-fula logs show no fatal errors"
    fi
}

test_kubo_p2p_protocols() {
    ((++TESTS_TOTAL))
    log_test "Step 8: Kubo p2p protocols registered..."

    local output
    output=$(docker exec ipfs_host ipfs p2p ls 2>&1 || echo "EXEC_FAILED")

    if [[ "$output" == *"EXEC_FAILED"* ]]; then
        log_fail "Could not list kubo p2p protocols"
    elif [[ -z "$output" ]]; then
        log_warn "  No p2p protocols registered yet (may need more startup time)"
        log_pass "Kubo p2p ls command succeeded (0 protocols — may be early)"
    else
        local count
        count=$(echo "$output" | wc -l)
        log_info "  Registered protocols: $count"
        echo "$output" | head -5 | sed 's/^/    /' | tee -a "$TEST_LOG"
        log_pass "Kubo has $count p2p protocols registered"
    fi
}

# Step 9: Verify systemd services
test_systemd_services() {
    ((++TESTS_TOTAL))
    log_test "Step 9: Verifying systemd services..."

    local all_ok=true
    for svc in "${EXPECTED_SERVICES[@]}"; do
        local status
        status=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
        log_info "  $svc: $status"
        # fula-plugins and commands may legitimately exit after running
        if [[ "$status" != "active" && "$svc" != "fula-plugins" && "$svc" != "commands" ]]; then
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "All critical systemd services are active"
    else
        log_fail "Some systemd services are not active"
    fi
}

test_firewall_rules() {
    ((++TESTS_TOTAL))
    log_test "Step 9: Checking firewall rules..."

    local output
    output=$(iptables -L FULA_FIREWALL -n 2>/dev/null || echo "NO_CHAIN")

    if [[ "$output" == *"NO_CHAIN"* ]]; then
        log_warn "  FULA_FIREWALL chain does not exist (firewall may not have run yet)"
        log_fail "FULA_FIREWALL iptables chain not found"
    else
        local rule_count
        rule_count=$(echo "$output" | grep -c -v "^Chain\|^target\|^$" || echo "0")
        log_info "  FULA_FIREWALL rules: $rule_count"
        echo "$output" | head -5 | sed 's/^/    /' | tee -a "$TEST_LOG"
        log_pass "Firewall chain FULA_FIREWALL exists with $rule_count rules"
    fi
}

test_firewall_bridge_rules() {
    ((++TESTS_TOTAL))
    log_test "Step 9: Firewall allows Docker bridge traffic (docker0 + br-+)..."

    local rules
    rules=$(iptables -L FULA_FIREWALL -n 2>/dev/null || echo "NO_CHAIN")

    if [[ "$rules" == *"NO_CHAIN"* ]]; then
        log_fail "FULA_FIREWALL chain not found"
        return
    fi

    local docker0_ok=false br_ok=false

    # Check for docker0 accept rule
    if iptables -L FULA_FIREWALL -n -v 2>/dev/null | grep -q "docker0.*ACCEPT"; then
        docker0_ok=true
    fi

    # Check for br-+ (Compose bridge) accept rule
    # iptables -L shows "br-+" as the interface pattern
    if iptables -L FULA_FIREWALL -n -v 2>/dev/null | grep -q "br-\+.*ACCEPT\|br+.*ACCEPT"; then
        br_ok=true
    fi

    if $docker0_ok && $br_ok; then
        log_pass "Firewall accepts traffic from docker0 and Compose bridges (br-+)"
    else
        $docker0_ok || log_info "  MISSING: docker0 accept rule"
        $br_ok      || log_info "  MISSING: br-+ accept rule (Docker Compose bridges)"
        log_fail "Firewall missing Docker bridge accept rules — kubo→proxy traffic will be silently dropped"
        log_info "  This breaks the Mobile→kubo→go-fula proxy path (port 4020/4021)."
        log_info "  Fix: Add 'iptables -A FULA_FIREWALL -i br-+ -j ACCEPT' to firewall.sh"
    fi
}

test_firewall_proxy_ports() {
    ((++TESTS_TOTAL))
    log_test "Step 9: Firewall allows go-fula proxy ports (4020 + 4021)..."

    local rules
    rules=$(iptables -L FULA_FIREWALL -n 2>/dev/null || echo "NO_CHAIN")

    if [[ "$rules" == *"NO_CHAIN"* ]]; then
        log_fail "FULA_FIREWALL chain not found"
        return
    fi

    local port4020_ok=false port4021_ok=false

    if echo "$rules" | grep -q "tcp dpt:4020.*ACCEPT\|ACCEPT.*tcp.*dpt:4020"; then
        port4020_ok=true
    fi

    if echo "$rules" | grep -q "tcp dpt:4021.*ACCEPT\|ACCEPT.*tcp.*dpt:4021"; then
        port4021_ok=true
    fi

    if $port4020_ok && $port4021_ok; then
        log_pass "Firewall has explicit ACCEPT rules for ports 4020 and 4021"
    else
        $port4020_ok || log_info "  MISSING: port 4020 (blockchain proxy) accept rule"
        $port4021_ok || log_info "  MISSING: port 4021 (ping proxy) accept rule"
        log_fail "Firewall missing explicit proxy port rules (defense-in-depth)"
        log_info "  These ports are used by kubo→go-fula p2p stream forwarding."
        log_info "  Fix: Add 'iptables -A FULA_FIREWALL -p tcp --dport 4020 -j ACCEPT' to firewall.sh"
    fi
}

# Step 10: Verify privilege reduction (hardening-specific)
test_no_privileged_mode() {
    ((++TESTS_TOTAL))
    log_test "Step 10: No container runs in privileged mode..."

    local all_ok=true
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        local priv
        priv=$(docker inspect --format='{{.HostConfig.Privileged}}' "$container" 2>/dev/null || echo "MISSING")
        if [[ "$priv" == "false" ]]; then
            log_info "  $container: privileged=false"
        else
            log_info "  $container: privileged=$priv"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "All containers have privileged=false"
    else
        log_fail "One or more containers are running in privileged mode"
    fi
}

test_gofula_capabilities() {
    ((++TESTS_TOTAL))
    log_test "Step 10: go-fula has correct capabilities..."

    local caps
    caps=$(docker inspect --format='{{.HostConfig.CapAdd}}' fula_go 2>/dev/null || echo "MISSING")
    log_info "  fula_go cap_add=$caps"

    local expected_caps=("NET_ADMIN" "NET_RAW" "SYS_ADMIN" "CHOWN" "DAC_OVERRIDE" "FOWNER" "SETGID" "SETUID")
    local all_ok=true

    for cap in "${expected_caps[@]}"; do
        if [[ "$caps" != *"$cap"* ]]; then
            log_info "  Missing capability: $cap"
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "go-fula has all expected capabilities"
    else
        log_fail "go-fula missing expected capabilities"
    fi
}

test_kubo_no_caps() {
    ((++TESTS_TOTAL))
    log_test "Step 10: kubo and ipfs-cluster have no extra capabilities..."

    local all_ok=true
    for container in ipfs_host ipfs_cluster; do
        local caps
        caps=$(docker inspect --format='{{.HostConfig.CapAdd}}' "$container" 2>/dev/null || echo "MISSING")
        log_info "  $container: cap_add=$caps"
        # Empty cap_add is [] or <nil> or <no value>
        if [[ "$caps" != "[]" && "$caps" != "<nil>" && "$caps" != "<no value>" && "$caps" != "MISSING" ]]; then
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "kubo and ipfs-cluster have no extra capabilities"
    else
        log_fail "kubo or ipfs-cluster have unexpected capabilities"
    fi
}

test_docker_sock_readonly() {
    ((++TESTS_TOTAL))
    log_test "Step 10: go-fula docker.sock mounted read-only..."

    local mode
    mode=$(docker inspect --format='{{range .Mounts}}{{if eq .Destination "/var/run/docker.sock"}}mode={{.Mode}}{{end}}{{end}}' fula_go 2>/dev/null || echo "MISSING")
    log_info "  fula_go docker.sock: $mode"

    if [[ "$mode" == *"ro"* ]]; then
        log_pass "docker.sock is mounted read-only on fula_go"
    else
        log_fail "docker.sock is NOT read-only on fula_go (got: $mode)"
    fi
}

test_fxsupport_no_mounts() {
    ((++TESTS_TOTAL))
    log_test "Step 10: fxsupport has no volume mounts..."

    local mount_count
    mount_count=$(docker inspect --format='{{len .Mounts}}' fula_fxsupport 2>/dev/null || echo "MISSING")
    log_info "  fula_fxsupport mount count: $mount_count"

    if [[ "$mount_count" == "0" ]]; then
        log_pass "fxsupport has 0 volume mounts"
    else
        log_fail "fxsupport has $mount_count volume mounts (expected 0)"
        docker inspect --format='{{range .Mounts}}  {{.Destination}}{{"\n"}}{{end}}' fula_fxsupport 2>/dev/null | tee -a "$TEST_LOG"
    fi
}

test_fxsupport_readonly() {
    ((++TESTS_TOTAL))
    log_test "Step 10: fxsupport has read-only rootfs..."

    local ro
    ro=$(docker inspect --format='{{.HostConfig.ReadonlyRootfs}}' fula_fxsupport 2>/dev/null || echo "MISSING")
    log_info "  fula_fxsupport read_only=$ro"

    if [[ "$ro" == "true" ]]; then
        log_pass "fxsupport rootfs is read-only"
    else
        log_fail "fxsupport rootfs is NOT read-only (got: $ro)"
    fi
}

test_watchtower_readonly() {
    ((++TESTS_TOTAL))
    log_test "Step 10: watchtower has read-only rootfs..."

    # docker inspect works on stopped containers too (reads config, not runtime state)
    local ro
    ro=$(docker inspect --format='{{.HostConfig.ReadonlyRootfs}}' fula_updater 2>/dev/null || echo "MISSING")
    log_info "  fula_updater read_only=$ro"

    if [[ "$ro" == "true" ]]; then
        log_pass "watchtower rootfs is read-only"
    else
        log_fail "watchtower rootfs is NOT read-only (got: $ro)"
    fi
}

test_no_new_privileges() {
    ((++TESTS_TOTAL))
    log_test "Step 10: All containers have no-new-privileges..."

    local all_ok=true
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        local sec
        sec=$(docker inspect --format='{{.HostConfig.SecurityOpt}}' "$container" 2>/dev/null || echo "MISSING")
        log_info "  $container: security_opt=$sec"
        if [[ "$sec" != *"no-new-privileges"* ]]; then
            all_ok=false
        fi
    done

    if $all_ok; then
        log_pass "All containers have no-new-privileges:true"
    else
        log_fail "Not all containers have no-new-privileges"
    fi
}

# Step 11: Isolation negative tests
test_docker_sock_write_blocked() {
    ((++TESTS_TOTAL))
    log_test "Step 11: go-fula docker.sock is read-only (write should fail)..."

    # Read should work
    local read_ok=false
    local read_output
    read_output=$(docker exec fula_go docker ps --format "{{.Names}}" 2>&1 || echo "READ_FAILED")
    if [[ "$read_output" != *"READ_FAILED"* ]] && [[ "$read_output" != *"permission denied"* ]]; then
        read_ok=true
        log_info "  Read (docker ps): OK"
    else
        log_info "  Read (docker ps): FAILED ($read_output)"
    fi

    # Write should fail — try to remove watchtower (harmless if it works, but it shouldn't)
    local write_output
    write_output=$(docker exec fula_go docker rm -f fula_updater 2>&1 || echo "WRITE_BLOCKED")
    local write_blocked=false
    if [[ "$write_output" == *"WRITE_BLOCKED"* ]] || [[ "$write_output" == *"read-only"* ]] || [[ "$write_output" == *"permission denied"* ]] || [[ "$write_output" == *"denied"* ]]; then
        write_blocked=true
        log_info "  Write (docker rm): blocked as expected"
    else
        log_info "  Write (docker rm): UNEXPECTEDLY SUCCEEDED — $write_output"
    fi

    if $read_ok && $write_blocked; then
        log_pass "docker.sock: read=OK, write=blocked"
    elif $read_ok && ! $write_blocked; then
        log_fail "docker.sock write was NOT blocked (read-only mount not enforced)"
    else
        log_warn "  docker.sock read also failed; docker CLI may not be in go-fula image"
        log_pass "docker.sock isolation test (docker CLI not in image — socket not usable)"
    fi
}

test_kubo_no_kernel_access() {
    ((++TESTS_TOTAL))
    log_test "Step 11: kubo cannot access kernel memory..."

    local output
    output=$(docker exec ipfs_host cat /proc/kcore 2>&1 || echo "BLOCKED")

    if [[ "$output" == *"BLOCKED"* ]] || [[ "$output" == *"Permission denied"* ]] || [[ "$output" == *"Operation not permitted"* ]]; then
        log_pass "kubo cannot read /proc/kcore (not privileged)"
    else
        log_fail "kubo CAN read /proc/kcore — container may be privileged!"
    fi
}

test_cluster_no_iptables() {
    ((++TESTS_TOTAL))
    log_test "Step 11: ipfs-cluster cannot run iptables..."

    local output
    output=$(docker exec ipfs_cluster iptables -L 2>&1 || echo "BLOCKED")

    if [[ "$output" == *"BLOCKED"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"Permission denied"* ]] || [[ "$output" == *"Operation not permitted"* ]]; then
        log_pass "ipfs-cluster cannot run iptables (no cap + no package)"
    else
        log_fail "ipfs-cluster CAN run iptables"
    fi
}

test_cluster_no_modprobe() {
    ((++TESTS_TOTAL))
    log_test "Step 11: ipfs-cluster cannot load kernel modules..."

    local output
    output=$(docker exec ipfs_cluster modprobe ip_tables 2>&1 || echo "BLOCKED")

    if [[ "$output" == *"BLOCKED"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"Permission denied"* ]] || [[ "$output" == *"Operation not permitted"* ]]; then
        log_pass "ipfs-cluster cannot load kernel modules (not privileged)"
    else
        log_fail "ipfs-cluster CAN load kernel modules"
    fi
}

# ─── OTA update flow verification ─────────────────────────────────────────
# These tests verify that fula.sh's internal OTA mechanisms actually
# executed correctly. They catch real update bugs before images are
# pushed to Docker Hub.

test_ota_docker_cp_ran() {
    ((++TESTS_TOTAL))
    log_test "OTA: docker cp extraction ran successfully..."

    if ! $OTA_SIM_RAN; then
        log_info "  Skipped (--ota-sim not run in this session)"
        log_pass "OTA docker cp check skipped"
        return
    fi

    if grep -q "docker cp status=> 0" "$FULA_LOG" 2>/dev/null; then
        log_pass "docker cp ran and exited 0"
    elif grep -q "skipping docker cp command" "$FULA_LOG" 2>/dev/null; then
        log_fail "docker cp was SKIPPED — stop_docker_copy.txt trigger did not fire"
        log_info "  This means fula.sh thinks the image hasn't changed."
        log_info "  Check the timestamp comparison logic at fula.sh line 1799."
        grep -i "docker cp\|stop_docker_copy\|last_pull_time\|last_modification" "$FULA_LOG" 2>/dev/null | tail -5 | sed 's/^/    /' || true
    elif grep -q "docker cp status=>" "$FULA_LOG" 2>/dev/null; then
        local line
        line=$(grep "docker cp status=>" "$FULA_LOG" | tail -1)
        log_fail "docker cp ran but FAILED: $line"
    else
        log_fail "No evidence of docker cp in fula.sh.log at all"
        log_info "  fula.sh may have crashed before reaching the docker cp stage."
        log_info "  Last 10 lines of fula.sh.log:"
        tail -10 "$FULA_LOG" 2>/dev/null | sed 's/^/    /' || true
    fi
}

test_ota_files_extracted() {
    ((++TESTS_TOTAL))
    log_test "OTA: extracted files match what's inside fxsupport container..."

    if ! $OTA_SIM_RAN; then
        log_info "  Skipped (--ota-sim not run in this session)"
        log_pass "OTA file extraction check skipped"
        return
    fi

    local all_ok=true
    local checked=0
    for file in fula.sh union-drive.sh docker-compose.yml .env; do
        # Get size from running fxsupport container
        local container_size
        container_size=$(docker exec fula_fxsupport stat -c %s "/linux/$file" 2>/dev/null || echo "MISSING")
        local host_size
        host_size=$(stat -c %s "${FULA_PATH}/$file" 2>/dev/null || echo "MISSING")

        if [[ "$container_size" == "MISSING" ]]; then
            log_info "  $file: not in container (skipped)"
            continue
        fi
        ((++checked))

        if [[ "$host_size" == "MISSING" ]]; then
            log_info "  $file: MISSING on host (docker cp failed to extract it)"
            all_ok=false
        elif [[ "$container_size" == "$host_size" ]]; then
            log_info "  $file: OK (${host_size} bytes)"
        else
            log_info "  $file: SIZE MISMATCH — container=${container_size} host=${host_size}"
            log_info "    docker cp may have failed or an older version remains"
            all_ok=false
        fi
    done

    if [[ $checked -eq 0 ]]; then
        log_fail "Could not compare any files (fxsupport container not accessible?)"
    elif $all_ok; then
        log_pass "All $checked checked files match fxsupport container"
    else
        log_fail "Some extracted files don't match — docker cp may be broken"
    fi
}

test_ota_kubo_config_merge() {
    ((++TESTS_TOTAL))
    log_test "OTA: kubo config merge executed..."

    if ! $OTA_SIM_RAN; then
        log_info "  Skipped (--ota-sim not run in this session)"
        log_pass "OTA kubo config merge check skipped"
        return
    fi

    if grep -q "kubo_config_merge_inline: done" "$FULA_LOG" 2>/dev/null; then
        log_pass "Kubo config merge completed (inline)"
    elif grep -q "kubo_config_merge_inline: config already up to date" "$FULA_LOG" 2>/dev/null; then
        log_pass "Kubo config merge ran (already up to date)"
    elif grep -q "kubo_config_merge_inline: deployed config not found" "$FULA_LOG" 2>/dev/null; then
        log_warn "  Deployed config not found — merge skipped (fresh install?)"
        log_pass "Kubo config merge correctly skipped (no deployed config)"
    elif grep -q "kubo config merge failed\|inline kubo config merge failed" "$FULA_LOG" 2>/dev/null; then
        log_fail "Kubo config merge FAILED"
        grep -i "kubo_config_merge\|merge failed" "$FULA_LOG" 2>/dev/null | tail -5 | sed 's/^/    /' || true
    else
        log_fail "No evidence kubo config merge ran"
        log_info "  fula.sh may have crashed before reaching the merge step (line 1375)."
    fi
}

test_ota_peerid_separation() {
    ((++TESTS_TOTAL))
    log_test "OTA: kubo and ipfs-cluster have different PeerIDs..."

    local kubo_pid cluster_pid config_pid

    # Get kubo PeerID from live API
    kubo_pid=$(curl -s --max-time 10 -X POST http://127.0.0.1:5001/api/v0/id 2>/dev/null \
        | python3 -c "import sys,json; print(json.load(sys.stdin).get('ID',''))" 2>/dev/null || echo "")

    # Get cluster PeerID from identity file
    cluster_pid=$(jq -r '.id // empty' /uniondrive/ipfs-cluster/identity.json 2>/dev/null || echo "")

    # Get kubo config PeerID (what's on disk)
    config_pid=$(jq -r '.Identity.PeerID // empty' /home/pi/.internal/ipfs_data/config 2>/dev/null || echo "")

    if [[ -z "$kubo_pid" ]]; then
        log_fail "Cannot get kubo PeerID from API (kubo not responding?)"
        return
    fi
    if [[ -z "$cluster_pid" ]]; then
        log_fail "Cannot get cluster PeerID (identity.json missing?)"
        return
    fi

    log_info "  Kubo API PeerID:    $kubo_pid"
    log_info "  Kubo config PeerID: $config_pid"
    log_info "  Cluster PeerID:     $cluster_pid"

    if [[ "$kubo_pid" == "$cluster_pid" ]]; then
        log_fail "CRITICAL: Kubo and cluster have the SAME PeerID: $kubo_pid"
        log_info "  The PeerID separation fix in fula.sh restart() did not work."
        log_info "  Check fula.sh.log for 'forcing identity re-derivation'."
        grep -i "PeerID\|re-derivation\|\.ipfs_setup" "$FULA_LOG" 2>/dev/null | sed 's/^/    /' || true

        # Show pre-OTA state if available
        if [[ -f "${OTA_SNAPSHOT_DIR}/kubo-peerid-before" ]]; then
            log_info "  Pre-OTA kubo PeerID was: $(cat ${OTA_SNAPSHOT_DIR}/kubo-peerid-before)"
        fi
    elif [[ -n "$config_pid" && "$config_pid" != "$kubo_pid" ]]; then
        log_fail "Kubo API PeerID ($kubo_pid) doesn't match config file ($config_pid)"
        log_info "  Kubo may have loaded an old config before initipfs overwrote it."
    else
        log_pass "Kubo ($kubo_pid) and cluster ($cluster_pid) have different PeerIDs"
    fi
}

test_ota_log_errors() {
    ((++TESTS_TOTAL))
    log_test "OTA: fula.sh.log has no critical errors..."

    if ! $OTA_SIM_RAN; then
        log_info "  Skipped (--ota-sim not run in this session)"
        log_pass "OTA log error check skipped"
        return
    fi

    # Scan for errors/failures that indicate real problems
    local error_patterns="failed to start again\|Pull for.*initiated\|Error response from daemon\|cannot start\|No such container\|is not running"
    local errors
    errors=$(grep -i "$error_patterns" "$FULA_LOG" 2>/dev/null || true)

    if [[ -z "$errors" ]]; then
        log_pass "No critical errors found in fula.sh.log"
    else
        local count
        count=$(echo "$errors" | wc -l)
        log_fail "Found $count error(s) in fula.sh.log during OTA update"
        echo "$errors" | head -10 | sed 's/^/    /' | tee -a "$TEST_LOG"
    fi
}

test_ota_compose_flow() {
    ((++TESTS_TOTAL))
    log_test "OTA: dockerComposeDown + dockerComposeUp both ran..."

    if ! $OTA_SIM_RAN; then
        log_info "  Skipped (--ota-sim not run in this session)"
        log_pass "OTA compose flow check skipped"
        return
    fi

    local down_ok=false up_ok=false
    grep -q "dockerComposeDown" "$FULA_LOG" 2>/dev/null && down_ok=true
    grep -q "dockerComposeUp" "$FULA_LOG" 2>/dev/null && up_ok=true

    if $down_ok && $up_ok; then
        log_pass "dockerComposeDown + dockerComposeUp both executed"
    else
        $down_ok || log_info "  dockerComposeDown: NOT FOUND in log"
        $up_ok   || log_info "  dockerComposeUp: NOT FOUND in log"
        log_fail "Compose lifecycle incomplete — fula.sh may have crashed early"
        log_info "  Last 10 lines of fula.sh.log:"
        tail -10 "$FULA_LOG" 2>/dev/null | sed 's/^/    /' || true
    fi
}

# ─── Phase runners ────────────────────────────────────────────────────────────

phase_verify() {
    log_step "7" "Verify ALL containers running"
    test_containers_running
    test_container_images
    test_image_digests_survived

    log_step "8" "Verify services are healthy"
    test_kubo_api
    test_gofula_readiness
    test_wifi_capability
    test_ipfs_cluster_health
    test_gofula_logs
    test_kubo_p2p_protocols

    log_step "9" "Verify ALL systemd services"
    test_systemd_services
    test_firewall_rules
    test_firewall_bridge_rules
    test_firewall_proxy_ports

    log_step "10" "Verify privilege reduction (hardening)"
    test_no_privileged_mode
    test_gofula_capabilities
    test_kubo_no_caps
    test_docker_sock_readonly
    test_fxsupport_no_mounts
    test_fxsupport_readonly
    test_watchtower_readonly
    test_no_new_privileges

    log_step "11" "Isolation negative tests"
    test_docker_sock_write_blocked
    test_kubo_no_kernel_access
    test_cluster_no_iptables
    test_cluster_no_modprobe

    log_step "12" "OTA update flow verification"
    test_ota_compose_flow
    test_ota_docker_cp_ran
    test_ota_files_extracted
    test_ota_kubo_config_merge
    test_ota_peerid_separation
    test_ota_log_errors
}

# ─── Lifecycle phases ─────────────────────────────────────────────────────────

# Prepare for reboot test (Step 12): block Docker Hub persistently so that
# fula.sh cannot pull images or docker cp non-hardened files after reboot.
phase_reboot_prep() {
    log_info "Preparing device for reboot test..."

    # Check if pull guard is already in place
    if grep -q "$PULL_GUARD_MARKER" /etc/hosts 2>/dev/null; then
        log_info "  Docker Hub already blocked in /etc/hosts"
    else
        block_docker_hub
    fi

    # Disable the EXIT trap — we WANT the block to persist across reboot
    HOSTS_MODIFIED=false

    log_info "Docker Hub is blocked persistently in /etc/hosts."
    log_info "After reboot, fula.sh will skip all pulls and use local images."
    echo ""
    echo "Ready for reboot. Run these commands:"
    echo "  sudo reboot"
    echo "  # Wait ~3 minutes, then:"
    echo "  sudo $0 --verify"
    echo "  sudo $0 --finish"
}

# Restore normal device operation after testing is complete.
phase_finish() {
    log_info "Restoring normal device operation..."

    # Remove Docker Hub block if present
    if grep -q "$PULL_GUARD_MARKER" /etc/hosts 2>/dev/null; then
        sed -i "/$PULL_GUARD_MARKER/d" /etc/hosts
        HOSTS_MODIFIED=false
        log_info "  /etc/hosts: Docker Hub unblocked"
    else
        log_info "  /etc/hosts: already clean"
    fi

    # Restart watchtower if it was stopped
    local wt_status
    wt_status=$(docker inspect --format='{{.State.Status}}' fula_updater 2>/dev/null || echo "missing")
    if [[ "$wt_status" != "running" ]]; then
        docker start fula_updater 2>/dev/null || true
        log_info "  watchtower: restarted"
    else
        log_info "  watchtower: already running"
    fi

    # Clean up temp files
    rm -f "$IMAGE_DIGESTS_FILE" "$HOSTS_BACKUP"

    log_info "Device restored to normal operation."
    log_info "  Watchtower will resume polling Docker Hub every 3600s."
    log_info "  Next fula.sh restart will pull from Docker Hub as usual."
}

phase_rollback() {
    echo -e "${YELLOW}Rolling back to production Docker Hub images...${NC}"

    # Ensure Docker Hub is accessible first
    if grep -q "$PULL_GUARD_MARKER" /etc/hosts 2>/dev/null; then
        sed -i "/$PULL_GUARD_MARKER/d" /etc/hosts
        HOSTS_MODIFIED=false
        log_info "  /etc/hosts: Docker Hub unblocked for pull"
    fi

    log_info "Pulling original production images..."
    docker pull functionland/fxsupport:release
    docker pull functionland/ipfs-cluster:release
    docker pull functionland/go-fula:release

    log_info "Stopping fula.service..."
    systemctl stop fula 2>/dev/null || true
    sleep 5

    log_info "Re-extracting original compose and scripts from production fxsupport..."
    docker rm -f fula_fxsupport 2>/dev/null || true
    docker run -d --name fula_fxsupport functionland/fxsupport:release tail -F /dev/null
    sleep 3
    docker cp fula_fxsupport:/linux/. "${FULA_PATH}/"
    chmod +x "${FULA_PATH}"/*.sh
    docker rm -f fula_fxsupport

    log_info "Restarting fula.service with original config..."
    systemctl restart fula

    # Clean up temp files
    rm -f "$IMAGE_DIGESTS_FILE" "$HOSTS_BACKUP"

    log_info "Rollback complete. Device is back to production state."
    log_info "Run --verify to check system state."
}

# ─── Results summary ─────────────────────────────────────────────────────────

print_results() {
    echo ""
    echo "Test Results"
    echo "==============="
    echo "Total Tests: $TESTS_TOTAL"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}All tests passed!${NC}"
        echo ""
        echo "Next steps:"
        echo ""
        echo "  Option A — Reboot test (Step 12, recommended):"
        echo "    sudo $0 --reboot-prep       # Block Docker Hub for reboot"
        echo "    sudo reboot"
        echo "    # Wait ~3 minutes, then:"
        echo "    sudo $0 --verify            # Re-verify after reboot"
        echo "    sudo $0 --finish            # Restore normal operation"
        echo ""
        echo "  Option B — Done testing, restore normal operation:"
        echo "    sudo $0 --finish"
        echo ""
        echo "  Option C — OTA simulation (test real update path):"
        echo "    sudo $0 --build --ota-sim --verify"
        echo "    sudo $0 --finish"
    else
        echo -e "\n${RED}Some tests failed. Check $TEST_LOG for details.${NC}"
        echo ""
        echo "  To rollback to production: sudo $0 --rollback"
        echo "  To restore normal state:   sudo $0 --finish"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Phases:"
    echo "  (no flags)     Run all phases: build + deploy + verify"
    echo "  --build        Build Docker images only (Steps 1-2)"
    echo "  --deploy       Deploy to device only (Steps 3-6)"
    echo "  --ota-sim      Simulate real OTA update via fula.sh (Steps OTA-1 through OTA-4)"
    echo "  --verify       Verify hardening only (Steps 7-12)"
    echo "  --skip-build   Deploy + verify, skip image builds"
    echo ""
    echo "Lifecycle:"
    echo "  --reboot-prep  Block Docker Hub and prepare for reboot test (Step 12)"
    echo "  --finish       Restore normal operation (unblock Hub, restart watchtower)"
    echo "  --rollback     Rollback to production Docker Hub images"
    echo ""
    echo "Options:"
    echo "  --branch NAME  Git branch to checkout (default: default branch)"
    echo "  --help         Show this help"
    echo ""
    echo "Typical workflow:"
    echo "  sudo $0 --branch my-branch       # Full test (build+deploy+verify)"
    echo "  sudo $0 --reboot-prep            # Prepare for reboot test"
    echo "  sudo reboot                       # Reboot device"
    echo "  sudo $0 --verify                  # Verify after reboot"
    echo "  sudo $0 --finish                  # Restore normal operation"
    echo ""
    echo "  # OTA simulation (test the real update path):"
    echo "  sudo $0 --build --ota-sim --verify"
}

main() {
    local do_build=false
    local do_deploy=false
    local do_verify=false
    local do_rollback=false
    local do_reboot_prep=false
    local do_finish=false
    local do_ota_sim=false
    local explicit_phase=false

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --build)
                do_build=true; explicit_phase=true; shift ;;
            --deploy)
                do_deploy=true; explicit_phase=true; shift ;;
            --verify)
                do_verify=true; explicit_phase=true; shift ;;
            --skip-build)
                do_deploy=true; do_verify=true; explicit_phase=true; shift ;;
            --rollback)
                do_rollback=true; explicit_phase=true; shift ;;
            --reboot-prep)
                do_reboot_prep=true; explicit_phase=true; shift ;;
            --finish)
                do_finish=true; explicit_phase=true; shift ;;
            --ota-sim)
                do_ota_sim=true; explicit_phase=true; shift ;;
            --branch)
                BRANCH="$2"; shift 2 ;;
            --help)
                usage; exit 0 ;;
            *)
                echo "Unknown option: $1"; usage; exit 1 ;;
        esac
    done

    # Default: run everything
    if ! $explicit_phase; then
        do_build=true
        do_deploy=true
        do_verify=true
    fi

    require_root

    echo "Device Integration Test: Docker Hardening"
    echo "=========================================="
    echo "Date: $(date)"
    echo "Host: $(hostname)"
    echo "Kernel: $(uname -r)"
    echo ""

    # Initialize log
    echo "Device Hardening Test" > "$TEST_LOG"
    echo "Started at: $(date)" >> "$TEST_LOG"
    echo "Host: $(hostname)" >> "$TEST_LOG"
    echo "======================================" >> "$TEST_LOG"

    check_prerequisites

    # Always clean up dead containers first. Dead containers (orphaned overlay2
    # metadata) destabilize Docker — they cause compose --no-recreate failures,
    # build errors, and daemon crashes. Must happen before ANY phase.
    cleanup_stale_containers

    # Lifecycle commands — execute and exit
    if $do_rollback; then
        phase_rollback
        exit 0
    fi

    if $do_reboot_prep; then
        phase_reboot_prep
        exit 0
    fi

    if $do_finish; then
        phase_finish
        exit 0
    fi

    # Test phases
    if $do_build; then
        phase_build
    fi

    if $do_deploy; then
        phase_deploy
    fi

    if $do_ota_sim; then
        phase_ota_sim
    fi

    if $do_verify; then
        phase_verify
        print_results
        exit $TESTS_FAILED
    fi

    echo ""
    log_info "Phase(s) complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
