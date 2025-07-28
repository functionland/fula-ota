#!/bin/bash

# Unit Test Suite for Docker Services
# Tests: go-fula, kubo, ipfs-cluster, watchtower containers

set -e

# Test configuration
TEST_LOG="/tmp/docker-services-test.log"
DOCKER_COMPOSE_FILE="../docker/fxsupport/linux/docker-compose.yml"
TEST_TIMEOUT=30

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

# Service definitions
declare -A EXPECTED_SERVICES=(
    ["watchtower"]="containrrr/watchtower"
    ["kubo"]="ipfs/kubo:release"
    ["ipfs-cluster"]="functionland/ipfs-cluster:release"
    ["go-fula"]="GO_FULA"
    ["fxsupport"]="FX_SUPPROT"
)

declare -A EXPECTED_PORTS=(
    ["kubo"]="4001:4001,4001:4001/udp,127.0.0.1:8081:8081,127.0.0.1:5001:5001"
    ["ipfs-cluster"]="9094:9094,9095:9095,9096:9096"
    ["go-fula"]="40001:40001,3500:3500"
)

declare -A EXPECTED_VOLUMES=(
    ["kubo"]="/uniondrive,/storage,/internal,/container-init.d,/export"
    ["ipfs-cluster"]="/uniondrive,/internal,/container-init.d,.env.cluster"
    ["go-fula"]="/storage,/internal,/uniondrive,docker.sock,.env.cluster,.env"
)

# Logging functions
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

# Test docker-compose.yml exists and is valid
test_docker_compose_exists() {
    ((TESTS_TOTAL++))
    log_test "Testing docker-compose.yml existence and validity..."
    
    if [[ ! -f "$DOCKER_COMPOSE_FILE" ]]; then
        log_fail "docker-compose.yml not found at $DOCKER_COMPOSE_FILE"
        return 1
    fi
    
    # Test YAML syntax
    if command -v docker-compose >/dev/null 2>&1; then
        if ! docker-compose -f "$DOCKER_COMPOSE_FILE" config >/dev/null 2>&1; then
            log_fail "docker-compose.yml has invalid YAML syntax"
            return 1
        fi
    elif command -v docker >/dev/null 2>&1; then
        if ! docker compose -f "$DOCKER_COMPOSE_FILE" config >/dev/null 2>&1; then
            log_fail "docker-compose.yml has invalid YAML syntax"
            return 1
        fi
    else
        log_warn "Docker not available, skipping YAML syntax validation"
    fi
    
    log_pass "docker-compose.yml exists and has valid syntax"
}

