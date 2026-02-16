#!/bin/sh

# This scripts runs before ipfs container
set -ex

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_files_and_folders() {
  if [ -d "/internal" ] && [ -d "/uniondrive" ] && [ -f "/internal/config.yaml" ] && [ -f "/internal/.ipfs_setup" ]; then
    return 0 # Explicitly return success
  else
    return 1 # Explicitly return failure
  fi
}

check_writable() {
  # Try to create a temporary file
  touch "/uniondrive/.tmp2_write_check"

  # Check if the file was created successfully
  if [ -f "/uniondrive/.tmp2_write_check" ]; then
    # Attempt to remove the file, ignoring whether removal is successful
    rm -f "/uniondrive/.tmp2_write_check" 2>/dev/null

    # Return success since the file was created (indicating the drive is writable)
    return 0
  else
    # Return failure if the file could not be created
    return 1
  fi
}

while ! check_files_and_folders || ! check_writable; do
  log "Waiting for /internal and /uniondrive to become available and writable..."
  sleep 5
done

log "Both /internal and /uniondrive are available and writable."
mkdir -p /internal/ipfs_data/

# Remove stale lock files from a previous crashed kubo instance.
# These are advisory locks that will be recreated on startup.
# Note: this script runs as the ipfs user (kubo's entrypoint does
# exec gosu ipfs before running container-init.d scripts). rm works
# here because the parent directories are world-writable (chmod 777).
# Ownership fixes are handled by fula.sh on the host (runs as root).
rm -f /uniondrive/ipfs_datastore/datastore/LOCK 2>/dev/null || true
rm -f /internal/ipfs_data/repo.lock 2>/dev/null || true

log "Initialization complete."
