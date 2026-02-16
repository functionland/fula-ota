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

# Fix ownership of kubo's data directories.
# This init script runs as root, but kubo switches to the ipfs user after init
# completes. Files created by root (fula.sh mkdir, migration scripts) or left
# from a previous run may be inaccessible to ipfs. Without this, kubo fails
# with: "failed to open pebble database: LOCK: permission denied"
#
# Remove stale pebble LOCK file first — it's an advisory lock from a dead
# process and will be recreated by kubo on startup.
rm -f /uniondrive/ipfs_datastore/datastore/LOCK 2>/dev/null || true
# Use the ipfs username (not hardcoded UID) so this works across kubo versions.
# "ipfs:" = change user to ipfs, group to ipfs's default login group.
log "Fixing datastore ownership for ipfs user..."
if [ -d "/uniondrive/ipfs_datastore" ]; then
  chown -R ipfs: /uniondrive/ipfs_datastore
fi
if [ -d "/internal/ipfs_data" ]; then
  chown -R ipfs: /internal/ipfs_data
fi

log "Initialization complete."
