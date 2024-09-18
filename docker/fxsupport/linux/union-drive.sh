#!/bin/sh

### With monitor instead of creating dummy drives

# Set the NOTIFY_SOCKET environment variable
export NOTIFY_SOCKET=/run/systemd/notify

MOUNT_USB_PATH=/media/pi
MOUNT_LINKS=/home/pi/drives
MOUNT_PATH=/uniondrive
SETUP_DONE_FILE="$MOUNT_PATH/setup.done"
FULA_PATH=/usr/bin/fula

mkdir -p $MOUNT_PATH
mkdir -p $MOUNT_LINKS

rm -f "$MOUNT_LINKS"/disk-*
sync

log()
{
  echo "$1"
}

remove_unionready() {
    if [ -d "$MOUNT_PATH" ] && [ -f "$SETUP_DONE_FILE" ]; then
        echo "Removing $SETUP_DONE_FILE..."
        rm -f "$SETUP_DONE_FILE" || true
    else
        echo "Either $MOUNT_PATH does not exist or $SETUP_DONE_FILE does not exist."
    fi
}
remove_unionready

umount_drives() {
  # Set a maximum number of attempts to prevent an infinite loop
    MAX_ATTEMPTS=10
    ATTEMPT=0

    while umount "$MOUNT_PATH" 2>/dev/null; do
        log "Successfully unmounted $MOUNT_PATH. Attempting again to ensure complete unmount."
        if [ $ATTEMPT -gt $MAX_ATTEMPTS ]; then
            umount -f "$MOUNT_PATH" || true
            break
        fi
        systemd-notify WATCHDOG=1
        sleep 5
    done

    if mountpoint -q "$MOUNT_PATH"; then
        echo "Failed to unmount $MOUNT_PATH after $MAX_ATTEMPTS attempts"
        # Optionally, you can add more aggressive unmounting methods here
        # For example: umount -f "$MOUNT_PATH" or umount -l "$MOUNT_PATH"
    else
        echo "$MOUNT_PATH is not mounted"
        if [ -d "$MOUNT_PATH" ]; then
            sudo rm -rf "$MOUNT_PATH"/*
        fi
    fi
}

remove_unionready
umount_drives

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
    mounted_count=0
    for drive in /media/pi/*; do
        if mountpoint -q "$drive"; then
            mounted_count=$((mounted_count + 1))
            echo "Detected mounted drive: $drive" >&2
        fi
    done
    echo $mounted_count
}

unionfs_fuse_mount_drives() {
    MOUNT_ARG=""
    FIRST=""

    for drive in /media/pi/*; do
        if mountpoint -q "$drive"; then
            MOUNT_ARG="${MOUNT_ARG}${FIRST}${drive}=RW"
            FIRST=":"
        fi
    done

    if [ -z "$MOUNT_ARG" ]; then
        echo "No drives mounted under /media/pi"
        return 1
    fi

    echo "MOUNT_ARG= $MOUNT_ARG"
    echo "MOUNT_PATH= $MOUNT_PATH"
    
    if mergerfs -o allow_other,cache.files=partial,dropcacheonclose=true,default_permissions,use_ino,category.create=lfs,minfreespace=1G,nonempty "$MOUNT_ARG" "$MOUNT_PATH"; then
        echo "MergerFS mounted successfully"
    else
        echo "Failed to mount MergerFS"
        return 1
    fi
}

mount_drives(){
	unionfs_fuse_mount_drives
}

# Wait for at least one drive to be mounted under /media/pi
while [ $(check_mounted_drives) -eq 0 ]; do
    echo "Waiting for at least one drive to be mounted under /media/pi..."
    systemd-notify WATCHDOG=1
    sleep 5  # Wait for 5 seconds before checking again
done

echo "Drive(s) detected. Proceeding with the script..."

# Mount drives initially
sync
sleep 1
systemd-notify WATCHDOG=1
mount_drives

# Now start monitoring for changes
monitor_and_update_drives() {
    systemd-notify WATCHDOG=1
    last_mount_count=$(check_mounted_drives)
    
    while true; do
        sleep 5
        systemd-notify WATCHDOG=1
        
        echo "Waiting for changes in /media/pi..."
        inotifywait -q -t 20 -e create,delete,move,unmount /media/pi
        echo "No change detected in the last 20 seconds"
        continue
        
        # Wait a moment for the system to finish mounting/unmounting
        sleep 7
        
        current_mount_count=$(check_mounted_drives)
        echo "Current mounted drives: $current_mount_count"
        echo "Last mounted drives: $last_mount_count"
        
        if [ "$current_mount_count" != "$last_mount_count" ]; then
            echo "Detected change in mounted drives. Updating mergerfs mount."
            if [ -f "$FULA_PATH/control_led.py" ]; then
                python ${FULA_PATH}/control_led.py light_purple 9000 &
            fi
            systemctl stop fula
            echo "fula stoped"
            
            umount_drives
            rm -rf "${MOUNT_LINKS:?}"/*
            
            DISK_INDEX=0
            for drive in /media/pi/*; do
                if mountpoint -q "$drive"; then
                    create_disk_link "$drive"
                fi
            done
            
            # Always remount after a change is detected
            mkdir -p $MOUNT_PATH
            mount_drives
            
            # Check if the mount was successful
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
        fi
        
        cleanup_mounts
        systemd-notify WATCHDOG=1
    done
}

remove_recursive_pattern() {
    base_path="$1"
    pattern="$2"
    if [ -d "$base_path" ]; then
        sudo find "$base_path" -maxdepth 1 -type d -name "$pattern" -print0 | while IFS= read -r -d '' dir; do
            echo "Removing recursive directory: $dir"
            sudo rm -rf "$dir"
        done
    else
        echo "Base path $base_path does not exist or is not a directory"
    fi
}

cleanup_mounts() {
    for dir in "${MOUNT_USB_PATH:?}"/*; do
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
                if ! mount -o remount,rw "$MOUNT_PATH"; then
                    log "Failed to remount /uniondrive as read-write."
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
    log "Mount did not become available or writable within the timeout period."
    exit 1
fi

#log $hash_map

monitor_and_update_drives
remove_exit_trap
