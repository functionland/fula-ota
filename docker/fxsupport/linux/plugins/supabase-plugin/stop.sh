#!/bin/bash

set -e

SUPABASE_DIR="/opt/supabase"

echo "Stopping Supabase..."

cd $SUPABASE_DIR

# Stop services
docker compose down

echo "Supabase stopped successfully!"