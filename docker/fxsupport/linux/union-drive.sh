#!/bin/sh

### With monitor instead of creating dummy drives

# Set the NOTIFY_SOCKET environment variable
export NOTIFY_SOCKET=/run/systemd/notify

MOUNT_USB_PATH=/media/pi
MOUNT_LINKS=/home/pi/drives
MOUNT_PATH=/uniondrive
mkdir -p $MOUNT_PATH
MAX_DRIVES=20

rm -f "$MOUNT_LINKS"/disk-*

log()
{
  echo "$1"
}


check_mounted_drives() {
    local mounted_count=0
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
    sleep 5  # Wait for 5 seconds before checking again
done

echo "Drive(s) detected. Proceeding with the script..."

# Mount drives initially
mount_drives

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

# Now start monitoring for changes
monitor_and_update_drives() {
    local last_mount_count=$(check_mounted_drives)
    
    while true; do
        systemd-notify WATCHDOG=1
        
        echo "Waiting for changes in /media/pi..."
        inotifywait -q -e create,delete,move,unmount /media/pi
        
        # Wait a moment for the system to finish mounting/unmounting
        sleep 2
        
        local current_mount_count=$(check_mounted_drives)
        echo "Current mounted drives: $current_mount_count"
        echo "Last mounted drives: $last_mount_count"
        
        if [ "$current_mount_count" != "$last_mount_count" ]; then
            echo "Detected change in mounted drives. Updating mergerfs mount."
            
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
        fi
        
        cleanup_mounts
    done
}

remove_recursive_pattern() {
    local base_path="$1"
    local pattern="$2"
    if [ -d "$base_path" ]; then
        sudo find "$base_path" -maxdepth 1 -type d -name "$pattern" -print0 | while IFS= read -r -d '' dir; do
            echo "Removing recursive directory: $dir"
            sudo rm -rf "$dir"
        done
    else
        echo "Base path $base_path does not exist or is not a directory"
    fi
}

umount_drives() {
  if mountpoint -q $MOUNT_PATH; then
    umount $MOUNT_PATH
  fi
  if [ -z "$MOUNT_PATH" ]; then
    echo "MOUNT_PATH is unset or empty, exiting..."
  else
    # Clear the contents of MOUNT_PATH, but don't remove the directory
    rm -rf "${MOUNT_PATH:?}"/*
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
