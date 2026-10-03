#!/usr/bin/env bash
#
# samba-pkgs.sh — install Samba-related packages in the background.
#
# Started by fula.sh (setup_storage_access -> dispatch_samba_pkgs) as the
# transient unit `fula-samba-pkgs`, so `fula.sh start` never waits on apt.
# The download step is time-bounded; dpkg itself is never killed mid-write.
# Usage: samba-pkgs.sh <package>...

set -u
export DEBIAN_FRONTEND=noninteractive

[ "$#" -gt 0 ] || exit 0

APT_OPTS=(-y --no-install-recommends
          -o DPkg::Lock::Timeout=120
          -o Dpkg::Options::=--force-confold)

log() {
    logger -t fula-samba-pkgs "$*" 2>/dev/null || true
    echo "$*"
}

if ! timeout 300 apt-get "${APT_OPTS[@]}" install --download-only "$@"; then
    log "download failed, refreshing package lists"
    if ! timeout 180 apt-get -o DPkg::Lock::Timeout=120 update; then
        log "apt-get update failed"
        exit 1
    fi
    if ! timeout 300 apt-get "${APT_OPTS[@]}" install --download-only "$@"; then
        log "download failed: $*"
        exit 1
    fi
fi

if ! apt-get "${APT_OPTS[@]}" install "$@"; then
    log "install failed: $*"
    exit 1
fi

# setup_storage_access starts smbd/nmbd itself once samba is configured; the
# WS-Discovery responder has no config, so start it here as soon as it is
# installed (wsdd-server.service on Ubuntu noble, wsdd.service on older Debian).
for unit in wsdd-server wsdd; do
    if systemctl cat "$unit" >/dev/null 2>&1; then
        systemctl enable --now "$unit" >/dev/null 2>&1 || log "could not start $unit"
        break
    fi
done

log "installed: $*"
exit 0
