#!/bin/bash

MOUNTPOINT="/media/pi"
DEVICE="/dev/$1"
MOUNTNAME=$(echo $1 | sed 's/[^a-zA-Z0-9]//g')
mkdir -p ${MOUNTPOINT}/${MOUNTNAME}
    
# Determine filesystem type
FSTYPE=$(blkid -o value -s TYPE ${DEVICE})
    
if [ ${FSTYPE} = "ntfs" ]; then
    # If filesystem is NTFS
    # uid and gid specify the owner and the group of files. 
    # dmask and fmask control the permissions for directories and files. 0000 gives everyone read and write access.
    mount -t ntfs -o uid=pi,gid=pi,dmask=0000,fmask=0000 ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
elif [ ${FSTYPE} = "vfat" ]; then
    # If filesystem is FAT32
    mount -t vfat -o uid=pi,gid=pi,dmask=0000,fmask=0000 ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
else
    # For other filesystem types
    mount ${DEVICE} ${MOUNTPOINT}/${MOUNTNAME}
    # Changing owner for non-NTFS and non-FAT32 filesystems
    chown pi:pi ${MOUNTPOINT}/${MOUNTNAME}
fi