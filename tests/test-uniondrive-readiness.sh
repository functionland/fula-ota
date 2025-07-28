#!/bin/bash

# Unit Test Suite for Uniondrive Service and Readiness Check
# Tests: uniondrive service, readiness-check.py script for Armbian/Rockchip3588

set -e

# Test configuration
TEST_LOG="/tmp/uniondrive-readiness-test.log"
READINESS_SCRIPT="../docker/fxsupport/linux/readiness-check.py"
UNIONDRIVE_SERVICE="../docker/fxsupport/linux/uniondrive.service"
UNION_DRIVE_SCRIPT="../docker/fxsupport/linux/union-drive.sh"
TEST_MOUNT_POINT="/tmp/test-uniondrive-mount"
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

# Expected readiness check functions
EXPECTED_READINESS_FUNCTIONS=(
    "start_led_flash"
    "stop_led_flash"
    "get_wifi_info_and_ping"
    "check_fs_type"
    "check_conditions"
    "check_wifi_connection"
    "attempt_wifi_connection"
    "check_and_fix_ipfs_cluster"
    "check_and_fix_ipfs_host"
    "check_internet_connection"
    "check_external_drive"
    "monitor_docker_logs_and_restart"
    "main"
)

# Expected uniondrive components
EXPECTED_UNIONDRIVE_COMPONENTS=(
    "overlayfs"
    "unionfs"
    "mount"
    "umount"
    "storage"
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

# Setup test environment
setup_test_env() {
    log_test "Setting up test environment..."
    
    # Create test directories
    mkdir -p "$TEST_MOUNT_POINT" "$TEST_INTERNAL"
    
    # Create mock config files
    touch "$TEST_INTERNAL/config.yaml"
    touch "$TEST_INTERNAL/.ipfs_setup"
    
    log_pass "Test environment setup complete"
}

# Cleanup test environment
cleanup_test_env() {
    log_test "Cleaning up test environment..."
    rm -rf "$TEST_MOUNT_POINT" "$TEST_INTERNAL" 2>/dev/null || true
    log_pass "Test environment cleanup complete"
}

# Test readiness-check.py script exists and is valid Python
test_readiness_script_exists() {
    ((TESTS_TOTAL++))
    log_test "Testing readiness-check.py script existence and validity..."
    
    if [[ ! -f "$READINESS_SCRIPT" ]]; then
        log_fail "readiness-check.py not found at $READINESS_SCRIPT"
        return 1
    fi
    
    # Test Python syntax
    if command -v python3 >/dev/null 2>&1; then
        if ! python3 -m py_compile "$READINESS_SCRIPT" 2>/dev/null; then
            log_fail "readiness-check.py has invalid Python syntax"
            return 1
        fi
    else
        log_warn "Python3 not available, skipping syntax validation"
    fi
    
    # Check shebang
    if ! head -n1 "$READINESS_SCRIPT" | grep -q "python"; then
        log_warn "readiness-check.py missing proper Python shebang"
    fi
    
    log_pass "readiness-check.py exists and has valid syntax"
}

# Test readiness script functions
test_readiness_functions() {
    ((TESTS_TOTAL++))
    log_test "Testing readiness-check.py function definitions..."
    
    local missing_functions=()
    
    for func in "${EXPECTED_READINESS_FUNCTIONS[@]}"; do
        if ! grep -q "def $func" "$READINESS_SCRIPT"; then
            missing_functions+=("$func")
        fi
    done
    
    if [[ ${#missing_functions[@]} -gt 0 ]]; then
        log_fail "Missing functions in readiness-check.py: ${missing_functions[*]}"
        return 1
    fi
    
    log_pass "All expected functions are defined in readiness-check.py"
}

# Test LED control functionality
test_led_control() {
    ((TESTS_TOTAL++))
    log_test "Testing LED control functionality..."
    
    # Check for LED control imports and functions
    local led_components=(
        "start_led_flash"
        "stop_led_flash"
        "threading"
        "LED_PATH"
    )
    
    local missing_led=()
    
    for component in "${led_components[@]}"; do
        if ! grep -q "$component" "$READINESS_SCRIPT"; then
            missing_led+=("$component")
        fi
    done
    
    if [[ ${#missing_led[@]} -gt 0 ]]; then
        log_warn "LED control components not found: ${missing_led[*]}"
    else
        log_pass "LED control functionality is implemented"
    fi
}

# Test WiFi management
test_wifi_management() {
    ((TESTS_TOTAL++))
    log_test "Testing WiFi management functionality..."
    
    # Check for WiFi-related functions
    local wifi_functions=(
        "get_wifi_info_and_ping"
        "check_wifi_connection"
        "attempt_wifi_connection"
    )
    
    local missing_wifi=()
    
    for func in "${wifi_functions[@]}"; do
        if ! grep -q "def $func" "$READINESS_SCRIPT"; then
            missing_wifi+=("$func")
        fi
    done
    
    if [[ ${#missing_wifi[@]} -gt 0 ]]; then
        log_fail "Missing WiFi functions: ${missing_wifi[*]}"
        return 1
    fi
    
    # Check for NetworkManager integration
    if ! grep -q "nmcli\|NetworkManager" "$READINESS_SCRIPT"; then
        log_warn "NetworkManager integration not found"
    fi
    
    log_pass "WiFi management functionality is implemented"
}

# Test Docker container monitoring
test_docker_monitoring() {
    ((TESTS_TOTAL++))
    log_test "Testing Docker container monitoring..."
    
    # Check for Docker monitoring functions
    local docker_functions=(
        "check_and_fix_ipfs_cluster"
        "check_and_fix_ipfs_host"
        "monitor_docker_logs_and_restart"
    )
    
    local missing_docker=()
    
    for func in "${docker_functions[@]}"; do
        if ! grep -q "def $func" "$READINESS_SCRIPT"; then
            missing_docker+=("$func")
        fi
    done
    
    if [[ ${#missing_docker[@]} -gt 0 ]]; then
        log_fail "Missing Docker monitoring functions: ${missing_docker[*]}"
        return 1
    fi
    
    # Check for Docker command usage
    if ! grep -q "docker\|subprocess" "$READINESS_SCRIPT"; then
        log_warn "Docker command integration not found"
    fi
    
    log_pass "Docker container monitoring is implemented"
}

# Test external drive management
test_external_drive_management() {
    ((TESTS_TOTAL++))
    log_test "Testing external drive management..."
    
    # Check for drive management functions
    if ! grep -q "check_external_drive\|format_drive" "$READINESS_SCRIPT"; then
        log_fail "External drive management functions not found"
        return 1
    fi
    
    # Check for filesystem operations
    local fs_operations=(
        "mount"
        "umount"
        "fdisk"
        "mkfs"
    )
    
    local found_ops=0
    for op in "${fs_operations[@]}"; do
        if grep -q "$op" "$READINESS_SCRIPT"; then
            ((found_ops++))
        fi
    done
    
    if [[ $found_ops -lt 2 ]]; then
        log_warn "Limited filesystem operations found"
    fi
    
    log_pass "External drive management is implemented"
}

# Test uniondrive service file
test_uniondrive_service() {
    ((TESTS_TOTAL++))
    log_test "Testing uniondrive service file..."
    
    if [[ ! -f "$UNIONDRIVE_SERVICE" ]]; then
        log_fail "uniondrive.service not found at $UNIONDRIVE_SERVICE"
        return 1
    fi
    
    # Check service file structure
    local service_sections=(
        "\[Unit\]"
        "\[Service\]"
        "\[Install\]"
    )
    
    for section in "${service_sections[@]}"; do
        if ! grep -q "$section" "$UNIONDRIVE_SERVICE"; then
            log_fail "Missing section $section in uniondrive.service"
            return 1
        fi
    done
    
    # Check for ExecStart
    if ! grep -q "ExecStart" "$UNIONDRIVE_SERVICE"; then
        log_fail "ExecStart not found in uniondrive.service"
        return 1
    fi
    
    log_pass "uniondrive.service is properly structured"
}

# Test union-drive.sh script
test_union_drive_script() {
    ((TESTS_TOTAL++))
    log_test "Testing union-drive.sh script..."
    
    if [[ ! -f "$UNION_DRIVE_SCRIPT" ]]; then
        log_fail "union-drive.sh not found at $UNION_DRIVE_SCRIPT"
        return 1
    fi
    
    # Check for unionfs/overlayfs functionality
    local union_components=()
    
    for component in "${EXPECTED_UNIONDRIVE_COMPONENTS[@]}"; do
        if ! grep -qi "$component" "$UNION_DRIVE_SCRIPT"; then
            union_components+=("$component")
        fi
    done
    
    if [[ ${#union_components[@]} -gt 2 ]]; then
        log_warn "Many uniondrive components not found: ${union_components[*]}"
    fi
    
    # Check for mount operations
    if ! grep -q "mount\|umount" "$UNION_DRIVE_SCRIPT"; then
        log_fail "Mount operations not found in union-drive.sh"
        return 1
    fi
    
    log_pass "union-drive.sh script is properly implemented"
}

# Test Armbian/Rockchip3588 specific features
test_armbian_rockchip_features() {
    ((TESTS_TOTAL++))
    log_test "Testing Armbian/Rockchip3588 specific features..."
    
    # Check for hardware-specific paths and configurations
    local hw_paths=(
        "/dev/"
        "/sys/"
        "/proc/"
        "gpio"
        "led"
    )
    
    local found_hw=0
    for path in "${hw_paths[@]}"; do
        if grep -q "$path" "$READINESS_SCRIPT" "$UNION_DRIVE_SCRIPT" 2>/dev/null; then
            ((found_hw++))
        fi
    done
    
    if [[ $found_hw -lt 2 ]]; then
        log_warn "Limited hardware-specific features found"
    else
        log_pass "Hardware-specific features are implemented"
    fi
}

# Test error handling and logging
test_error_handling() {
    ((TESTS_TOTAL++))
    log_test "Testing error handling and logging..."
    
    # Check for logging in readiness script
    if ! grep -q "logging\|log" "$READINESS_SCRIPT"; then
        log_fail "Logging not found in readiness-check.py"
        return 1
    fi
    
    # Check for exception handling
    if ! grep -q "try:\|except\|Exception" "$READINESS_SCRIPT"; then
        log_warn "Exception handling not found in readiness-check.py"
    fi
    
    # Check for error handling in shell scripts
    if [[ -f "$UNION_DRIVE_SCRIPT" ]]; then
        if ! grep -q "set -e\|exit\|return" "$UNION_DRIVE_SCRIPT"; then
            log_warn "Error handling not found in union-drive.sh"
        fi
    fi
    
    log_pass "Error handling and logging are implemented"
}

# Test system integration
test_system_integration() {
    ((TESTS_TOTAL++))
    log_test "Testing system integration..."
    
    # Check for systemctl integration
    if ! grep -q "systemctl\|systemd" "$READINESS_SCRIPT" 2>/dev/null; then
        log_warn "systemd integration not found"
    fi
    
    # Check for cron/timer integration
    if ! grep -q "cron\|timer" "$READINESS_SCRIPT" "$UNION_DRIVE_SCRIPT" 2>/dev/null; then
        log_warn "Scheduled task integration not found"
    fi
    
    # Check for network management
    if ! grep -q "nmcli\|networkctl\|ifconfig" "$READINESS_SCRIPT" 2>/dev/null; then
        log_warn "Network management integration not found"
    fi
    
    log_pass "System integration components checked"
}

# Main test execution
main() {
    echo "🔧 Uniondrive & Readiness Check Unit Test Suite"
    echo "==============================================="
    echo "Testing uniondrive service and readiness-check.py for Armbian/Rockchip3588"
    echo ""
    
    # Initialize test log
    echo "Uniondrive & readiness test started at $(date)" > "$TEST_LOG"
    
    # Setup test environment
    setup_test_env
    
    # Run tests
    test_readiness_script_exists
    test_readiness_functions
    test_led_control
    test_wifi_management
    test_docker_monitoring
    test_external_drive_management
    test_uniondrive_service
    test_union_drive_script
    test_armbian_rockchip_features
    test_error_handling
    test_system_integration
    
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
        echo -e "\n${GREEN}✅ All uniondrive & readiness tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}❌ Some uniondrive & readiness tests failed. Check $TEST_LOG for details.${NC}"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
