#!/bin/bash

MOUNTPOINT="/media/pi"
DEVICE="/dev/$1"
MOUNTNAME=$(echo "$1" | sed 's/[^a-zA-Z0-9]//g')
mkdir -p "${MOUNTPOINT}/${MOUNTNAME}"

# Determine filesystem type
FSTYPE=$(blkid -o value -s TYPE "${DEVICE}" 2>/dev/null)

if [ -z "${FSTYPE}" ]; then
    echo "ERROR: Could not detect filesystem type on ${DEVICE}" >&2
    rmdir "${MOUNTPOINT}/${MOUNTNAME}" 2>/dev/null
    exit 1
fi

echo "Mounting ${DEVICE} (type: ${FSTYPE}) to ${MOUNTPOINT}/${MOUNTNAME}"

if [ "${FSTYPE}" = "ntfs" ]; then
    if ! mount -t ntfs -o uid=pi,gid=pi,dmask=0000,fmask=0000 "${DEVICE}" "${MOUNTPOINT}/${MOUNTNAME}"; then
        echo "ERROR: Failed to mount ${DEVICE} (ntfs) to ${MOUNTPOINT}/${MOUNTNAME}" >&2
        rmdir "${MOUNTPOINT}/${MOUNTNAME}" 2>/dev/null
        exit 1
    fi
elif [ "${FSTYPE}" = "vfat" ]; then
    if ! mount -t vfat -o uid=pi,gid=pi,dmask=0000,fmask=0000 "${DEVICE}" "${MOUNTPOINT}/${MOUNTNAME}"; then
        echo "ERROR: Failed to mount ${DEVICE} (vfat) to ${MOUNTPOINT}/${MOUNTNAME}" >&2
        rmdir "${MOUNTPOINT}/${MOUNTNAME}" 2>/dev/null
        exit 1
    fi
else
    if ! mount "${DEVICE}" "${MOUNTPOINT}/${MOUNTNAME}"; then
        echo "ERROR: Failed to mount ${DEVICE} (${FSTYPE}) to ${MOUNTPOINT}/${MOUNTNAME}" >&2
        rmdir "${MOUNTPOINT}/${MOUNTNAME}" 2>/dev/null
        exit 1
    fi
    chown pi:pi "${MOUNTPOINT}/${MOUNTNAME}"
fi

echo "Successfully mounted ${DEVICE} to ${MOUNTPOINT}/${MOUNTNAME}"
