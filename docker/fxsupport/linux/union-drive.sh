#!/bin/sh

### With monitor instead of creating dummy drives

# Set the NOTIFY_SOCKET environment variable
export NOTIFY_SOCKET=/run/systemd/notify

MOUNT_USB_PATH=/media/pi
MOUNT_LINKS=/home/pi/drives
MOUNT_PATH=/uniondrive
SETUP_DONE_FILE="$MOUNT_PATH/setup.done"
mkdir -p $MOUNT_PATH

rm -f "$MOUNT_LINKS"/disk-*

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

    while [ $ATTEMPT -lt $MAX_ATTEMPTS ]; do
        echo "Attempting to unmount $MOUNT_PATH (Attempt $((ATTEMPT+1))/$MAX_ATTEMPTS)"
        if mountpoint -q "$MOUNT_PATH" || umount "$MOUNT_PATH"; then
            echo "$MOUNT_PATH successfully unmounted or was not a mount point"
            break
        else
            echo "Failed to unmount $MOUNT_PATH"
            ATTEMPT=$((ATTEMPT+1))
            # Check if the transport endpoint is not connected
            if ! mountpoint -q "$MOUNT_PATH"; then
                echo "Transport endpoint is not connected"
                # Attempt a lazy unmount
                if umount -l "$MOUNT_PATH"; then
                    echo "Lazy unmount of $MOUNT_PATH successful"
                    break
                fi
            fi
            sleep 2
        fi
    done

    if mountpoint -q "$MOUNT_PATH"; then
        echo "Failed to unmount $MOUNT_PATH after $MAX_ATTEMPTS attempts"
        # Optionally, you can add more aggressive unmounting methods here
        # For example: umount -f "$MOUNT_PATH" or umount -l "$MOUNT_PATH"
    else
        echo "$MOUNT_PATH is not mounted"
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
        touch "$SETUP_DONE_FILE"
        echo "Created setup done file"
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
    sleep 5  # Wait for 5 seconds before checking again
done

echo "Drive(s) detected. Proceeding with the script..."

# Mount drives initially
mount_drives

# Now start monitoring for changes
monitor_and_update_drives() {
    last_mount_count=$(check_mounted_drives)
    
    while true; do
        systemd-notify WATCHDOG=1
        
        echo "Waiting for changes in /media/pi..."
        inotifywait -q -e create,delete,move,unmount /media/pi
        
        # Wait a moment for the system to finish mounting/unmounting
        sleep 7
        
        current_mount_count=$(check_mounted_drives)
        echo "Current mounted drives: $current_mount_count"
        echo "Last mounted drives: $last_mount_count"
        
        if [ "$current_mount_count" != "$last_mount_count" ]; then
            echo "Detected change in mounted drives. Updating mergerfs mount."
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
        fi
        
        cleanup_mounts
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
        ln -sf "$(readlink -f "$1")" "$MOUNT_LINKS/$LINK_NAME"
        echo "Created link $LINK_NAME for $1"
    else
        echo "Skipping $1, not a mount point."
    fi
}

remove_unionready

umount_drives

#delete previous symbolic folders
for d in "${MOUNT_LINKS:?}"/*; do
   rm -rf "$d"
done 

mkdir -p $MOUNT_LINKS
mkdir -p $MOUNT_PATH

mount_drives

for pattern in sda sdb sdc sdd sde nvme; do
    remove_recursive_pattern "$MOUNT_PATH" "${pattern}*"
done

# Timeout for the mount to become available and to check if it's not read-only.
TIMEOUT=60
ELAPSED=0
SLEEP_INTERVAL=5

while [ $ELAPSED -lt $TIMEOUT ]; do
    if mountpoint -q "$MOUNT_PATH"; then
        log "Mount successful"

        # Try to write a temporary file to check if the filesystem is read-write
        if touch "$MOUNT_PATH/.test_rw" > /dev/null 2>&1; then
            log "Filesystem is read-write"
            rm -f "$MOUNT_PATH/.test_rw" > /dev/null 2>&1  # Clean up the test file
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
        log "Mount is not available yet. Waiting..."
    fi

    ELAPSED=$((ELAPSED + SLEEP_INTERVAL))
    sleep $SLEEP_INTERVAL
done

if [ $ELAPSED -ge $TIMEOUT ]; then
    log "Mount did not become available or writable within the timeout period."
    exit 1
fi

#remove to create new one
rm -rf "${MOUNT_LINKS:?}"/*

#log $hash_map

monitor_and_update_drives
remove_exit_trap
