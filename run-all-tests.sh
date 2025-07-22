#!/bin/bash

# Master test runner for all validation tests

set -e

echo "🧪 Starting Fula-OTA Node Removal Validation Tests"
echo "=================================================="

# Make all test scripts executable
chmod +x test-*.sh

# Run all tests in sequence
echo ""
echo "📋 Test 1: Docker Compose Validation"
echo "------------------------------------"
./test-docker-setup.sh

echo ""
echo "📋 Test 2: Container Dependencies"
echo "--------------------------------"
./test-container-dependencies.sh

echo ""
echo "📋 Test 3: Configuration Validation"
echo "----------------------------------"
./test-config-validation.sh

echo ""
echo "📋 Test 4: Fula.sh Functions (Optional)"
echo "--------------------------------------"
if [ "$1" = "--include-functions" ]; then
    ./test-fula-functions.sh
else
    echo "Skipping function tests (use --include-functions to enable)"
fi

echo ""
echo "🎯 Test Summary"
echo "==============="
echo "✅ All validation tests completed"
echo ""
echo "📝 Next Steps:"
echo "1. Review any warnings (⚠️) from the tests above"
echo "2. Fix any issues (❌) before deploying"
echo "3. Consider running a staging deployment test"
echo ""
echo "🚀 Staging Test Command:"
echo "   docker-compose -f docker/fxsupport/linux/docker-compose.yml up --dry-run"
echo ""
echo "🔍 Manual Verification Steps:"
echo "1. Check that go-fula starts without blockchain endpoint errors"
echo "2. Verify IPFS cluster initializes with peer ID"
echo "3. Confirm no services are waiting for fula_node"
echo "4. Test that monitoring scripts don't fail"

echo ""
echo "=================================================="
echo "🧪 Fula-OTA Node Removal Validation Complete"
