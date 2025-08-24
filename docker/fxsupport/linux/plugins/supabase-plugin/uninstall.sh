#!/bin/bash

set -e

SUPABASE_DIR="/opt/supabase"

echo "==========================================="
echo "Uninstalling Supabase Plugin..."
echo "WARNING: This will remove all data!"
echo "Press Ctrl+C to cancel, or wait 5 seconds to continue..."
echo "==========================================="

sleep 5

cd $SUPABASE_DIR

# Stop docker and remove volumes
docker compose down -v

# Remove Postgres data
rm -rf volumes/db/data/

# Remove all Supabase files
cd /
rm -rf $SUPABASE_DIR

echo "Supabase Plugin uninstalled successfully!"