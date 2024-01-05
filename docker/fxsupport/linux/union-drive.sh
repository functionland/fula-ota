#!/bin/sh

# Set the NOTIFY_SOCKET environment variable
export NOTIFY_SOCKET=/run/systemd/notify

MOUNT_USB_PATH=/media/pi
MOUNT_LINKS=/home/pi/drives
MOUNT_PATH=/uniondrive


MAX_DRIVES=20

log()
{
  echo $1
}

# New while loop to wait for at least one drive to be mounted under /media/pi
while [ -z "$(ls -A /media/pi)" ]; do
    echo "Waiting for at least one drive to be mounted under /media/pi..."
    sleep 5  # Wait for 5 seconds before checking again
done

echo "Drive detected. Proceeding with the script..."

unionfs_fuse_mount_drives() {
 #log "mount drives" 
 #unionfs-fuse -o cow /root/dir1=RW:/root/dir2=RW  /home/mohsen/mount-fuse
 MOUNT_ARG=""
 FIRST=""

#create MAX_DRIVES empty directory for mapping drivers
#all of them will be deleted after
 for d in `seq 0 $MAX_DRIVES` ; do
   DISK_PATH=${MOUNT_LINKS}/disk-${d}
   mkdir -p $DISK_PATH;
   MOUNT_ARG="${MOUNT_ARG}${FIRST}${DISK_PATH}=RW"
   FIRST=":"
 done 
 mergerfs -o allow_other,direct_io,default_permissions,use_ino,category.create=lfs,minfreespace=1G "$MOUNT_ARG" "$MOUNT_PATH" 
}

mount_drives(){
unionfs_fuse_mount_drives
}

umount_drives() {
  if mountpoint -q $MOUNT_PATH; then
    umount $MOUNT_PATH
  fi
  if [ -z "$MOUNT_PATH" ]; then
   echo "MOUNT_PATH is unset or empty, exiting..."
  else
   sudo rm -r "${MOUNT_PATH:?}"
  fi
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

create_disk_link(){
   #log "create_disk_link start for $1" 
   DISK_INDEX=$((DISK_INDEX+1))
   LINK_NAME="disk-$DISK_INDEX"
   ln -s "$1" "$MOUNT_LINKS/$LINK_NAME" 
   hput "$1" "$LINK_NAME"
   #log "create_disk_link end for $1 in $MOUNT_LINKS/$LINK_NAME" 
}

umount_drives


#delete previous symbolic files
for d in $MOUNT_LINKS/* ; do
   rm $d
done 

mkdir -p $MOUNT_LINKS
mkdir -p $MOUNT_PATH

mount_drives

# Timeout for the mount to become available and to check if it's not read-only.
TIMEOUT=60
ELAPSED=0
SLEEP_INTERVAL=5

while [ $ELAPSED -lt $TIMEOUT ]; do
    if mountpoint -q "$MOUNT_PATH"; then
        log "Mount successful"

        # Try to write a temporary file to check if the filesystem is read-write
        if touch "$MOUNT_PATH/.test_rw" &>/dev/null; then
            log "Filesystem is read-write"
            rm -f "$MOUNT_PATH/.test_rw" &>/dev/null # Clean up the test file
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
rm -r $MOUNT_LINKS/*

#mount current drives
for d in $MOUNT_USB_PATH/* ; do
   create_disk_link "$d"
done 
#log $hash_map

while true; do
   systemd-notify WATCHDOG=1
   cat /proc/mounts | grep "$MOUNT_USB_PATH" |
    while IFS= read -r line; do
        if [ ! -s "$line" ]; then
		value=$(echo $line | cut -d ' ' -f 2)
		if [ -z $value ]; then
			 create_disk_link "$value"
		fi
        fi
    done 
    sleep 20
done