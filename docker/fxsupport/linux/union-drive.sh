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

    # Check if argument is provided
    if [ -z "$local_mount_point" ]; then
        echo "Error: Mount point argument is required"
        exit 1
    fi

    # Check if mount point exists
    if [ ! -d "$local_mount_point" ]; then
        echo "Error: Mount point does not exist"
        exit 1
    fi

    # Use df -PT to get the actual filesystem type, ignoring FUSE layers
    # -P for POSIX format
    # grep to find the specific mount point
    # awk to extract just the filesystem type
    fs_type=$(df -PT "$local_mount_point" | grep "$local_mount_point" | awk '{print $2}')

    if [ -z "$fs_type" ]; then
        echo "Error: Could not detect filesystem type"
        exit 1
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
                MOUNT_ARG="${MOUNT_ARG}${FIRST}${drive}=RW"
                FIRST=":"
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
    
    if mergerfs -o allow_other,cache.files=partial,dropcacheonclose=true,default_permissions,use_ino,category.create=lfs,nonempty "$MOUNT_ARG" "$MOUNT_PATH"; then
        systemd-notify WATCHDOG=1
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
            partition="${disk}1"
            if ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                echo "Attempting to mount ${partition}"
                systemd-notify WATCHDOG=1
                sudo systemctl restart "automount@${partition}"
                sync
                systemd-notify WATCHDOG=1
                sleep 5
                systemd-notify WATCHDOG=1
                if ! mountpoint -q "${MOUNT_USB_PATH}/${partition}"; then
                    echo "Automount failed. Attempting a parition."
                    if [ -d "${MOUNT_USB_PATH}/${partition}" ]; then
                        sudo rm -rf "${MOUNT_USB_PATH}/${partition}"
                    fi
                    sync
                    sleep 1
                    systemd-notify WATCHDOG=1
                    sudo mkdir -p "${MOUNT_USB_PATH}/${partition}"
                    sync
                    sleep 1
                    systemd-notify WATCHDOG=1
                    if [ "$check_mount_attempt" -eq 1 ]; then
                        sudo touch "$COMMANDS_DIR/.command_partition"
                        log "created partition flag. exiting."
                        exit 1
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
    if [ $check_mount_attempt -le $check_mount_max_attempts ]; then
        if ! check_mount; then
            systemd-notify WATCHDOG=1
            echo "Attempt $check_mount_attempt of $check_mount_max_attempts"
            echo "There might be an issue with mounting. Please check the system logs."
        fi
    fi
    sleep 5  # Wait for 5 seconds before checking again
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
        fi
    else
        echo "$MOUNT_PATH is not mounted."
        if [ $check_mount_attempt -le $check_mount_max_attempts ]; then
            if ! check_mount; then
                echo "There might be an issue with mounting. Please check the system logs."
                is_correctly_mounted=false
            fi
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
            else
                echo "Failed to remount MergerFS"
            fi
            
            last_mount_count=$current_mount_count
            systemctl start fula
            echo "fula started"
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
                log "Filesystem is read-only. Attempting to remount as read-write."
                if ! mount -o remount,rw,nonempty "$MOUNT_PATH"; then
                    log "Failed to remount /uniondrive as read-write. exiting."
                    exit 1
                fi
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
