#!/bin/bash
# Check if Watchtower has pulled newer images since last docker cp
source /usr/bin/fula/.env 2>/dev/null || true
last_cp=$(stat -c %Y /home/pi/stop_docker_copy.txt 2>/dev/null || echo 0)
for img in "$FX_SUPPROT" "$GO_FULA"; do
    [ -z "$img" ] && continue
    created=$(docker inspect --format='{{.Created}}' "$img" 2>/dev/null) || continue
    img_epoch=$(date -d "$created" +%s 2>/dev/null || echo 0)
    if [ "$img_epoch" -gt "$last_cp" ]; then
        logger -t fula-ota-update "Image $img is newer than last docker cp, restarting fula.service"
        systemctl restart fula.service
        exit 0
    fi
done
