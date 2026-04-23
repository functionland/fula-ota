#!/bin/bash

set -e

SUPABASE_DIR="/opt/supabase"

echo "Restarting Supabase..."

cd $SUPABASE_DIR

# Stop and remove the containers
docker compose down

# Recreate and start the containers
docker compose up -d

echo "Waiting for services to restart..."
sleep 10

if docker compose ps | grep -q "Up"; then
    echo "Supabase restarted successfully!"
else
    echo "Error: Some services failed to restart"
    docker compose ps
    exit 1
fi