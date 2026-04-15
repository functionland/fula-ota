#!/bin/sh

### With monitor instead of creating dummy drives

# Set the NOTIFY_SOCKET environment variable
export NOTIFY_SOCKET=/run/systemd/notify

MOUNT_USB_PATH=/media/pi
MOUNT_LINKS=/home/pi/drives
MOUNT_PATH=/uniondrive
SETUP_DONE_FILE="$MOUNT_PATH/setup.done"
FULA_PATH=/usr/bin/fula
COMMANDS_DIR="/home/pi/commands"

mkdir -p $MOUNT_PATH
mkdir -p $MOUNT_LINKS

rm -f "$MOUNT_LINKS"/disk-*
sync

log()
{
  echo "$1"
}

systemd-notify WATCHDOG=1
remove_unionready() {
    systemd-notify WATCHDOG=1
    if [ -d "$MOUNT_PATH" ] && [ -f "$SETUP_DONE_FILE" ]; then
        echo "Removing $SETUP_DONE_FILE..."
        rm -f "$SETUP_DONE_FILE" || true
    else
        echo "Either $MOUNT_PATH does not exist or $SETUP_DONE_FILE does not exist."
    fi
}
remove_unionready

umount_drives() {
    systemd-notify WATCHDOG=1
    # Remove Docker's shared-volume-external volume and its bind mount.
    # Docker's local volume driver (device: /uniondrive, o: bind) creates a
    # bind mount that, through shared mount propagation from the root mount,
    # stacks an ext4 mount from the root partition back on top of mergerfs.
    # Just unmounting the data path is not enough — the Docker daemon
    # independently recreates it.  Removing the volume forces docker-compose
    # to recreate it later (from the correct mergerfs mount).
    docker stop ipfs_host ipfs_local ipfs_cluster fula_go 2>/dev/null || true
    umount /var/lib/docker/volumes/fula_shared-volume-external/_data 2>/dev/null || true
    docker volume rm fula_shared-volume-external 2>/dev/null || true

  # Set a maximum number of attempts to prevent an infinite loop
    MAX_ATTEMPTS=10
    ATTEMPT=0

    while umount "$MOUNT_PATH" 2>/dev/null; do
        systemd-notify WATCHDOG=1
        log "Successfully unmounted $MOUNT_PATH. Attempting again to ensure complete unmount."
        if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
            umount -f "$MOUNT_PATH" || true
            break
        fi
        systemd-notify WATCHDOG=1
        ATTEMPT=$((ATTEMPT + 1))
        sleep 5
    done

    if mountpoint -q "$MOUNT_PATH"; then
        systemd-notify WATCHDOG=1
        echo "Failed to unmount $MOUNT_PATH after $MAX_ATTEMPTS attempts"
        # Optionally, you can add more aggressive unmounting methods here
        # For example: umount -f "$MOUNT_PATH" or umount -l "$MOUNT_PATH"
    else
        systemd-notify WATCHDOG=1
        echo "$MOUNT_PATH is not mounted"
        if [ -d "$MOUNT_PATH" ]; then
            sudo rm -rf "$MOUNT_PATH"/*
        fi
    fi
}

remove_unionready
umount_drives
systemd-notify WATCHDOG=1

cleanup_on_exit() {
    echo "Cleaning up before exit..."
    umount_drives
    rm -rf "${MOUNT_LINKS:?}"/*
    echo "Cleanup complete. Exiting."
    remove_unionready
}

trap cleanup_on_exit EXIT

remove_exit_trap() {
    trap - EXIT
}

check_mounted_drives() {
    systemd-notify WATCHDOG=1
    mounted_count=0
    for drive in /media/pi/*; do
        systemd-notify WATCHDOG=1
        if mountpoint -q "$drive"; then
            mounted_count=$((mounted_count + 1))
            echo "Detected mounted drive: $drive" >&2
        fi
    done
    echo $mounted_count
}

detect_type() {
    local_mount_point="$1"
    if [ -z "$local_mount_point" ] || [ ! -d "$local_mount_point" ]; then
        echo ""
        return 1
    fi
    fs_type=$(df -PT "$local_mount_point" 2>/dev/null | grep "$local_mount_point" | awk '{print $2}')
    if [ -z "$fs_type" ]; then
        echo ""
        return 1
    fi
    echo "$fs_type"
}

unionfs_fuse_mount_drives() {
    systemd-notify WATCHDOG=1
    MOUNT_ARG=""
    FIRST=""

    for drive in /media/pi/*; do
        systemd-notify WATCHDOG=1
        if mountpoint -q "$drive"; then
            # Check if the filesystem type is ext4
            fs_type=$(detect_type "$drive")
            if [ "$fs_type" = "ext4" ]; then
                # Check that the block device still exists (not a stale mount)
                blk_dev=$(findmnt -n -o SOURCE "$drive" 2>/dev/null)
                if [ -n "$blk_dev" ] && [ ! -b "$blk_dev" ]; then
                    echo "WARNING: Skipping $drive — block device $blk_dev no longer exists (stale mount). Lazy-unmounting."
                    umount -l "$drive" 2>/dev/null || true
                # Check for I/O errors before including drive
                elif ! ls "$drive" > /dev/null 2>&1; then
                    echo "WARNING: Skipping $drive due to I/O errors (drive may be failing)"
                else
                    MOUNT_ARG="${MOUNT_ARG}${FIRST}${drive}=RW"
                    FIRST=":"
                fi
            else
                echo "Skipping $drive as it is not formatted as ext4. Detected type: $fs_type"
            fi
        fi
    done

    if [ -z "$MOUNT_ARG" ]; then
        echo "No drives mounted under /media/pi"
        return 1
    fi

    echo "MOUNT_ARG= $MOUNT_ARG"
    echo "MOUNT_PATH= $MOUNT_PATH"

    # Remove Docker volume so the daemon cannot recreate its stale bind mount.
    # docker-compose up (in fula.sh) will recreate it from the correct mergerfs.
    umount /var/lib/docker/volumes/fula_shared-volume-external/_data 2>/dev/null || true
    docker volume rm fula_shared-volume-external 2>/dev/null || true

    if mergerfs -o allow_other,cache.files=partial,dropcacheonclose=true,default_permissions,use_ino,category.create=lfs,nonempty "$MOUNT_ARG" "$MOUNT_PATH"; then
        systemd-notify WATCHDOG=1
        # Prevent future Docker bind-mount propagation from stacking mounts.
        mount --make-private "$MOUNT_PATH" 2>/dev/null || true
        echo "MergerFS mounted successfully"
    else
        systemd-notify WATCHDOG=1
        echo "Failed to mount MergerFS"
        return 1
    fi
}

mount_drives(){
	unionfs_fuse_mount_drives
}
systemd-notify WATCHDOG=1
check_mount_max_attempts=3
check_mount_attempt=1
systemd-notify WATCHDOG=1
check_mount() {
    is_correctly_unmounted=true
    external_disks=""
    systemd-notify WATCHDOG=1
    # Check for external disks (excluding internal mmcblk and zram)
    for disk in $(lsblk -ndo NAME); do
        systemd-notify WATCHDOG=1
        case "$disk" in
            sd*|nvme*)
                external_disks="$external_disks $disk"
                ;;
        esac
    done

    if [ -n "$external_disks" ]; then
        echo "External disk(s) detected:$external_disks"
        for disk in $external_disks; do
            systemd-notify WATCHDOG=1
            # Derive correct partition name (NVMe uses 'p1' suffix, SATA uses '1')
            case "$disk" in
                nvme*)
                    partition="${disk}p1"
                    ;;
                *)
                    partition="${disk}1"
                    ;;
            esac
            if ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                echo "Attempting to mount ${partition} (attempt $check_mount_attempt)"
                systemd-notify WATCHDOG=1

                # Strategy 1: systemctl restart automount service
                sudo systemctl restart "automount@${partition}" 2>/dev/null || true
                sync
                systemd-notify WATCHDOG=1
                sleep 5
                systemd-notify WATCHDOG=1

                if ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                    echo "Automount service failed for ${partition}. Trying automount.sh directly..."

                    # Ensure mount point directory exists and is clean
                    if [ -d "${MOUNT_USB_PATH}/${partition}" ] && ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                        sudo rm -rf "${MOUNT_USB_PATH}/${partition}"
                    fi
                    sudo mkdir -p "${MOUNT_USB_PATH}/${partition}"
                    sync
                    systemd-notify WATCHDOG=1

                    # Strategy 2: call automount.sh directly (bypasses systemd)
                    if [ -x /usr/local/bin/automount.sh ]; then
                        sudo /usr/local/bin/automount.sh "${partition}" 2>/dev/null || true
                        sleep 2
                        systemd-notify WATCHDOG=1
                    fi

                    if ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                        echo "automount.sh failed for ${partition}. Trying direct mount..."

                        # Strategy 3: bare mount command
                        if [ -b "/dev/${partition}" ]; then
                            sudo mount "/dev/${partition}" "${MOUNT_USB_PATH}/${partition}" 2>/dev/null && \
                                sudo chown pi:pi "${MOUNT_USB_PATH}/${partition}" 2>/dev/null || true
                            sleep 1
                            systemd-notify WATCHDOG=1
                        fi

                        if ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                            echo "All mount strategies failed for ${partition}."
                            # Only consider partitioning after max attempts AND confirmed no filesystem
                            if [ "$check_mount_attempt" -ge "$check_mount_max_attempts" ]; then
                                if [ -b "/dev/${partition}" ]; then
                                    fs_type=$(blkid -o value -s TYPE "/dev/${partition}" 2>/dev/null)
                                else
                                    fs_type=""
                                fi
                                if [ -z "$fs_type" ]; then
                                    echo "No filesystem on /dev/${partition} after $check_mount_attempt attempts. Creating partition flag."
                                    sudo touch "$COMMANDS_DIR/.command_partition"
                                    log "created partition flag. exiting."
                                    exit 1
                                else
                                    echo "Filesystem '$fs_type' exists on /dev/${partition} but mount failed. Will keep retrying."
                                fi
                            fi
                        fi
                    fi
                fi
            fi
        done

        # Check if mergerfs is properly mounted
        if ! df -T "$MOUNT_PATH" | grep -q "fuse.mergerfs"; then
            echo "MergerFS not properly mounted."
            is_correctly_unmounted=false
        fi
    else
        echo "No external disks detected."
    fi
    check_mount_attempt=$((check_mount_attempt + 1))

    if [ "$is_correctly_unmounted" = true ]; then
        echo "$MOUNT_PATH is correctly unmounted (no external disks or not merged)."
        return 0  # Success
    else
        echo "$MOUNT_PATH should be mounted but isn't. There might be an issue."
        return 1  # Failure
    fi
}

# Wait for at least one drive to be mounted under /media/pi
while [ "$(check_mounted_drives)" -eq 0 ]; do
    echo "Waiting for at least one drive to be mounted under /media/pi..."
    systemd-notify WATCHDOG=1
    if ! check_mount; then
        systemd-notify WATCHDOG=1
        echo "Mount attempt $check_mount_attempt failed."
    fi
    if [ "$check_mount_attempt" -gt "$check_mount_max_attempts" ]; then
        echo "Max attempts exceeded. Waiting 30s before retrying..."
        sleep 25  # + 5 below = 30 total, within WatchdogSec=120
    fi
    sleep 5  # Wait before checking again
done

echo "Drive(s) detected. Proceeding with the script..."

# Mount drives initially
sync
sleep 1
systemd-notify WATCHDOG=1
mount_drives

# Now start monitoring for changes
check_and_remount() {
    systemd-notify WATCHDOG=1
    is_correctly_mounted=false
    # Check if /uniondrive is mounted
    if mountpoint -q "$MOUNT_PATH"; then
        echo "$MOUNT_PATH is mounted. Checking if it's correctly mounted..."
        systemd-notify WATCHDOG=1
        # Check if it's a mergerfs mount
        if grep -qs "$MOUNT_PATH" /proc/mounts && grep -qs "$MOUNT_PATH.*fuse.mergerfs" /proc/mounts; then
            # Check if it's actually using the external drives
            if df -T "$MOUNT_PATH" | grep -q "fuse.mergerfs"; then
                echo "$MOUNT_PATH is correctly mounted as mergerfs."
                is_correctly_mounted=true
            else
                echo "$MOUNT_PATH is mounted as mergerfs but not using external drives."
            fi
        else
            echo "$MOUNT_PATH is mounted but not as mergerfs."
            # Docker's shared-volume-external bind mount can propagate a stale
            # ext4 mount from the root partition on top of mergerfs.  Peel off
            # all non-mergerfs layers and clear the Docker volume bind mount
            # that sources the propagation.
            actual_fs=$(findmnt -n -o FSTYPE "$MOUNT_PATH" 2>/dev/null)
            if [ "$actual_fs" = "ext4" ]; then
                echo "Stale ext4 bind mount detected on $MOUNT_PATH. Removing..."
                # Remove the Docker volume entirely so the daemon stops
                # recreating its bind mount.
                docker stop ipfs_host ipfs_local ipfs_cluster fula_go 2>/dev/null || true
                umount /var/lib/docker/volumes/fula_shared-volume-external/_data 2>/dev/null || true
                docker volume rm fula_shared-volume-external 2>/dev/null || true
                # Peel all ext4 layers from /uniondrive
                peel_count=0
                while [ "$peel_count" -lt 10 ] && \
                      mountpoint -q "$MOUNT_PATH" && \
                      [ "$(findmnt -n -o FSTYPE "$MOUNT_PATH" 2>/dev/null)" = "ext4" ]; do
                    umount "$MOUNT_PATH" 2>/dev/null || break
                    peel_count=$((peel_count + 1))
                done
                sleep 1
                new_fs=$(findmnt -n -o FSTYPE "$MOUNT_PATH" 2>/dev/null)
                if [ "$new_fs" = "fuse.mergerfs" ]; then
                    echo "mergerfs now visible after removing stale bind mount(s)."
                    mount --make-private "$MOUNT_PATH" 2>/dev/null || true
                    is_correctly_mounted=true
                fi
            fi
        fi
    else
        echo "$MOUNT_PATH is not mounted."
        check_mount_attempt=1  # Reset for monitoring retry
        if ! check_mount; then
            echo "There might be an issue with mounting. Please check the system logs."
            is_correctly_mounted=false
        fi
    fi

    if ! $is_correctly_mounted; then
        echo "$MOUNT_PATH is not mounted or wrongly mounted. Checking for drives..."
        if [ "$(ls -A $MOUNT_USB_PATH)" ]; then
            echo "Drives found in $MOUNT_USB_PATH. Remounting..."
            systemd-notify WATCHDOG=1
            sleep 5
            systemd-notify WATCHDOG=1
            current_mount_count=$(check_mounted_drives)
            echo "Current mounted drives: $current_mount_count"
            echo "Last mounted drives: $last_mount_count"
            
            echo "Updating mergerfs mount."
            if [ -f "$FULA_PATH/control_led.py" ]; then
                python ${FULA_PATH}/control_led.py light_purple 9000 &
            fi
            systemctl stop fula
            echo "fula stopped"
            systemd-notify WATCHDOG=1
            umount_drives
            rm -rf "${MOUNT_LINKS:?}"/*
            systemd-notify WATCHDOG=1
            DISK_INDEX=0
            for drive in /media/pi/*; do
                systemd-notify WATCHDOG=1
                if mountpoint -q "$drive"; then
                    create_disk_link "$drive"
                fi
            done
            
            mkdir -p $MOUNT_PATH
            mount_drives
            
            if mountpoint -q "$MOUNT_PATH"; then
                echo "MergerFS remounted successfully"
                touch "$SETUP_DONE_FILE"
                last_mount_count=$current_mount_count
                systemctl start fula
                echo "fula started"
            else
                echo "Failed to remount MergerFS. NOT starting fula — will retry on next drive event."
                rm -f "$SETUP_DONE_FILE" 2>/dev/null || true
            fi
            if [ -f /usr/bin/fula/control_led.py ]; then
                python /usr/bin/fula/control_led.py light_purple 0
            fi
            
            cleanup_mounts
        else
            echo "No drives found in $MOUNT_USB_PATH. Skipping remount."
        fi
    else
        echo "$MOUNT_PATH is already properly mounted. No action needed."
    fi
}

monitor_and_update_drives() {
    systemd-notify WATCHDOG=1
    last_mount_count=$(check_mounted_drives)
    
    while true; do
        sleep 5
        systemd-notify WATCHDOG=1
        
        echo "Waiting for changes in /media/pi..."
        inotifywait -q -t 20 -e create,delete,move,unmount /media/pi
        echo "No change detected in the last 20 seconds"
        systemd-notify WATCHDOG=1

        check_and_remount
        
        systemd-notify WATCHDOG=1
    done
}

remove_recursive_pattern() {
    systemd-notify WATCHDOG=1
    base_path="$1"
    pattern="$2"
    if [ -d "$base_path" ]; then
        sudo find "$base_path" -maxdepth 1 -type d -name "$pattern" -exec sh -c '
            for dir do
                echo "Removing recursive directory: $dir"
                sudo rm -rf "$dir"
            done
        ' sh {} +
    else
        echo "Base path $base_path does not exist or is not a directory"
    fi
}

cleanup_mounts() {
    for dir in "${MOUNT_USB_PATH:?}"/*; do
        systemd-notify WATCHDOG=1
        if [ -d "$dir" ] && ! mountpoint -q "$dir"; then
            echo "Removing unmounted directory $dir"
            rm -rf "$dir"
        fi
    done
}


hash_map=","
# map(map_name,key,value) table for storing links
hput() {
     hash_map="$hash_map,$1:$2"
}
# return map(map_name,key)  to $value
hget() {
   eval echo "$(expr "$hash_map" : ".*,$1:\([^,]*\),.*")"
}


DISK_INDEX=0

create_disk_link() {
    systemd-notify WATCHDOG=1
    if mountpoint -q "$1"; then
        DISK_INDEX=$((DISK_INDEX+1))
        LINK_NAME="disk-$DISK_INDEX"
        LINK_PATH="$MOUNT_LINKS/$LINK_NAME"
        
        if [ -L "$LINK_PATH" ]; then
            # Link already exists, remove it
            rm "$LINK_PATH"
            echo "Removed existing link $LINK_NAME"
        fi
        
        if ln -sf "$(readlink -f "$1")" "$LINK_PATH"; then
            echo "Created link $LINK_NAME for $1"
        else
            echo "Failed to create link $LINK_NAME for $1"
        fi
    else
        echo "Skipping $1, not a mount point."
    fi
}

#delete previous symbolic folders
for d in "${MOUNT_LINKS:?}"/*; do
   rm -rf "$d"
done

for pattern in sda sdb sdc sdd sde nvme; do
    remove_recursive_pattern "$MOUNT_PATH" "${pattern}*"
done

check_fs_type() {
    local_mount_path="$1"
    local_expected_type="$2"

    local_actual_type=$(findmnt -no FSTYPE "$local_mount_path")
    if [ "$local_actual_type" = "$local_expected_type" ]; then
        return 0  # Success
    else
        return 1  # Failure
    fi
}

# Timeout for the mount to become available and to check if it's not read-only.
TIMEOUT=60
ELAPSED=0
SLEEP_INTERVAL=5
check_mount_attempt=1
while [ $ELAPSED -lt $TIMEOUT ]; do
    sleep $SLEEP_INTERVAL
    systemd-notify WATCHDOG=1
    if mountpoint -q "$MOUNT_PATH"; then
        log "Mount successful"

        if check_fs_type "$MOUNT_PATH" "fuse.mergerfs"; then
            log "Correct filesystem type (fuse.mergerfs) detected"

            # Try to write a temporary file to check if the filesystem is read-write
            if touch "$MOUNT_PATH/.test_rw" > /dev/null 2>&1; then
                log "Filesystem is read-write"
                rm -f "$MOUNT_PATH/.test_rw" > /dev/null 2>&1  # Clean up the test file
                touch "$SETUP_DONE_FILE"
                sync
                echo "Created setup done file"
                systemd-notify --ready
                break
            else
                log "Filesystem is not writable (attempt $check_mount_attempt)."
                # Check underlying drives for I/O errors
                for drive in /media/pi/*; do
                    if mountpoint -q "$drive"; then
                        if ! ls "$drive" > /dev/null 2>&1; then
                            log "WARNING: $drive has I/O errors — drive may be failing or disconnected."
                        fi
                    fi
                done
                # Cannot use 'mount -o remount' on FUSE — kernel injects
                # options like 'relatime' that mergerfs does not understand.
                # Unmount and re-mount, excluding bad drives.
                log "Remounting mergerfs without bad drives..."
                umount_drives
                sync
                sleep 2
                mount_drives
                check_mount_attempt=$((check_mount_attempt + 1))
            fi
        else
            log "Incorrect filesystem type. Expected fuse.mergerfs."
            umount_drives
            sync
            sleep 1
            systemd-notify WATCHDOG=1
            remove_unionready
            sync
            sleep 1
            systemd-notify WATCHDOG=1
            # Track exec restarts to prevent infinite loop
            UNION_EXEC_COUNT=${UNION_EXEC_COUNT:-0}
            UNION_EXEC_COUNT=$((UNION_EXEC_COUNT + 1))
            export UNION_EXEC_COUNT
            if [ "$UNION_EXEC_COUNT" -ge 5 ]; then
                log "ERROR: Filesystem type still wrong after $UNION_EXEC_COUNT exec restarts. Exiting for systemd retry."
                exit 1
            fi
            # Restart the script from the beginning
            exec "$0" "$@"
        fi
    else
        log "Mount is not available yet. Waiting..."
    fi

    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "Mount did not become available or writable within the timeout period. exiting."
    exit 1
fi

#log $hash_map

monitor_and_update_drives
remove_exit_trap
