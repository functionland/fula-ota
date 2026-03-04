#!/bin/bash
# Detect when Watchtower has pulled a newer image that a running
# container hasn't picked up yet.

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
