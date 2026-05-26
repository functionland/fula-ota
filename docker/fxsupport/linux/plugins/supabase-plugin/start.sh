#!/bin/bash

set -e

SUPABASE_DIR="/opt/supabase"

echo "Starting Supabase..."

cd $SUPABASE_DIR

# Start services
docker compose up -d

# Wait for services to be ready
echo "Waiting for services to start..."
sleep 10

# Check if services are running
if docker compose ps | grep -q "Up"; then
    echo "==========================================="
    echo "Supabase started successfully!"
    echo "Run './status.sh' to view connection details"
    echo "==========================================="
else
    echo "Error: Some services failed to start"
    docker compose ps
    exit 1
fi