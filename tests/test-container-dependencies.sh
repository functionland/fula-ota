#!/bin/bash

# Test container dependencies and startup order

set -e

echo "=== Container Dependency Tests ==="

# Test 1: Check if removing node service breaks dependencies
echo "1. Testing container dependencies after node removal..."

cd ../docker/fxsupport/linux

# Parse docker-compose to check dependencies
echo "2. Analyzing service dependencies..."
SERVICES=$(docker-compose config --services)
echo "Available services: $SERVICES"

for service in $SERVICES; do
    echo "Checking dependencies for $service:"
    DEPS=$(docker-compose config | grep -A 20 "^  $service:" | grep "depends_on:" -A 10 | grep "- " | sed 's/.*- //' || echo "none")
    if [ "$DEPS" != "none" ]; then
        echo "  Dependencies: $DEPS"
        # Check if any dependency references the removed node
        if echo "$DEPS" | grep -q "node\|fula_node"; then
            echo "  ❌ ISSUE: $service still depends on removed node service"
        else
            echo "  ✅ Dependencies are clean"
        fi
    else
        echo "  ✅ No dependencies"
    fi
done

# Test 3: Check for orphaned volume references
echo "3. Checking for orphaned volume references..."
VOLUMES=$(docker-compose config | grep -E "^\s*-\s*/.*:" | sed 's/.*- //' | cut -d: -f1)
for vol in $VOLUMES; do
    if [[ "$vol" == *"node"* ]] || [[ "$vol" == *"sugarfunge"* ]]; then
        echo "⚠️  Potential orphaned volume reference: $vol"
    fi
done

# Test 4: Port conflict analysis
echo "4. Analyzing port usage after node removal..."
PORTS=$(docker-compose config | grep -E "ports:" -A 10 | grep -E "^\s*-\s*\".*:[0-9]+\"" | sed 's/.*"\(.*\)"/\1/')
echo "Ports that will be used:"
echo "$PORTS"

# Check if any critical ports (4000, 9945, 30335) are still referenced
if echo "$PORTS" | grep -E "(4000|9945|30335)"; then
    echo "⚠️  Node-specific ports still referenced"
else
    echo "✅ Node-specific ports successfully removed"
fi

echo "=== Container Dependency Tests Complete ==="
