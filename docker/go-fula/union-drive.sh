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
 #log "mount drives" 
 #unionfs-fuse -o cow /root/dir1=RW:/root/dir2=RW  /home/mohsen/mount-fuse
 MOUNT_ARG=""
 FIRST=""

#create MAX_DRIVES empty directory for mapping drivers
#all of them will be deleted after
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
 #log "drive removed" 
 umount  $MOUNT_PATH  
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
#remove to create new one
rm -r $MOUNT_LINKS/*

#mount current drives
for d in $MOUNT_USB_PATH/* ; do
   create_disk_link "$d"
done 
#log $hash_map

while true; do
   cat /proc/mounts | grep "$MOUNT_USB_PATH" |
    while IFS= read -r line; do
        value=$(echo $line | cut -d ' ' -f 2)
        if [ ! -z $value ]; then
            create_disk_link "$value"
        fi
    done 
    sleep 2
done