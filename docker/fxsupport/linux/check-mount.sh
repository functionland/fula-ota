#!/bin/bash

# Directory where devices will be mounted
MOUNTPOINT_BASE="/media/pi"

# Function to mount a device
mount_device() {
    local DEVICE=$1
    local MOUNTPOINT="${MOUNTPOINT_BASE}/${DEVICE}"

    echo "Mounting ${DEVICE} at ${MOUNTPOINT}..."
    /usr/local/bin/automount.sh "${DEVICE}" &> /dev/null
}

# List all unmounted sd[a-z][0-9] devices and mount each one
while IFS= read -r line; do
    # Extract the device name
    DEVICE=$(awk '{print $1}' <<< "$line")

    mount_device "$DEVICE" &
done < <(lsblk -nr -o NAME,MOUNTPOINT | awk '/^sd[a-z][0-9] / && $2 == ""')

wait # Wait for all background processes to finish
