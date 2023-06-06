#!/bin/bash

FULA_LOG_PATH=/home/pi/fula.sh.log

# Get a list of USB devices
mapfile -t devices < <(for id in /dev/disk/by-id/*; do
    if echo "$id" | grep -Eq 'usb.*-part.*'; then
        device_path=$(readlink -f "$id")
        echo "$device_path"
    fi
done)

for device in "${devices[@]}"; do
    # Create a temporary mountpoint
    mountpoint=$(mktemp -d)

    # Mount the device to the mountpoint
    sudo mount "$device" "$mountpoint"

    # Check if the update file exists on this device
    if [ -f "$mountpoint/fula_update/update.yaml" ]; then
        python /usr/bin/fula/control_led.py blue -1 > $FULA_LOG_PATH 2>&1 &
        python /usr/bin/fula/control_led.py blue 100 > $FULA_LOG_PATH 2>&1 &
        sudo systemctl stop fula
        sudo cp -r "$mountpoint/fula_update/fula"/* /usr/bin/fula
        sudo cp -r "$mountpoint/fula_update/fula"/* /home/pi/fula-ota
        sudo cp /home/pi/fula.sh.log* "$mountpoint/fula_update/"
        sudo chmod +x /usr/bin/fula/*.sh
        sudo chmod +x /home/pi/fula-ota/*.sh
        date | sudo tee -a /home/pi/stop_docker_copy.txt > /dev/null
        cd /usr/bin/fula || exit
        
        mv "$mountpoint/fula_update/update.yaml" "$mountpoint/fula_update/update.completed.yaml"
        sudo bash ./fula.sh install
        sudo umount "$mountpoint"
        python /usr/bin/fula/control_led.py blue -1 > $FULA_LOG_PATH 2>&1 &
        sudo pkill -f "control_led.py"
        sudo reboot
    fi

    # Cleanup: unmount the device and remove the temporary mountpoint
    sudo umount "$mountpoint"
    rmdir "$mountpoint"
done
