#!/bin/bash

# Unit Test Suite for plugins.sh Functions
# Tests: plugin name validation, status transitions, duplicate prevention,
#        atomic file writes, timeout configuration, version tracking

set -e

# Test configuration
TEST_LOG="/tmp/plugin-test.log"
PLUGINS_SCRIPT="../docker/fxsupport/linux/plugins.sh"
TEST_DIR="/tmp/test-plugins"
TEST_PLUGINS_DIR="$TEST_DIR/plugins"
TEST_INTERNAL_DIR="$TEST_DIR/internal"
TEST_ACTIVE_FILE="$TEST_INTERNAL_DIR/active-plugins.txt"

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

# Logging functions
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

# Setup test environment
setup_test_env() {
    log_test "Setting up test environment..."

    rm -rf "$TEST_DIR"
    mkdir -p "$TEST_PLUGINS_DIR"
    mkdir -p "$TEST_INTERNAL_DIR"
    touch "$TEST_ACTIVE_FILE"

    log_pass "Test environment setup complete"
}

# Cleanup test environment
cleanup_test_env() {
    log_test "Cleaning up test environment..."
    rm -rf "$TEST_DIR" 2>/dev/null || true
    log_pass "Test environment cleanup complete"
}

# Source just the functions we need from plugins.sh (without running main)
source_plugin_functions() {
    # We can't source plugins.sh directly (it runs main logic at top level),
    # so we test by extracting and evaluating individual functions.
    # For structural tests, we grep the script directly.
    true
}

# ============================================================
# Test: Plugin name validation (item 5)
# ============================================================
test_plugin_name_validation() {
    ((++TESTS_TOTAL))
    log_test "Testing plugin name validation function exists..."

    if ! grep -q "validate_plugin_name" "$PLUGINS_SCRIPT"; then
        log_fail "validate_plugin_name function not found in plugins.sh"
        return 1
    fi

    # Extract and test the validation function
    eval "$(sed -n '/^validate_plugin_name()/,/^}/p' "$PLUGINS_SCRIPT" | sed 's/log_message/echo/g')"

    # Valid names should pass
    local valid_names=("streamr-node" "loyal-agent" "my_plugin" "Plugin123" "a" "test-plugin-v2")
    for name in "${valid_names[@]}"; do
        if ! validate_plugin_name "$name"; then
            log_fail "Valid plugin name '$name' was rejected"
            return 1
        fi
    done

    # Invalid names should fail
    local invalid_names=("../etc" "../../passwd" "my plugin" "plugin;rm -rf" 'plugin"name' "plugin/path" "" "plugin\$var" "plugin()" "my.plugin")
    for name in "${invalid_names[@]}"; do
        if validate_plugin_name "$name" 2>/dev/null; then
            log_fail "Invalid plugin name '$name' was accepted"
            return 1
        fi
    done

    log_pass "Plugin name validation works correctly"
}

# ============================================================
# Test: Path traversal prevention (item 5)
# ============================================================
test_path_traversal_prevention() {
    ((++TESTS_TOTAL))
    log_test "Testing path traversal prevention..."

    eval "$(sed -n '/^validate_plugin_name()/,/^}/p' "$PLUGINS_SCRIPT" | sed 's/log_message/echo/g')"

    local traversal_attempts=(
        "../../../etc/passwd"
        "..%2f..%2f"
        "plugin/../../../etc"
        "..\\..\\windows"
        "plugin\x00name"
    )

    for attempt in "${traversal_attempts[@]}"; do
        if validate_plugin_name "$attempt" 2>/dev/null; then
            log_fail "Path traversal attempt '$attempt' was not blocked"
            return 1
        fi
    done

    log_pass "Path traversal prevention works correctly"
}

