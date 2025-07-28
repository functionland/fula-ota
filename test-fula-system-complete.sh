#!/bin/bash

# Master Test Runner for Complete Fula System
# Runs all unit tests for fula.sh, Docker services, and uniondrive/readiness

set -e

# Test configuration
MASTER_LOG="/tmp/fula-system-complete-test.log"
TEST_RESULTS_DIR="/tmp/fula-test-results"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Test suite files (in tests folder)
TEST_SUITES=(
    "tests/test-config-validation.sh"
    "tests/test-docker-setup.sh"
    "tests/test-container-dependencies.sh"
    "tests/test-fula-sh-functions.sh"
    "tests/test-docker-services.sh"
    "tests/test-uniondrive-readiness.sh"
    "tests/test-go-fula-system-integration.sh"
)

# Test suite descriptions
declare -A TEST_DESCRIPTIONS=(
    ["tests/test-config-validation.sh"]="Configuration Validation (Node Removal Impact)"
    ["tests/test-docker-setup.sh"]="Docker Compose Setup Validation"
    ["tests/test-container-dependencies.sh"]="Container Dependencies Analysis"
    ["tests/test-fula-sh-functions.sh"]="Fula.sh Functions (install, update, run)"
    ["tests/test-docker-services.sh"]="Docker Services (go-fula, kubo, ipfs-cluster, watchtower)"
    ["tests/test-uniondrive-readiness.sh"]="Uniondrive & Readiness Check (Armbian/Rockchip3588)"
    ["tests/test-go-fula-system-integration.sh"]="go-fula System Integration (WiFi, Hotspot, Storage)"
)

# Results tracking
TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0

# Logging functions
log_header() {
    echo -e "${CYAN}$1${NC}"
    echo "$1" >> "$MASTER_LOG"
}

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
    echo "[INFO] $1" >> "$MASTER_LOG"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
    echo "[SUCCESS] $1" >> "$MASTER_LOG"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
    echo "[ERROR] $1" >> "$MASTER_LOG"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
    echo "[WARNING] $1" >> "$MASTER_LOG"
}

# Setup test environment
setup_test_environment() {
    log_info "Setting up test environment..."
    
    # Create results directory
    mkdir -p "$TEST_RESULTS_DIR"
    
    # Initialize master log
    echo "Fula System Complete Test Suite" > "$MASTER_LOG"
    echo "Started at: $(date)" >> "$MASTER_LOG"
    echo "System: $(uname -a)" >> "$MASTER_LOG"
    echo "======================================" >> "$MASTER_LOG"
    
    # Make test scripts executable
    for suite in "${TEST_SUITES[@]}"; do
        if [[ -f "$suite" ]]; then
            chmod +x "$suite"
            log_info "Made $suite executable"
        else
            log_warning "Test suite $suite not found"
        fi
    done
    
    log_success "Test environment setup complete"
}

# Run individual test suite
run_test_suite() {
    local suite="$1"
    local description="${TEST_DESCRIPTIONS[$suite]}"
    
    ((TOTAL_SUITES++))
    
    log_header "Running Test Suite: $description"
    log_info "Executing: $suite"
    
    if [[ ! -f "$suite" ]]; then
        log_error "Test suite file not found: $suite"
        ((FAILED_SUITES++))
        return 1
    fi
    
    # Run the test suite and capture output
    local suite_log="$TEST_RESULTS_DIR/${suite%.sh}.log"
    local exit_code=0
    
    if ./"$suite" > "$suite_log" 2>&1; then
        log_success "✅ $description - PASSED"
        ((PASSED_SUITES++))
        
        # Extract summary from test output
        if grep -q "Test Results" "$suite_log"; then
            echo "  Summary:" | tee -a "$MASTER_LOG"
            grep -A 3 "Test Results" "$suite_log" | sed 's/^/    /' | tee -a "$MASTER_LOG"
        fi
    else
        exit_code=$?
        log_error "❌ $description - FAILED (exit code: $exit_code)"
        ((FAILED_SUITES++))
        
        # Show last few lines of failed test
        echo "  Last 10 lines of output:" | tee -a "$MASTER_LOG"
        tail -n 10 "$suite_log" | sed 's/^/    /' | tee -a "$MASTER_LOG"
    fi
    
    echo "" | tee -a "$MASTER_LOG"
    return $exit_code
}

