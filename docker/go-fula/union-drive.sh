#!/bin/sh

MOUNT_USB_PATH=/storage
MOUNT_LINKS=/storagelinks
MOUNT_PATH=/uniondrive


log()
{
  echo $1
}

unionfs_fuse_mount_drives() {
 log "mount drives" 
 #unionfs-fuse -o cow /root/dir1=RW:/root/dir2=RW  /home/mohsen/mount-fuse
 MOUNT_ARG=""
 FIRST=""

#create 500 empty directory for mapping drivers
#all of them will be deleted after
 for d in `seq 0 500` ; do
   DISK_PATH=${MOUNT_LINKS}/disk-${d}
   mkdir $DISK_PATH;
   MOUNT_ARG="${MOUNT_ARG}${FIRST}${DISK_PATH}=RW"
   FIRST=":"
 done 
 #log $MOUNT_ARG 
 #on alpine version se this
 unionfs -o cow,statfs_omit_ro,allow_other,suid,dev "$MOUNT_ARG" "$MOUNT_PATH" 
 #on ubuntu use this one
 #unionfs-fuse -o cow,statfs_omit_ro,allow_other,use_ino,suid,dev "$MOUNT_ARG" "$MOUNT_PATH"  
}

mount_drives(){
unionfs_fuse_mount_drives
}

umount_drives() {
 log "drive removed" 
 #fusermount
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
   DISK_INDEX=$((DISK_INDEX+1))
   LINK_NAME="disk-$DISK_INDEX"
   ln -s "$1" "$MOUNT_LINKS/$LINK_NAME" 
   hput "$1" "$LINK_NAME"
   log "create_disk_link for $1 in $MOUNT_LINKS/$LINK_NAME" 
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
log $hash_map

# wait for drive mount events
inotifywait -m -e moved_to -e create,delete "$MOUNT_USB_PATH"  | while read path action file 
do
   DRIVE_PATH=$path$file   
  
   case "$action" in
   "DELETE,ISDIR") 
      log "Drive Delted $DRIVE_PATH"    
      value=`hget "$DRIVE_PATH"`
      log "removing $MOUNT_LINKS/$value ..."
      #rm $MOUNT_LINKS/$value
   ;;
   "CREATE,ISDIR")  
      log "Drive Created $DRIVE_PATH" 
      value=`hget "$DRIVE_PATH"`
      if [ -z $value ]; then
         create_disk_link "$DRIVE_PATH"
      else
        log "drive exist $DRIVE_PATH"
        #ln -s "$DRIVE_PATH" "$MOUNT_LINKS/$value"
      fi
   ;;
esac
#log "hash map:"$hash_map
done
