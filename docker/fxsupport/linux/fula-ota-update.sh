#!/bin/bash
# Detect when Watchtower has pulled a newer image but host scripts in
# /usr/bin/fula/ haven't been re-synced via fula.sh start's docker cp.
#
# Two paths to detect:
#   Path 1 (image-mismatch): Watchtower pulled the new image but hasn't
#     restarted the container yet. running_id != current_id.
#   Path 2 (host-file-stale): Watchtower pulled AND restarted, container
#     is on the new image, but host /usr/bin/fula/ scripts are still old
#     because fula.sh start (which docker cp's /linux/. to /usr/bin/fula/)
#     never re-ran. Detected by hashing canary files in the container vs
#     on the host.
#
# Why hash-based and not timestamp-based: container Created timestamps
# are always more recent than fula.service ActiveEnterTimestamp (because
# fula.sh start -> docker-compose up creates them WITHIN ExecStart). A
# timestamp comparison would fire on every clean startup and loop until
# StartLimitBurst trips. Hash comparison is self-converging: once
# docker cp completes, container_hash == host_hash and the next firing
# is a no-op.

# Three guards, all must pass before any restart action.
#
# Guard 1: fula.service must be in 'active' state. Catches systemd-level
# transitions (failed, activating, deactivating).
fula_state=$(systemctl show fula.service --property=ActiveState --value 2>/dev/null)
if [ "$fula_state" != "active" ]; then
    logger -t fula-ota-update "fula.service is ${fula_state:-unknown}, skipping update check"
    exit 0
fi

# Guard 2: fula.sh must not be currently executing. Necessary because
# fula.service has Type=simple + RemainAfterExit=true, so systemd marks
# it 'active' the moment ExecStart begins — even while fula.sh start
# (docker-compose up, container-settle wait, docker cp) is still running
# for ~60-120s. Without this guard a timer firing during that window
# could collide with fula.sh start and force a redundant restart.
# Matches "bash /usr/bin/fula/fula.sh start" (and any other fula.sh
# invocation, e.g. install/update paths that call back into it).
if pgrep -f "/usr/bin/fula/fula\.sh" >/dev/null 2>&1; then
    logger -t fula-ota-update "fula.sh is currently executing, skipping update check"
    exit 0
fi

# Guard 3: all managed containers must be in 'running' state. If any is
# restarting / exited / created, the fula stack is mid-transition (either
# fula.sh start in progress, Watchtower mid-restart, or a container crash
# loop). Wait until everything is stable. The [ -n "$status" ] check means
# containers that DON'T EXIST (e.g. ipfs_local disabled in compose) do
# NOT cause a skip — only existing containers with non-running status do.
for c in fula_fxsupport fula_go fula_gateway fula_pinning ipfs_host ipfs_local ipfs_cluster; do
    status=$(docker inspect --format='{{.State.Status}}' "$c" 2>/dev/null)
    if [ -n "$status" ] && [ "$status" != "running" ]; then
        logger -t fula-ota-update "Container $c is $status, skipping update check (fula stack not stable)"
        exit 0
    fi
done

# Path 1: Watchtower downloaded but hasn't restarted the container yet.
for container in fula_fxsupport fula_go fula_gateway fula_pinning; do
    # Image ID the running container was created from
    running_id=$(docker inspect --format='{{.Image}}' "$container" 2>/dev/null) || continue
    # Image reference (tag) the container uses
    img_ref=$(docker inspect --format='{{.Config.Image}}' "$container" 2>/dev/null) || continue
    # Current image ID for that tag (Watchtower may have updated it)
    current_id=$(docker inspect --format='{{.Id}}' "$img_ref" 2>/dev/null) || continue

    if [ "$running_id" != "$current_id" ]; then
        logger -t fula-ota-update "Container $container uses stale image (tag $img_ref updated), restarting fula.service"
        systemctl restart fula.service
        exit 0
    fi
done

# Path 2: Container is on the current image but host scripts are stale.
# Hash canary files in fula_fxsupport's /linux/ vs host's /usr/bin/fula/.
# Multiple canaries because any given release might change one but not
# another; if ANY diverges, host is stale and needs a docker cp. After
# fula.sh start completes the docker cp, all hashes converge and the
# next firing is a no-op.
canary_files=(readiness-check.py fula.sh commands.sh)
if docker inspect fula_fxsupport >/dev/null 2>&1; then
    for f in "${canary_files[@]}"; do
        container_hash=$(docker exec fula_fxsupport sha256sum "/linux/${f}" 2>/dev/null | awk '{print $1}')
        host_hash=$(sha256sum "/usr/bin/fula/${f}" 2>/dev/null | awk '{print $1}')
        if [ -n "$container_hash" ] && [ -n "$host_hash" ] && [ "$container_hash" != "$host_hash" ]; then
            logger -t fula-ota-update "Host ${f} differs from container, restarting fula.service to sync"
            systemctl restart fula.service
            exit 0
        fi
    done
fi
