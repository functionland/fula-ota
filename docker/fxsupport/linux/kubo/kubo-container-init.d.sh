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
  if touch "/uniondrive/.tmp2_write_check" && rm "/uniondrive/.tmp2_write_check"; then
    return 0 # Success
  else
    return 1 # Failure
  fi
}

while ! check_files_and_folders || ! check_writable; do
  log "Waiting for /internal and /uniondrive to become available and writable..."
  sleep 5
done

log "Both /internal and /uniondrive are available and writable."
mkdir -p /internal/ipfs_data/
mkdir -p /uniondrive/ipfs_data/
mkdir -p /uniondrive/ipfs_staging

log "Initialization complete."
