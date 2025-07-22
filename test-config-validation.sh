#!/bin/bash

# Validate configuration files for node removal impact

set -e

echo "=== Configuration Validation Tests ==="

# Test 1: Check for remaining node references in scripts
echo "1. Scanning for remaining node references..."

SEARCH_DIRS="docker/fxsupport/linux docker/go-fula docker/ipfs-cluster"
NODE_REFS=$(find $SEARCH_DIRS -type f \( -name "*.sh" -o -name "*.py" -o -name "*.yml" -o -name "*.yaml" \) -exec grep -l "fula_node\|sugarfunge.*node\|node\.functionyard\|api\.node3\.functionyard" {} \; 2>/dev/null || true)

if [ -n "$NODE_REFS" ]; then
    echo "⚠️  Files still containing node references:"
    for file in $NODE_REFS; do
        echo "  - $file"
        echo "    References:"
        grep -n "fula_node\|sugarfunge.*node\|node\.functionyard\|api\.node3\.functionyard" "$file" | head -3
        echo ""
    done
else
    echo "✅ No node references found in configuration files"
fi

# Test 2: Check environment files
echo "2. Checking environment files..."
ENV_FILES="docker/env_release.sh docker/env_release_amd64.sh docker/env_test.sh"
for env_file in $ENV_FILES; do
    if [ -f "$env_file" ]; then
        echo "Checking $env_file:"
        if grep -q "SUGARFUNGE_NODE\|NODE.*IMAGE" "$env_file"; then
            echo "  ⚠️  Still contains node image references"
            grep -n "SUGARFUNGE_NODE\|NODE.*IMAGE" "$env_file"
        else
            echo "  ✅ Clean of node references"
        fi
    fi
done

# Test 3: Check for hardcoded endpoints
echo "3. Checking for hardcoded blockchain endpoints..."
ENDPOINT_REFS=$(find $SEARCH_DIRS -type f -exec grep -l "api\.node3\.functionyard\|node\.functionyard" {} \; 2>/dev/null || true)

if [ -n "$ENDPOINT_REFS" ]; then
    echo "⚠️  Files still containing blockchain endpoint references:"
    for file in $ENDPOINT_REFS; do
        echo "  - $file"
        grep -n "api\.node3\.functionyard\|node\.functionyard" "$file"
    done
else
    echo "✅ No hardcoded blockchain endpoints found"
fi

# Test 4: Validate IPFS cluster configuration
echo "4. Validating IPFS cluster configuration..."
CLUSTER_SCRIPT="docker/fxsupport/linux/ipfs-cluster/ipfs-cluster-container-init.d.sh"
if [ -f "$CLUSTER_SCRIPT" ]; then
    echo "Checking CLUSTER_PEERNAME configuration:"
    if grep -q "get_ipfs_peer_id" "$CLUSTER_SCRIPT"; then
        echo "  ✅ Using IPFS peer ID function"
    else
        echo "  ⚠️  CLUSTER_PEERNAME configuration may need review"
    fi
    
    if grep -q "/internal/.secrets/account.txt" "$CLUSTER_SCRIPT"; then
        echo "  ❌ Still references node account file"
    else
        echo "  ✅ No longer depends on node account file"
    fi
fi

echo "=== Configuration Validation Complete ==="
