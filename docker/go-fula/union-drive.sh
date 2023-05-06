#!/bin/sh

MOUNT_USB_PATH=/storage
MOUNT_LINKS=/storagelinks
MOUNT_PATH=/uniondrive

MAX_DRIVES=20

log()
{
  echo $1
}

unionfs_fuse_mount_drives() {
 # ... (same code as before)
}

mount_drives(){
  unionfs_fuse_mount_drives
}

umount_drives() {
 # ... (same code as before)
}

hash_map=","
hput() {
 # ... (same code as before)
}
hget() {
 # ... (same code as before)
}

DISK_INDEX=0

create_disk_link(){
 # ... (same code as before)
}

umount_drives

for d in $MOUNT_LINKS/* ; do
   rm $d
done 

mkdir -p $MOUNT_LINKS
mkdir -p $MOUNT_PATH

rm -r $MOUNT_LINKS/*

while true; do
  # Get the list of mounted external storage devices
  EXTERNAL_DRIVES=$(lsblk -o NAME,TRAN | grep 'usb' | awk '{print "/dev/"$1}')
  
  for drive in $EXTERNAL_DRIVES; do
    # Get the mount point for the current drive
    MOUNT_POINT=$(grep "$drive" /proc/mounts | awk '{print $2}')
    
    # Check if the mount point is under the MOUNT_USB_PATH
    if [ ! -z "$MOUNT_POINT" ] && [[ "$MOUNT_POINT" == "$MOUNT_USB_PATH"* ]]; then
      create_disk_link "$MOUNT_POINT"
    fi
  done

  # Mount the drives after creating the symbolic links
  mount_drives

  sleep 30

  # Unmount the drives before the next iteration
  umount_drives
  rm -r $MOUNT_LINKS/*

done