# Check system prerequisites
check_prerequisites() {
    log_info "Checking system prerequisites..."
    
    local missing_tools=()
    
    # Check for required tools
    local required_tools=("bash" "docker" "python3")
    
    for tool in "${required_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_tools+=("$tool")
        fi
    done
    
    # Check for optional tools
    local optional_tools=("docker-compose" "systemctl" "nmcli")
    local missing_optional=()
    
    for tool in "${optional_tools[@]}"; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            missing_optional+=("$tool")
        fi
    done
    
    if [[ ${#missing_tools[@]} -gt 0 ]]; then
        log_error "Missing required tools: ${missing_tools[*]}"
        log_error "Please install missing tools before running tests"
        return 1
    fi
    
    if [[ ${#missing_optional[@]} -gt 0 ]]; then
        log_warning "Missing optional tools: ${missing_optional[*]}"
        log_warning "Some tests may be skipped or show warnings"
    fi
    
    log_success "Prerequisites check completed"
    return 0
}

# Generate test report
generate_report() {
    local report_file="$TEST_RESULTS_DIR/fula-system-test-report.txt"
    
    log_info "Generating comprehensive test report..."
    
    cat > "$report_file" << EOF
=====================================
FULA SYSTEM COMPLETE TEST REPORT
=====================================

Test Execution Details:
- Date: $(date)
- System: $(uname -a)
- User: $(whoami)
- Working Directory: $(pwd)

Test Suite Results:
- Total Suites: $TOTAL_SUITES
- Passed: $PASSED_SUITES
- Failed: $FAILED_SUITES
- Success Rate: $(( PASSED_SUITES * 100 / TOTAL_SUITES ))%

Individual Test Suite Details:
EOF

    # Add individual test results
    for suite in "${TEST_SUITES[@]}"; do
        local suite_log="$TEST_RESULTS_DIR/${suite%.sh}.log"
        local description="${TEST_DESCRIPTIONS[$suite]}"
        
        echo "" >> "$report_file"
        echo "Test Suite: $description" >> "$report_file"
        echo "File: $suite" >> "$report_file"
        
        if [[ -f "$suite_log" ]]; then
            echo "Status: $(grep -q "All.*tests passed" "$suite_log" && echo "PASSED" || echo "FAILED")" >> "$report_file"
            
            # Extract test statistics if available
            if grep -q "Total Tests:" "$suite_log"; then
                grep "Total Tests:\|Passed:\|Failed:" "$suite_log" | sed 's/^/  /' >> "$report_file"
            fi
        else
            echo "Status: NOT RUN" >> "$report_file"
        fi
    done
    
    # Add system information
    cat >> "$report_file" << EOF

System Information:
- Docker Version: $(docker --version 2>/dev/null || echo "Not available")
- Python Version: $(python3 --version 2>/dev/null || echo "Not available")
- Available Memory: $(free -h 2>/dev/null | grep Mem || echo "Not available")
- Disk Space: $(df -h . 2>/dev/null | tail -1 || echo "Not available")

Test Logs Location: $TEST_RESULTS_DIR
Master Log: $MASTER_LOG

EOF
    
    log_success "Test report generated: $report_file"
    echo "📋 Full test report available at: $report_file"
}

# Cleanup function
cleanup() {
    log_info "Cleaning up temporary test files..."
    # Note: We keep the results directory for review
    log_info "Test results preserved in: $TEST_RESULTS_DIR"
}

# Main execution
main() {
    echo "🚀 Fula System Complete Test Suite"
    echo "=================================="
    echo "Testing all components for Armbian/Rockchip3588 deployment"
    echo ""
    echo "Test suites to run:"
    for suite in "${TEST_SUITES[@]}"; do
        echo "  - ${TEST_DESCRIPTIONS[$suite]}"
    done
    echo ""
    
    # Setup
    setup_test_environment
    
    # Check prerequisites
    if ! check_prerequisites; then
        log_error "Prerequisites check failed. Aborting tests."
        exit 1
    fi
    
    echo ""
    log_header "Starting Test Execution"
    
    # Run all test suites
    for suite in "${TEST_SUITES[@]}"; do
        run_test_suite "$suite"
    done
    
    # Generate final report
    echo ""
    log_header "Test Execution Complete"
    
    echo "📊 Final Results:"
    echo "================="
    echo "Total Test Suites: $TOTAL_SUITES"
    echo -e "Passed: ${GREEN}$PASSED_SUITES${NC}"
    echo -e "Failed: ${RED}$FAILED_SUITES${NC}"
    
    if [[ $FAILED_SUITES -eq 0 ]]; then
        echo -e "\n${GREEN}🎉 ALL TEST SUITES PASSED!${NC}"
        echo "The Fula system is ready for deployment on Armbian/Rockchip3588"
    else
        echo -e "\n${RED}⚠️  SOME TEST SUITES FAILED${NC}"
        echo "Please review the test logs and fix issues before deployment"
    fi
    
    # Generate comprehensive report
    generate_report
    
    # Cleanup
    cleanup
    
    # Exit with appropriate code
    exit $FAILED_SUITES
}

# Handle script interruption
trap cleanup EXIT

# Run main function if script is executed directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
