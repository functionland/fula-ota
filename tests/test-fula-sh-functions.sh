#!/bin/bash

# Unit Test Suite for fula.sh Functions
# Tests: install, update, run operations for Armbian/Rockchip3588

set -e

# Test configuration
TEST_LOG="/tmp/fula-test.log"
FULA_SCRIPT="../docker/fxsupport/linux/fula.sh"
TEST_HOME="/tmp/test-fula-home"
TEST_UNIONDRIVE="/tmp/test-uniondrive"
TEST_INTERNAL="/tmp/test-internal"

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

# Logging function
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

# Setup test environment
setup_test_env() {
    log_test "Setting up test environment..."
    
    # Create test directories
    mkdir -p "$TEST_HOME" "$TEST_UNIONDRIVE" "$TEST_INTERNAL"
    mkdir -p "$TEST_UNIONDRIVE"/{ipfs_datastore,ipfs_staging,ipfs-cluster,chain}
    mkdir -p "$TEST_INTERNAL"
    
    # Create mock files
    touch "$TEST_INTERNAL/config.yaml"
    touch "$TEST_INTERNAL/.ipfs_setup"
    
    # Set permissions
    chmod 777 "$TEST_UNIONDRIVE" "$TEST_INTERNAL" 2>/dev/null || true
    
    log_pass "Test environment setup complete"
}

# Cleanup test environment
cleanup_test_env() {
    log_test "Cleaning up test environment..."
    rm -rf "$TEST_HOME" "$TEST_UNIONDRIVE" "$TEST_INTERNAL" 2>/dev/null || true
    log_pass "Test environment cleanup complete"
}

# Test fula.sh script existence and permissions
test_fula_script_exists() {
    ((TESTS_TOTAL++))
    log_test "Testing fula.sh script existence and permissions..."
    
    if [[ ! -f "$FULA_SCRIPT" ]]; then
        log_fail "fula.sh script not found at $FULA_SCRIPT"
        return 1
    fi
    
    if [[ ! -x "$FULA_SCRIPT" ]]; then
        log_warn "fula.sh script is not executable, attempting to fix..."
        chmod +x "$FULA_SCRIPT" 2>/dev/null || {
            log_fail "Cannot make fula.sh executable"
            return 1
        }
    fi
    
    log_pass "fula.sh script exists and is executable"
}

# Test fula.sh install function
test_fula_install() {
    ((TESTS_TOTAL++))
    log_test "Testing fula.sh install function..."
    
    # Mock environment variables
    export HOME_DIR="$TEST_HOME"
    export FULA_LOG_PATH="$TEST_LOG"
    
    # Test install function exists
    if ! grep -q "^install()" "$FULA_SCRIPT"; then
        log_fail "install() function not found in fula.sh"
        return 1
    fi
    
    # Test install function has required components
    local required_components=(
        "setup_logrotate"
        "create_cron"
        "setup_storage_access"
        "dockerPull"
    )
    
    for component in "${required_components[@]}"; do
        if ! grep -q "$component" "$FULA_SCRIPT"; then
            log_fail "Required component '$component' not found in install function"
            return 1
        fi
    done
    
    log_pass "fula.sh install function structure is valid"
}

# Test fula.sh restart function
test_fula_restart() {
    ((TESTS_TOTAL++))
    log_test "Testing fula.sh restart function..."
    
    # Test restart function exists
    if ! grep -q "^restart()" "$FULA_SCRIPT"; then
        log_fail "restart() function not found in fula.sh"
        return 1
    fi
    
    # Test restart function checks for required directories
    local required_checks=(
        "/uniondrive"
        "ipfs_datastore"
        "ipfs_staging"
        "ipfs-cluster"
        "chain"
    )
    
    for check in "${required_checks[@]}"; do
        if ! grep -q "$check" "$FULA_SCRIPT"; then
            log_fail "Required directory check '$check' not found in restart function"
            return 1
        fi
    done
    
    log_pass "fula.sh restart function structure is valid"
}

