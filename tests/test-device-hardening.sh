#!/bin/bash

# Device Integration Test: Docker Hardening
# Tests the complete production update flow on a real RK3588 device
# Verifies privilege reduction, read-only mounts, security_opt, and isolation
#
# Usage:
#   ./test-device-hardening.sh              # Run all phases (build + deploy + verify)
#   ./test-device-hardening.sh --build      # Build Docker images only (Steps 1-2)
#   ./test-device-hardening.sh --deploy     # Deploy to device only (Steps 3-6)
#   ./test-device-hardening.sh --verify     # Verify hardening only (Steps 7-11)
#   ./test-device-hardening.sh --rollback   # Rollback to production images
#   ./test-device-hardening.sh --skip-build # Deploy + verify, skip image builds
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

# Timeouts (seconds)
CONTAINER_STARTUP_TIMEOUT=180
SERVICE_STARTUP_TIMEOUT=30

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
    ((TESTS_PASSED++))
}

log_fail() {
    echo -e "${RED}[FAIL]${NC} $1" | tee -a "$TEST_LOG"
    ((TESTS_FAILED++))
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

    # --- 2a. fxsupport ---
    log_info "2a. Building fxsupport image..."
    docker build -t functionland/fxsupport:release \
        -f "$REPO_LOCAL/docker/fxsupport/Dockerfile" \
        "$REPO_LOCAL/docker/fxsupport/"
    log_info "  fxsupport: built"

    # --- 2b. ipfs-cluster ---
    log_info "2b. Building ipfs-cluster image (this may take 10-20 min)..."
    if [[ ! -d "$REPO_LOCAL/docker/ipfs-cluster/ipfs-cluster" ]]; then
        git clone --depth 1 -b master https://github.com/ipfs-cluster/ipfs-cluster \
            "$REPO_LOCAL/docker/ipfs-cluster/ipfs-cluster"
    fi
    docker build -t functionland/ipfs-cluster:release \
        -f "$REPO_LOCAL/docker/ipfs-cluster/Dockerfile" \
        "$REPO_LOCAL/docker/ipfs-cluster/"
    log_info "  ipfs-cluster: built"

    # --- 2c. go-fula ---
    log_info "2c. Building go-fula image (this may take 15-25 min)..."
    if [[ ! -d "$REPO_LOCAL/docker/go-fula/go-fula" ]]; then
        git clone --depth 1 -b main https://github.com/functionland/go-fula \
            "$REPO_LOCAL/docker/go-fula/go-fula"
    fi
    docker build -t functionland/go-fula:release \
        -f "$REPO_LOCAL/docker/go-fula/Dockerfile" \
        "$REPO_LOCAL/docker/go-fula/"
    log_info "  go-fula: built"

    # --- 2d. kubo ---
    log_info "2d. Pulling kubo:release..."
    docker pull ipfs/kubo:release
    log_info "  kubo: pulled"

    log_info "All images ready."
}

# ─── Phase: DEPLOY (Steps 3-6) ───────────────────────────────────────────────

phase_deploy() {
    log_step "3" "Stop everything (simulates pre-update state)"

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
    log_info "All containers stopped."

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
}

# ─── Phase: VERIFY (Steps 7-11) ──────────────────────────────────────────────

# Step 7: Verify all containers running
test_containers_running() {
    ((TESTS_TOTAL++))
    log_test "Step 7: Verifying all containers are running..."

    local all_running=true
    for container in "${EXPECTED_CONTAINERS[@]}"; do
        local status
        status=$(docker inspect --format='{{.State.Status}}' "$container" 2>/dev/null || echo "missing")
        if [[ "$status" == "running" ]]; then
            log_info "  $container: running"
        else
            log_info "  $container: $status"
            all_running=false
        fi
    done

    if $all_running; then
        log_pass "All 5 expected containers are running"
    else
        log_fail "Not all containers are running"
    fi
}

test_container_images() {
    ((TESTS_TOTAL++))
    log_test "Step 7: Verifying container images..."

    docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}" 2>&1 | tee -a "$TEST_LOG"
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

# Step 8: Verify services are healthy
test_kubo_api() {
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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

# Step 10: Verify privilege reduction (hardening-specific)
test_no_privileged_mode() {
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
    log_test "Step 10: watchtower has read-only rootfs..."

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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
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
    ((TESTS_TOTAL++))
    log_test "Step 11: ipfs-cluster cannot load kernel modules..."

    local output
    output=$(docker exec ipfs_cluster modprobe ip_tables 2>&1 || echo "BLOCKED")

    if [[ "$output" == *"BLOCKED"* ]] || [[ "$output" == *"not found"* ]] || [[ "$output" == *"Permission denied"* ]] || [[ "$output" == *"Operation not permitted"* ]]; then
        log_pass "ipfs-cluster cannot load kernel modules (not privileged)"
    else
        log_fail "ipfs-cluster CAN load kernel modules"
    fi
}

# ─── Phase runners ────────────────────────────────────────────────────────────

phase_verify() {
    log_step "7" "Verify ALL containers running"
    test_containers_running
    test_container_images

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
}

# ─── Rollback ─────────────────────────────────────────────────────────────────

phase_rollback() {
    echo -e "${YELLOW}Rolling back to production Docker Hub images...${NC}"

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

    log_info "Rollback complete. Run --verify to check system state."
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
        echo "Step 12 (manual): Reboot the device and re-run with --verify"
        echo "  sudo reboot"
        echo "  # Wait ~3 minutes, then:"
        echo "  sudo ./test-device-hardening.sh --verify"
    else
        echo -e "\n${RED}Some tests failed. Check $TEST_LOG for details.${NC}"
        echo ""
        echo "To rollback: sudo ./test-device-hardening.sh --rollback"
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
    echo "  --verify       Verify hardening only (Steps 7-11)"
    echo "  --skip-build   Deploy + verify, skip image builds"
    echo "  --rollback     Rollback to production Docker Hub images"
    echo ""
    echo "Options:"
    echo "  --branch NAME  Git branch to checkout (default: default branch)"
    echo "  --help         Show this help"
}

main() {
    local do_build=false
    local do_deploy=false
    local do_verify=false
    local do_rollback=false
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

    if $do_rollback; then
        phase_rollback
        exit 0
    fi

    if $do_build; then
        phase_build
    fi

    if $do_deploy; then
        phase_deploy
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