# ============================================================
# Test: Status transitions (items 2, 10)
# ============================================================
test_status_transitions() {
    ((++TESTS_TOTAL))
    log_test "Testing status transition support..."

    # Statuses written by plugins.sh itself
    local core_statuses=("Installing" "Installed" "Failed" "Uninstalling")
    for status in "${core_statuses[@]}"; do
        if ! grep -q "\"$status\"" "$PLUGINS_SCRIPT"; then
            log_fail "Status '$status' not found in plugins.sh"
            return 1
        fi
    done

    # "Downloading" is written by plugin scripts (e.g. loyal-agent install.sh / download_model.sh)
    local found_downloading=false
    for f in ../docker/fxsupport/linux/plugins/*/install.sh ../docker/fxsupport/linux/plugins/*/custom/*.sh; do
        if [ -f "$f" ] && grep -q "Downloading" "$f"; then
            found_downloading=true
            break
        fi
    done
    if ! $found_downloading; then
        log_fail "Status 'Downloading' not found in any plugin script"
        return 1
    fi

    log_pass "All required status transitions are present"
}

# ============================================================
# Test: Status file write function
# ============================================================
test_write_plugin_status() {
    ((++TESTS_TOTAL))
    log_test "Testing write_plugin_status function..."

    # Extract and test write_plugin_status
    local INTERNAL_PLUGIN_DIR="$TEST_INTERNAL_DIR"
    eval "$(sed -n '/^write_plugin_status()/,/^}/p' "$PLUGINS_SCRIPT" | sed 's/log_message/echo/g')"

    # Test writing various statuses
    write_plugin_status "test-plugin" "Installing" > /dev/null 2>&1
    local status
    status=$(cat "$TEST_INTERNAL_DIR/test-plugin/status.txt")
    if [ "$status" != "Installing" ]; then
        log_fail "Expected 'Installing', got '$status'"
        return 1
    fi

    write_plugin_status "test-plugin" "Failed" > /dev/null 2>&1
    status=$(cat "$TEST_INTERNAL_DIR/test-plugin/status.txt")
    if [ "$status" != "Failed" ]; then
        log_fail "Expected 'Failed', got '$status'"
        return 1
    fi

    # Verify no trailing newline (echo -n)
    local size
    size=$(wc -c < "$TEST_INTERNAL_DIR/test-plugin/status.txt")
    if [ "$size" -ne 6 ]; then
        log_fail "Status file has unexpected size $size (expected 6 for 'Failed')"
        return 1
    fi

    log_pass "write_plugin_status works correctly"
}

# ============================================================
# Test: Duplicate entry prevention (item 4)
# ============================================================
test_duplicate_prevention() {
    ((++TESTS_TOTAL))
    log_test "Testing duplicate entry prevention in add_to_active_plugins..."

    # Check that add_to_active_plugins has duplicate check (grep for existing entry)
    local add_func
    add_func=$(sed -n '/^add_to_active_plugins()/,/^}/p' "$PLUGINS_SCRIPT")
    if ! echo "$add_func" | grep -q 'grep.*ACTIVE_PLUGINS_FILE'; then
        log_fail "add_to_active_plugins does not check for duplicates"
        return 1
    fi

    # Functional test using extracted function
    local ACTIVE_PLUGINS_FILE="$TEST_ACTIVE_FILE"
    echo "" > "$ACTIVE_PLUGINS_FILE"

    eval "$(sed -n '/^validate_plugin_name()/,/^}/p' "$PLUGINS_SCRIPT" | sed 's/log_message/echo/g')"
    eval "$(sed -n '/^add_to_active_plugins()/,/^}/p' "$PLUGINS_SCRIPT" | sed 's/log_message/echo/g')"

    # Add plugin twice
    add_to_active_plugins "test-plugin" > /dev/null 2>&1
    add_to_active_plugins "test-plugin" > /dev/null 2>&1

    local count
    count=$(grep -c "^test-plugin$" "$ACTIVE_PLUGINS_FILE" || echo 0)
    if [ "$count" -ne 1 ]; then
        log_fail "Plugin added $count times instead of 1"
        return 1
    fi

    log_pass "Duplicate entry prevention works correctly"
}

# ============================================================
# Test: Atomic file writes (item 4)
# ============================================================
test_atomic_file_writes() {
    ((++TESTS_TOTAL))
    log_test "Testing atomic file writes in add_to_active_plugins..."

    # Verify mktemp + mv pattern is used (atomic write)
    if ! grep -A 15 "^add_to_active_plugins()" "$PLUGINS_SCRIPT" | grep -q "mktemp"; then
        log_fail "add_to_active_plugins does not use mktemp for atomic writes"
        return 1
    fi

    if ! grep -A 15 "^add_to_active_plugins()" "$PLUGINS_SCRIPT" | grep -q "mv.*ACTIVE_PLUGINS_FILE"; then
        log_fail "add_to_active_plugins does not use mv for atomic replacement"
        return 1
    fi

    # Verify remove also uses atomic pattern
    if ! grep -A 10 "^remove_from_active_plugins()" "$PLUGINS_SCRIPT" | grep -q "mktemp"; then
        log_fail "remove_from_active_plugins does not use mktemp"
        return 1
    fi

    log_pass "Atomic file write patterns are in place"
}

# ============================================================
# Test: Per-plugin timeout configuration (item 12)
# ============================================================
test_timeout_configuration() {
    ((++TESTS_TOTAL))
    log_test "Testing per-plugin timeout configuration..."

    # Check get_plugin_timeout function exists
    if ! grep -q "get_plugin_timeout()" "$PLUGINS_SCRIPT"; then
        log_fail "get_plugin_timeout function not found"
        return 1
    fi

    # Check that process_plugin uses get_plugin_timeout instead of hardcoded value
    if grep -A 5 "^process_plugin()" "$PLUGINS_SCRIPT" | grep -q "local timeout=300"; then
        log_fail "process_plugin still uses hardcoded timeout=300"
        return 1
    fi

    if ! grep -A 20 "^process_plugin()" "$PLUGINS_SCRIPT" | grep -q "get_plugin_timeout"; then
        log_fail "process_plugin does not call get_plugin_timeout"
        return 1
    fi

    # Check update_plugin also uses it
    if ! grep -A 10 "^update_plugin()" "$PLUGINS_SCRIPT" | grep -q "get_plugin_timeout"; then
        log_fail "update_plugin does not call get_plugin_timeout"
        return 1
    fi

    log_pass "Per-plugin timeout configuration is implemented"
}

# ============================================================
# Test: Timeout values in info.json files
# ============================================================
test_info_json_timeout_values() {
    ((++TESTS_TOTAL))
    log_test "Testing installTimeout in plugin info.json files..."

    local loyal_info="../docker/fxsupport/linux/plugins/loyal-agent/info.json"
    local streamr_info="../docker/fxsupport/linux/plugins/streamr-node/info.json"

    if [ ! -f "$loyal_info" ]; then
        log_fail "loyal-agent info.json not found"
        return 1
    fi

    if ! grep -q '"installTimeout"' "$loyal_info"; then
        log_fail "installTimeout not found in loyal-agent info.json"
        return 1
    fi

    # loyal-agent should have high timeout (>= 3600) for model download
    local loyal_timeout
    loyal_timeout=$(python3 -c "import json; print(json.load(open('$loyal_info')).get('installTimeout', 0))" 2>/dev/null || echo 0)
    if [ "$loyal_timeout" -lt 3600 ]; then
        log_fail "loyal-agent installTimeout ($loyal_timeout) is too low for model download"
        return 1
    fi

    if [ -f "$streamr_info" ] && ! grep -q '"installTimeout"' "$streamr_info"; then
        log_fail "installTimeout not found in streamr-node info.json"
        return 1
    fi

    log_pass "Plugin timeout values are correctly configured"
}

# ============================================================
# Test: Failed status on all failure paths (item 2)
# ============================================================
test_failed_status_on_failures() {
    ((++TESTS_TOTAL))
    log_test "Testing Failed status is written on all failure paths..."

    # Count "Failed" writes in process_plugin
    local failed_count
    failed_count=$(sed -n '/^process_plugin()/,/^}/p' "$PLUGINS_SCRIPT" | grep -c '"Failed"' || echo 0)

    # We expect at least 5 Failed writes:
    # install: start.sh fail, install.sh fail, outer install fail, no install.sh
    # uninstall: uninstall.sh fail (inner), uninstall.sh fail (outer)
    if [ "$failed_count" -lt 5 ]; then
        log_fail "Only $failed_count 'Failed' status writes found in process_plugin (expected >= 5)"
        return 1
    fi

    log_pass "Failed status is written on all failure paths ($failed_count occurrences)"
}

# ============================================================
# Test: Uninstall failure does NOT re-add to active-plugins (item 9)
# ============================================================
test_uninstall_no_readd() {
    ((++TESTS_TOTAL))
    log_test "Testing uninstall failure does not re-add plugin to active-plugins..."

    # The uninstall section should NOT call add_to_active_plugins
    local uninstall_section
    uninstall_section=$(sed -n '/action.*==.*uninstall/,/^        fi$/p' "$PLUGINS_SCRIPT")

    if echo "$uninstall_section" | grep -q "add_to_active_plugins"; then
        log_fail "Uninstall failure path still calls add_to_active_plugins (oscillation bug)"
        return 1
    fi

    log_pass "Uninstall failure does not re-add plugin (no oscillation)"
}

# ============================================================
# Test: Uninstalling status (item 10)
# ============================================================
test_uninstalling_status() {
    ((++TESTS_TOTAL))
    log_test "Testing Uninstalling status is written before uninstall..."

    # Check that "Uninstalling" is written at the start of uninstall action
    if ! grep -B 2 -A 2 '"Uninstalling"' "$PLUGINS_SCRIPT" | grep -q "uninstall"; then
        log_fail "Uninstalling status not found in uninstall action"
        return 1
    fi

    log_pass "Uninstalling status is set before uninstall scripts run"
}

# ============================================================
# Test: cleanup_plugin_dir only on success (item 2)
# ============================================================
test_cleanup_only_on_success() {
    ((++TESTS_TOTAL))
    log_test "Testing cleanup_plugin_dir is only called on successful uninstall..."

    # Check that cleanup_plugin_dir function exists
    if ! grep -q "^cleanup_plugin_dir()" "$PLUGINS_SCRIPT"; then
        log_fail "cleanup_plugin_dir function not found"
        return 1
    fi

    # Check that remove_from_active_plugins does NOT contain rm -rf
    local remove_func
    remove_func=$(sed -n '/^remove_from_active_plugins()/,/^}/p' "$PLUGINS_SCRIPT")
    if echo "$remove_func" | grep -q "rm -rf"; then
        log_fail "remove_from_active_plugins still contains rm -rf (should use cleanup_plugin_dir)"
        return 1
    fi

    log_pass "Plugin directory cleanup is separated from active-plugins removal"
}

# ============================================================
# Test: Health check function (item 16)
# ============================================================
test_health_check() {
    ((++TESTS_TOTAL))
    log_test "Testing health check function exists and is called in main loop..."

    if ! grep -q "check_plugin_health()" "$PLUGINS_SCRIPT"; then
        log_fail "check_plugin_health function not found"
        return 1
    fi

    # Verify it's called in the main loop
    if ! grep -q "check_plugin_health" "$PLUGINS_SCRIPT" | grep -v "^check_plugin_health()"; then
        # More robust check
        local call_count
        call_count=$(grep -c "check_plugin_health" "$PLUGINS_SCRIPT" || echo 0)
        if [ "$call_count" -lt 2 ]; then
            log_fail "check_plugin_health is defined but never called in main loop"
            return 1
        fi
    fi

    # Verify health check counter exists
    if ! grep -q "HEALTH_CHECK_COUNTER" "$PLUGINS_SCRIPT"; then
        log_fail "HEALTH_CHECK_COUNTER not found (health check interval tracking)"
        return 1
    fi

    log_pass "Health check function is implemented and called periodically"
}

# ============================================================
# Test: Version tracking (item 23)
# ============================================================
test_version_tracking() {
    ((++TESTS_TOTAL))
    log_test "Testing version-aware update system..."

    # Check functions exist
    if ! grep -q "get_plugin_version()" "$PLUGINS_SCRIPT"; then
        log_fail "get_plugin_version function not found"
        return 1
    fi

    if ! grep -q "save_plugin_version()" "$PLUGINS_SCRIPT"; then
        log_fail "save_plugin_version function not found"
        return 1
    fi

    # Check that update_plugin compares versions
    local update_func
    update_func=$(sed -n '/^update_plugin()/,/^}/p' "$PLUGINS_SCRIPT")
    if ! echo "$update_func" | grep -q "version.txt"; then
        log_fail "update_plugin does not check version.txt"
        return 1
    fi

    if ! echo "$update_func" | grep -q "skipping update"; then
        log_fail "update_plugin does not skip same-version updates"
        return 1
    fi

    # Check that save_plugin_version is called after successful install
    if ! grep -q "save_plugin_version" "$PLUGINS_SCRIPT"; then
        log_fail "save_plugin_version is never called"
        return 1
    fi

    log_pass "Version-aware update system is implemented"
}

# ============================================================
# Test: Conditional docker copy (item 7)
# ============================================================
test_conditional_docker_copy() {
    ((++TESTS_TOTAL))
    log_test "Testing conditional docker copy (skip when dir populated)..."

    local copy_func
    copy_func=$(sed -n '/^copy_plugins_from_docker()/,/^}/p' "$PLUGINS_SCRIPT")

    if ! echo "$copy_func" | grep -q "already populated"; then
        log_fail "copy_plugins_from_docker does not check if dir is already populated"
        return 1
    fi

    if ! echo "$copy_func" | grep -q "ls -A"; then
        log_fail "copy_plugins_from_docker does not use ls -A to check dir contents"
        return 1
    fi

    log_pass "Docker copy is conditional (skips when dir already populated)"
}

# ============================================================
# Test: inotifywait availability check (item 15)
# ============================================================
test_inotifywait_check() {
    ((++TESTS_TOTAL))
    log_test "Testing inotifywait availability check..."

    if ! grep -q "command -v inotifywait" "$PLUGINS_SCRIPT"; then
        log_fail "No inotifywait availability check found"
        return 1
    fi

    if ! grep -q "inotify-tools" "$PLUGINS_SCRIPT"; then
        log_fail "No inotify-tools install hint found"
        return 1
    fi

    log_pass "inotifywait availability check is present"
}

# ============================================================
# Test: update_plugin uses cd for relative paths (item 18)
# ============================================================
test_update_cd() {
    ((++TESTS_TOTAL))
    log_test "Testing update_plugin changes to plugin directory..."

    local update_func
    update_func=$(sed -n '/^update_plugin()/,/^}/p' "$PLUGINS_SCRIPT")

    if ! echo "$update_func" | grep -q "cd.*plugin_dir"; then
        log_fail "update_plugin does not cd to plugin directory before running update.sh"
        return 1
    fi

    log_pass "update_plugin changes to plugin directory for relative paths"
}

# ============================================================
# Test: Loyal-agent start.sh exits non-zero on failure (item 3)
# ============================================================
test_loyal_agent_start_exit() {
    ((++TESTS_TOTAL))
    log_test "Testing loyal-agent start.sh exits non-zero when model missing..."

    local start_script="../docker/fxsupport/linux/plugins/loyal-agent/start.sh"
    if [ ! -f "$start_script" ]; then
        log_fail "loyal-agent start.sh not found"
        return 1
    fi

    if ! grep -A 2 "Download failed or incomplete" "$start_script" | grep -q "exit 1"; then
        log_fail "start.sh does not exit 1 when download is incomplete"
        return 1
    fi

    log_pass "loyal-agent start.sh exits non-zero on incomplete download"
}

# ============================================================
# Test: Streamr private key permissions (item 14)
# ============================================================
test_streamr_key_permissions() {
    ((++TESTS_TOTAL))
    log_test "Testing streamr-node private key file permissions..."

    local install_script="../docker/fxsupport/linux/plugins/streamr-node/install.sh"
    if [ ! -f "$install_script" ]; then
        log_fail "streamr-node install.sh not found"
        return 1
    fi

    if ! grep -q "chmod 600.*PRIVATE_KEY_FILE" "$install_script"; then
        log_fail "Private key file permissions not set to 600"
        return 1
    fi

    if ! grep -q "chmod 600.*CONFIG_FILE" "$install_script"; then
        log_fail "Config file permissions not set to 600"
        return 1
    fi

    log_pass "Streamr private key and config file permissions are restricted"
}

# ============================================================
# Test: Fix_freq shebang (item 13)
# ============================================================
test_fix_freq_shebang() {
    ((++TESTS_TOTAL))
    log_test "Testing fix_freq_rk3588.sh has correct shebang..."

    local script="../docker/fxsupport/linux/plugins/loyal-agent/custom/fix_freq_rk3588.sh"
    if [ ! -f "$script" ]; then
        log_fail "fix_freq_rk3588.sh not found"
        return 1
    fi

    local shebang
    shebang=$(head -1 "$script" | tr -d '\r')
    if [ "$shebang" = "#!/system/bin/sh" ]; then
        log_fail "fix_freq_rk3588.sh still has Android shebang: $shebang"
        return 1
    fi

    if [ "$shebang" != "#!/bin/bash" ]; then
        log_fail "fix_freq_rk3588.sh has unexpected shebang: $shebang"
        return 1
    fi

    log_pass "fix_freq_rk3588.sh has correct shebang"
}

# ============================================================
# Test: PC installer array handling (item 6)
# ============================================================
test_pc_installer_array_handling() {
    ((++TESTS_TOTAL))
    log_test "Testing PC installer handles info.json array correctly..."

    local pc_script="../pc-installer/src/main/plugin-manager.js"
    if [ ! -f "$pc_script" ]; then
        log_fail "plugin-manager.js not found"
        return 1
    fi

    # Should NOT use Object.entries on plugins array
    if grep -q "Object.entries(plugins)" "$pc_script"; then
        log_fail "plugin-manager.js still uses Object.entries() on array"
        return 1
    fi

    # Should filter using p.name
    if ! grep -q "\.filter(p => !PC_EXCLUDED_PLUGINS.includes(p.name))" "$pc_script"; then
        log_fail "plugin-manager.js does not filter by p.name"
        return 1
    fi

    log_pass "PC installer correctly handles info.json as array"
}

# ============================================================
# Test: PC installer runs install-pc.sh (item 19)
# ============================================================
test_pc_installer_setup_scripts() {
    ((++TESTS_TOTAL))
    log_test "Testing PC installer executes setup scripts..."

    local pc_script="../pc-installer/src/main/plugin-manager.js"
    if [ ! -f "$pc_script" ]; then
        log_fail "plugin-manager.js not found"
        return 1
    fi

    if ! grep -q "install-pc.sh" "$pc_script"; then
        log_fail "plugin-manager.js does not reference install-pc.sh"
        return 1
    fi

    log_pass "PC installer supports install-pc.sh execution"
}

# ============================================================
# Test: fula.sh remove() properly cleans up fula-plugins.service (item 8)
# ============================================================
test_fula_sh_plugins_cleanup() {
    ((++TESTS_TOTAL))
    log_test "Testing fula.sh remove() properly removes fula-plugins.service..."

    local fula_script="../docker/fxsupport/linux/fula.sh"
    if [ ! -f "$fula_script" ]; then
        log_fail "fula.sh not found"
        return 1
    fi

    # Check that the buggy bare "rm fula-plugins" is NOT present
    if grep -q "sudo rm fula-plugins$" "$fula_script"; then
        log_fail "fula.sh still has bare 'sudo rm fula-plugins' (missing path)"
        return 1
    fi

    # Check that proper cleanup exists
    if ! grep -q "rm.*SYSTEMD_PATH.*fula-plugins.service\|rm -f.*fula-plugins.service" "$fula_script"; then
        log_fail "fula.sh does not properly remove fula-plugins.service from SYSTEMD_PATH"
        return 1
    fi

    log_pass "fula.sh properly removes fula-plugins.service"
}

# ============================================================
# Test: Download model has integrity check (item 17)
# ============================================================
test_model_integrity_check() {
    ((++TESTS_TOTAL))
    log_test "Testing download_model.sh has integrity verification..."

    local dl_script="../docker/fxsupport/linux/plugins/loyal-agent/custom/download_model.sh"
    if [ ! -f "$dl_script" ]; then
        log_fail "download_model.sh not found"
        return 1
    fi

    if ! grep -q "sha256sum" "$dl_script"; then
        log_fail "download_model.sh does not verify SHA256"
        return 1
    fi

    if ! grep -q "INTEGRITY CHECK FAILED" "$dl_script"; then
        log_fail "download_model.sh does not report integrity failures"
        return 1
    fi

    log_pass "Model download integrity verification is implemented"
}

# ============================================================
# Test: Download model has progress reporting (item 11)
# ============================================================
test_download_progress_reporting() {
    ((++TESTS_TOTAL))
    log_test "Testing download_model.sh reports progress..."

    local dl_script="../docker/fxsupport/linux/plugins/loyal-agent/custom/download_model.sh"
    if [ ! -f "$dl_script" ]; then
        log_fail "download_model.sh not found"
        return 1
    fi

    if ! grep -q "Downloading.*%" "$dl_script"; then
        log_fail "download_model.sh does not report download percentage"
        return 1
    fi

    if ! grep -q "status.txt\|STATUS_FILE" "$dl_script"; then
        log_fail "download_model.sh does not write to status file"
        return 1
    fi

    log_pass "Download progress reporting is implemented"
}

# ============================================================
# Main test execution
# ============================================================
main() {
    echo "Plugin System Test Suite"
    echo "========================"
    echo "Testing plugin system production-readiness fixes"
    echo ""

    # Initialize test log
    echo "Test started at $(date)" > "$TEST_LOG"

    # Setup
    setup_test_env

    # Core plugins.sh tests
    test_plugin_name_validation
    test_path_traversal_prevention
    test_status_transitions
    test_write_plugin_status
    test_duplicate_prevention
    test_atomic_file_writes
    test_timeout_configuration
    test_info_json_timeout_values
    test_failed_status_on_failures
    test_uninstall_no_readd
    test_uninstalling_status
    test_cleanup_only_on_success
    test_health_check
    test_version_tracking
    test_conditional_docker_copy
    test_inotifywait_check
    test_update_cd

    # Plugin-specific tests
    test_loyal_agent_start_exit
    test_streamr_key_permissions
    test_fix_freq_shebang
    test_model_integrity_check
    test_download_progress_reporting

    # PC installer tests
    test_pc_installer_array_handling
    test_pc_installer_setup_scripts

    # Cross-file tests
    test_fula_sh_plugins_cleanup

    # Cleanup
    cleanup_test_env

    # Print results
    echo ""
    echo "Test Results"
    echo "============"
    echo "Total Tests: $TESTS_TOTAL"
    echo -e "Passed: ${GREEN}$TESTS_PASSED${NC}"
    echo -e "Failed: ${RED}$TESTS_FAILED${NC}"

    if [[ $TESTS_FAILED -eq 0 ]]; then
        echo -e "\n${GREEN}All plugin tests passed!${NC}"
        exit 0
    else
        echo -e "\n${RED}Some plugin tests failed. Check $TEST_LOG for details.${NC}"
        exit 1
    fi
}

# Run tests if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