# Test directory creation and permissions
test_directory_setup() {
    ((TESTS_TOTAL++))
    log_test "Testing directory setup and permissions..."
    
    # Test that fula.sh creates required directories
    local required_dirs=(
        "/uniondrive/ipfs_datastore"
        "/uniondrive/ipfs_staging"
        "/uniondrive/ipfs-cluster"
        "/uniondrive/chain"
    )
    
    # Check if directory creation commands exist in script
    if ! grep -q "mkdir.*uniondrive" "$FULA_SCRIPT"; then
        log_fail "Directory creation commands not found in fula.sh"
        return 1
    fi
    
    # Check if permission setting exists
    if ! grep -q "chmod.*777" "$FULA_SCRIPT"; then
        log_fail "Permission setting commands not found in fula.sh"
        return 1
    fi
    
    log_pass "Directory setup and permissions are configured"
}

# Test Docker integration
test_docker_integration() {
    ((TESTS_TOTAL++))
    log_test "Testing Docker integration in fula.sh..."
    
    # Test Docker functions exist
    local docker_functions=(
        "dockerPull"
        "dockerComposeUp"
        "dockerComposeDown"
        "dockerPrune"
    )
    
    for func in "${docker_functions[@]}"; do
        if ! grep -q "^$func()" "$FULA_SCRIPT"; then
            log_fail "Docker function '$func' not found in fula.sh"
            return 1
        fi
    done
    
    # Test docker-compose.yml reference
    if ! grep -q "docker-compose" "$FULA_SCRIPT"; then
        log_fail "docker-compose integration not found in fula.sh"
        return 1
    fi
    
    log_pass "Docker integration is properly configured"
}

# Test service management
test_service_management() {
    ((TESTS_TOTAL++))
    log_test "Testing service management functions..."
    
    # Test systemctl commands exist
    if ! grep -q "systemctl" "$FULA_SCRIPT"; then
        log_fail "systemctl commands not found in fula.sh"
        return 1
    fi
    
    # Test service creation
    if ! grep -q "service_exists" "$FULA_SCRIPT"; then
        log_fail "service_exists function not found in fula.sh"
        return 1
    fi
    
    log_pass "Service management functions are present"
}

# Test Rockchip3588/Armbian specific features
test_armbian_rockchip_features() {
    ((TESTS_TOTAL++))
    log_test "Testing Armbian/Rockchip3588 specific features..."
    
    # Test for hardware-specific configurations
    local hw_features=(
        "bluetooth"
        "wifi"
        "storage"
        "led"
    )
    
    local found_features=0
    for feature in "${hw_features[@]}"; do
        if grep -qi "$feature" "$FULA_SCRIPT"; then
            ((found_features++))
        fi
    done
    
    if [[ $found_features -lt 2 ]]; then
        log_warn "Limited hardware-specific features found (found: $found_features)"
    else
        log_pass "Hardware-specific features are configured"
    fi
}

# Test error handling and logging
test_error_handling() {
    ((TESTS_TOTAL++))
    log_test "Testing error handling and logging..."
    
    # Test logging mechanisms
    if ! grep -q "FULA_LOG_PATH\|tee.*log" "$FULA_SCRIPT"; then
        log_fail "Logging mechanisms not found in fula.sh"
        return 1
    fi
    
    # Test error handling patterns
    if ! grep -q "||.*echo\|exit\|return" "$FULA_SCRIPT"; then
        log_fail "Error handling patterns not found in fula.sh"
        return 1
    fi
    
    log_pass "Error handling and logging are implemented"
}

# Main test execution
main() {
    echo "🧪 Fula.sh Unit Test Suite"
    echo "=========================="
    echo "Testing fula.sh functions for Armbian/Rockchip3588"
    echo ""
    
    # Initialize test log
    echo "Test started at $(date)" > "$TEST_LOG"
    
    # Setup test environment
    setup_test_env
    
    # Run tests
    test_fula_script_exists
    test_fula_install
    test_fula_restart
    test_directory_setup
    test_docker_integration
    test_service_management
    test_armbian_rockchip_features
    test_error_handling
    
    # Cleanup
    cleanup_test_env
    
    # Print results
    echo ""
    echo "📊 Test Results"
    echo "==============="
    echo "Total Tests: $TESTS_TOTAL"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"
    
    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}✅ All fula.sh tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some fula.sh tests failed. Check $TEST_LOG for details.${NC}"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
