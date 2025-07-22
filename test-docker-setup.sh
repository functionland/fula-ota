#!/bin/bash

# Test script for validating docker setup without running containers

set -e

echo "=== Docker Compose Validation Tests ==="

# Test 1: Validate docker-compose syntax
echo "1. Testing docker-compose syntax..."
cd docker/fxsupport/linux
if docker-compose -f docker-compose.yml config --quiet; then
    echo "✅ Docker compose syntax is valid"
else
    echo "❌ Docker compose syntax error"
    exit 1
fi

# Test 2: Check for missing environment variables
echo "2. Checking environment variables..."
if docker-compose -f docker-compose.yml config > /dev/null 2>&1; then
    echo "✅ All required environment variables are available"
else
    echo "❌ Missing environment variables detected"
    docker-compose -f docker-compose.yml config
fi

# Test 3: List services that would be created
echo "3. Services that would be created:"
docker-compose -f docker-compose.yml config --services

# Test 4: Check for port conflicts
echo "4. Checking for potential port conflicts..."
PORTS=$(docker-compose -f docker-compose.yml config | grep -E "^\s*-\s*\".*:[0-9]+\"" | sed 's/.*"\(.*\)"/\1/' | cut -d: -f2)
for port in $PORTS; do
    if netstat -tuln | grep -q ":$port "; then
        echo "⚠️  Port $port is already in use"
    else
        echo "✅ Port $port is available"
    fi
done

# Test 5: Validate image references
echo "5. Checking if docker images exist..."
IMAGES=$(docker-compose -f docker-compose.yml config | grep "image:" | awk '{print $2}')
for image in $IMAGES; do
    if docker image inspect "$image" > /dev/null 2>&1; then
        echo "✅ Image $image exists locally"
    else
        echo "⚠️  Image $image not found locally (will be pulled)"
    fi
done

echo "=== Docker Compose Validation Complete ==="