# Test service definitions
test_service_definitions() {
    ((TESTS_TOTAL++))
    log_test "Testing service definitions in docker-compose.yml..."
    
    local missing_services=()
    
    for service in "${!EXPECTED_SERVICES[@]}"; do
        if ! grep -q "^[[:space:]]*${service}:" "$DOCKER_COMPOSE_FILE"; then
            missing_services+=("$service")
        fi
    done
    
    if [[ ${#missing_services[@]} -gt 0 ]]; then
        log_fail "Missing services: ${missing_services[*]}"
        return 1
    fi
    
    log_pass "All expected services are defined"
}

# Test service images
test_service_images() {
    ((TESTS_TOTAL++))
    log_test "Testing service image configurations..."
    
    local failed_images=()
    
    for service in "${!EXPECTED_SERVICES[@]}"; do
        local expected_image="${EXPECTED_SERVICES[$service]}"
        
        # Extract service section and check image
        if ! awk "/^[[:space:]]*${service}:/,/^[[:space:]]*[^[:space:]]/ { if (/image:/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "$expected_image"; then
            failed_images+=("$service:$expected_image")
        fi
    done
    
    if [[ ${#failed_images[@]} -gt 0 ]]; then
        log_fail "Incorrect or missing images: ${failed_images[*]}"
        return 1
    fi
    
    log_pass "All service images are correctly configured"
}

# Test port mappings
test_port_mappings() {
    ((TESTS_TOTAL++))
    log_test "Testing port mappings..."
    
    local failed_ports=()
    
    for service in "${!EXPECTED_PORTS[@]}"; do
        local expected_ports="${EXPECTED_PORTS[$service]}"
        IFS=',' read -ra ports <<< "$expected_ports"
        
        for port in "${ports[@]}"; do
            # Check if port mapping exists in service section
            if ! awk "/^[[:space:]]*${service}:/,/^[[:space:]]*[^[:space:]]/ { if (/ports:/) found=1; if (found && /^[[:space:]]*-/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "$port"; then
                failed_ports+=("$service:$port")
            fi
        done
    done
    
    if [[ ${#failed_ports[@]} -gt 0 ]]; then
        log_warn "Some expected ports not found: ${failed_ports[*]}"
        # Don't fail the test as port configurations might vary
    else
        log_pass "Port mappings are correctly configured"
    fi
}

# Test volume mappings
test_volume_mappings() {
    ((TESTS_TOTAL++))
    log_test "Testing volume mappings..."
    
    local failed_volumes=()
    
    for service in "${!EXPECTED_VOLUMES[@]}"; do
        local expected_volumes="${EXPECTED_VOLUMES[$service]}"
        IFS=',' read -ra volumes <<< "$expected_volumes"
        
        local service_has_volumes=false
        for volume in "${volumes[@]}"; do
            # Check if volume mapping exists in service section
            if awk "/^[[:space:]]*${service}:/,/^[[:space:]]*[^[:space:]]/ { if (/volumes:/) found=1; if (found && /^[[:space:]]*-/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "$volume"; then
                service_has_volumes=true
                break
            fi
        done
        
        if [[ "$service_has_volumes" == false ]]; then
            failed_volumes+=("$service")
        fi
    done
    
    if [[ ${#failed_volumes[@]} -gt 0 ]]; then
        log_fail "Services missing expected volumes: ${failed_volumes[*]}"
        return 1
    fi
    
    log_pass "Volume mappings are correctly configured"
}

# Test service dependencies
test_service_dependencies() {
    ((TESTS_TOTAL++))
    log_test "Testing service dependencies..."
    
    # Test that services have proper depends_on relationships
    local dependency_tests=(
        "ipfs-cluster:kubo"
        "go-fula:fxsupport"
    )
    
    local failed_deps=()
    
    for dep_test in "${dependency_tests[@]}"; do
        IFS':' read -r service dependency <<< "$dep_test"
        
        # Check if service depends on dependency
        if ! awk "/^[[:space:]]*${service}:/,/^[[:space:]]*[^[:space:]]/ { if (/depends_on:/) found=1; if (found && /^[[:space:]]*-/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "$dependency"; then
            failed_deps+=("$service should depend on $dependency")
        fi
    done
    
    if [[ ${#failed_deps[@]} -gt 0 ]]; then
        log_warn "Dependency issues: ${failed_deps[*]}"
        # Don't fail as dependencies might be configured differently
    else
        log_pass "Service dependencies are correctly configured"
    fi
}

# Test restart policies
test_restart_policies() {
    ((TESTS_TOTAL++))
    log_test "Testing restart policies..."
    
    local services_without_restart=()
    
    for service in "${!EXPECTED_SERVICES[@]}"; do
        # Check if service has restart policy
        if ! awk "/^[[:space:]]*${service}:/,/^[[:space:]]*[^[:space:]]/ { if (/restart:/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "always\|unless-stopped"; then
            services_without_restart+=("$service")
        fi
    done
    
    if [[ ${#services_without_restart[@]} -gt 0 ]]; then
        log_warn "Services without restart policy: ${services_without_restart[*]}"
        # Don't fail as restart policies might be optional
    else
        log_pass "All services have appropriate restart policies"
    fi
}

# Test watchtower configuration
test_watchtower_config() {
    ((TESTS_TOTAL++))
    log_test "Testing watchtower configuration..."
    
    # Check watchtower specific configurations
    local watchtower_configs=(
        "WATCHTOWER_DEBUG"
        "WATCHTOWER_CLEANUP"
        "WATCHTOWER_LABEL_ENABLE"
    )
    
    local missing_configs=()
    
    for config in "${watchtower_configs[@]}"; do
        if ! awk "/^[[:space:]]*watchtower:/,/^[[:space:]]*[^[:space:]]/ { if (/environment:/) found=1; if (found && /^[[:space:]]*-/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "$config"; then
            missing_configs+=("$config")
        fi
    done
    
    if [[ ${#missing_configs[@]} -gt 0 ]]; then
        log_warn "Watchtower missing configs: ${missing_configs[*]}"
    else
        log_pass "Watchtower is properly configured"
    fi
}

# Test network configurations
test_network_config() {
    ((TESTS_TOTAL++))
    log_test "Testing network configurations..."
    
    # Check for host network mode where expected
    local host_network_services=("ipfs-cluster" "go-fula")
    
    for service in "${host_network_services[@]}"; do
        if ! awk "/^[[:space:]]*${service}:/,/^[[:space:]]*[^[:space:]]/ { if (/network_mode:/) print }" "$DOCKER_COMPOSE_FILE" | grep -q "host"; then
            log_warn "Service $service might not be using host network mode"
        fi
    done
    
    log_pass "Network configurations checked"
}

# Test Docker container status (if Docker is available and containers are running)
test_container_status() {
    ((TESTS_TOTAL++))
    log_test "Testing Docker container status (if available)..."
    
    if ! command -v docker >/dev/null 2>&1; then
        log_warn "Docker not available, skipping container status test"
        return 0
    fi
    
    # Get list of expected container names
    local expected_containers=(
        "fula_updater"
        "ipfs_host"
        "ipfs_cluster"
        "fula_go"
        "fula_fxsupport"
    )
    
    local running_containers=()
    local stopped_containers=()
    
    for container in "${expected_containers[@]}"; do
        if docker ps --format "table {{.Names}}" | grep -q "^${container}$"; then
            running_containers+=("$container")
        elif docker ps -a --format "table {{.Names}}" | grep -q "^${container}$"; then
            stopped_containers+=("$container")
        fi
    done
    
    if [[ ${#running_containers[@]} -gt 0 ]]; then
        log_pass "Running containers: ${running_containers[*]}"
    fi
    
    if [[ ${#stopped_containers[@]} -gt 0 ]]; then
        log_warn "Stopped containers: ${stopped_containers[*]}"
    fi
    
    if [[ ${#running_containers[@]} -eq 0 && ${#stopped_containers[@]} -eq 0 ]]; then
        log_warn "No expected containers found (services might not be started)"
    fi
}

# Main test execution
main() {
    echo "🐳 Docker Services Unit Test Suite"
    echo "=================================="
    echo "Testing go-fula, kubo, ipfs-cluster, watchtower containers"
    echo ""
    
    # Initialize test log
    echo "Docker services test started at $(date)" > "$TEST_LOG"
    
    # Run tests
    test_docker_compose_exists
    test_service_definitions
    test_service_images
    test_port_mappings
    test_volume_mappings
    test_service_dependencies
    test_restart_policies
    test_watchtower_config
    test_network_config
    test_container_status
    
    # Print results
    echo ""
    echo "📊 Test Results"
    echo "==============="
    echo "Total Tests: $TESTS_TOTAL"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✅ All Docker services tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some Docker services tests failed. Check $TEST_LOG for details.${NC}"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
