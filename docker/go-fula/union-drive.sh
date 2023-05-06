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
 MOUNT_ARG=""
 FIRST=""

 for d in `seq 0 $MAX_DRIVES` ; do
   DISK_PATH=${MOUNT_LINKS}/disk-${d}
   mkdir $DISK_PATH;
   MOUNT_ARG="${MOUNT_ARG}${FIRST}${DISK_PATH}=RW"
   FIRST=":"
 done 
 mergerfs -o allow_other "$MOUNT_ARG" "$MOUNT_PATH" 
}

mount_drives(){
  unionfs_fuse_mount_drives
}

umount_drives() {
 umount  $MOUNT_PATH  
}

hash_map=","
hput() {
     hash_map="$hash_map,$1:$2"
}
hget() {
   eval echo "$(expr "$hash_map" : ".*,$1:\([^,]*\),.*")"
}

DISK_INDEX=0

create_disk_link(){
   DISK_INDEX=$((DISK_INDEX+1))
   LINK_NAME="disk-$DISK_INDEX"
   ln -s "$1" "$MOUNT_LINKS/$LINK_NAME" 
   hput "$1" "$LINK_NAME"
}

umount_drives

for d in $MOUNT_LINKS/* ; do
   rm $d
done 

mkdir -p $MOUNT_LINKS
mkdir -p $MOUNT_PATH

mount_drives
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
  sleep 30
done