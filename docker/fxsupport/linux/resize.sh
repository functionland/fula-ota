#!/bin/sh
HOME_DIR=/home/pi
FULA_LOG_PATH=$HOME_DIR/fula.sh.log

force_partition="${1:-0}"
services_stopped=0
services_started=0

cleanup() {
    echo "An error occurred. Starting services before exiting."
    if [ -f $HOME_DIR/control_led.per ]; then
        sudo rm $HOME_DIR/control_led.per
    fi
    if [ -f /usr/bin/fula/control_led.py ]; then
        python /usr/bin/fula/control_led.py red 999999 --persist &
    fi
    exit 1  # Exit with an error status
}

# Trap any script exit and call cleanup
trap cleanup EXIT

if [ -f $HOME_DIR/control_led.per ]; then
    sudo rm $HOME_DIR/control_led.per 2>&1 | sudo tee -a $FULA_LOG_PATH
fi

# Function to stop services
stop_services() {
    if [ "$services_stopped" -eq 0 ]; then
        services_stopped=1
        echo "Stopping services..."
        python /usr/bin/fula/control_led.py light_purple 999999 --persist &
        sudo systemctl stop fula.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error stop fula.service" 2>&1 | sudo tee -a $FULA_LOG_PATH; } || true
        echo "Fula service stopped..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl stop uniondrive.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error stop uniondrive.service" 2>&1 | sudo tee -a $FULA_LOG_PATH; } || true
        echo "uniondrive service stopped..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        # sudo systemctl stop commands.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error stop commands.service" 2>&1 | sudo tee -a $FULA_LOG_PATH; } || true
        # echo "commands service stopped..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl stop cron.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error stop cron.service" 2>&1 | sudo tee -a $FULA_LOG_PATH; } || true
        echo "cron service stopped..." 2>&1 | sudo tee -a $FULA_LOG_PATH
    fi
}

# Function to start services
start_services() {
    error="${1:-0}"
    if [ "$services_started" -eq 0 ]; then
        if [ -f $HOME_DIR/control_led.per ]; then
            sudo rm $HOME_DIR/control_led.per 2>&1 | sudo tee -a $FULA_LOG_PATH
        fi
        if [ -f /usr/bin/fula/control_led.py ]; then
            python /usr/bin/fula/control_led.py light_purple 0 2>&1 | sudo tee -a $FULA_LOG_PATH
        fi
        echo "Starting services..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl enable uniondrive.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl start uniondrive.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        echo "uniondrive service started..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl enable fula.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl start fula.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        echo "fula service started..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo rm -rf "$HOME_DIR/commands/*" 2>&1 | sudo tee -a $FULA_LOG_PATH
        # sudo systemctl start commands.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        # echo "commands service started..." 2>&1 | sudo tee -a $FULA_LOG_PATH
         sudo systemctl enable cron.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo systemctl start cron.service 2>&1 | sudo tee -a $FULA_LOG_PATH
        echo "cron service started..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo sync
        if [ "$error" -eq 1 ]; then
            # If an error occurred, indicate with red light
            if [ -f /usr/bin/fula/control_led.py ]; then
                python /usr/bin/fula/control_led.py red 10 2>&1 | sudo tee -a $FULA_LOG_PATH
            fi
        else
            # No error, proceed with light_purple or as originally planned
            if [ -f /usr/bin/fula/control_led.py ]; then
                python /usr/bin/fula/control_led.py yellow 10 2>&1 | sudo tee -a $FULA_LOG_PATH
            fi
        fi
        services_started=1
        trap - EXIT
        sudo reboot
    fi
}

format_storage_devices() {
    type="$1"  # The type of device to format ('sd' or 'nvme')
    force="$2"
    # Determine the list of devices to format based on the type
    DEVICELIST=''
    PARTITION_SUFFIX=''
    if [ "$type" = "sd" ]; then
        DEVICELIST=$(lsblk -dpno NAME | grep '^/dev/sd')
        PARTITION_SUFFIX='1'
    elif [ "$type" = "nvme" ]; then
        DEVICELIST='/dev/nvme0n1'
        PARTITION_SUFFIX='p1'
    else
        echo "Invalid device type specified."
        return 1  # Exit the function with an error
    fi
    for DEVICE in $DEVICELIST; do
        if [ ! -e "$DEVICE" ]; then
            echo "The device $DEVICE does not exist." 2>&1 | sudo tee -a $FULA_LOG_PATH
            continue  # Skip to the next device
        fi
        sudo docker stop fula_go 2>&1 | sudo tee -a $FULA_LOG_PATH | true
        if sudo docker ps -a --format "table {{.Names}}" | grep -q "^fula_node$"; then
            sudo docker stop fula_node 2>&1 | sudo tee -a $FULA_LOG_PATH | true
        fi
        sudo docker stop ipfs_cluster 2>&1 | sudo tee -a $FULA_LOG_PATH | true
        sudo docker stop ipfs_host 2>&1 | sudo tee -a $FULA_LOG_PATH | true
        PARTITIONS=$(sudo fdisk -l "$DEVICE" | grep "^${DEVICE}[0-9]*")
        if [ -z "$PARTITIONS" ] || [ "$force" -eq 1 ]; then
            echo "The device $DEVICE is not formatted or force format is requested. Formatting now..." 2>&1 | sudo tee -a $FULA_LOG_PATH
            stop_services 2>&1 | sudo tee -a $FULA_LOG_PATH

            # Unmount any mounted partitions on the device before formatting
            MOUNTED_PARTS=$(lsblk -lnp -o NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}')
            if [ -n "$MOUNTED_PARTS" ]; then
                echo "Unmounting partitions on $DEVICE..." 2>&1 | sudo tee -a $FULA_LOG_PATH
                for PART in $MOUNTED_PARTS; do
                    PART_NAME=$(basename "$PART")
                    SERVICE_NAME="automount@${PART_NAME}.service"

                    echo "Stopping service $SERVICE_NAME..." 2>&1 | sudo tee -a $FULA_LOG_PATH
                    sudo systemctl stop "$SERVICE_NAME" 2>&1 | sudo tee -a $FULA_LOG_PATH
                    if sudo umount "$PART"; then
                        echo "Unmounted $PART successfully." 2>&1 | sudo tee -a $FULA_LOG_PATH
                        # Check if the mount point directory exists and is empty before removing
                        if [ -d "$PART" ] && [ -z "$(ls -A "$PART")" ]; then
                            echo "Removing mount point directory $PART." 2>&1 | sudo tee -a $FULA_LOG_PATH
                            sudo rm -r "$PART"
                        else
                            echo "$PART is not empty or does not exist as a directory." 2>&1 | sudo tee -a $FULA_LOG_PATH
                        fi
                    else
                        echo "Failed to unmount $PART. Attempting to kill processes using it." 2>&1 | sudo tee -a $FULA_LOG_PATH
                        sudo fuser -km "$PART" 2>&1 | sudo tee -a $FULA_LOG_PATH
                        sleep 2  # Give some time for processes to terminate
                        if sudo umount "$PART"; then
                            echo "Unmounted $PART after killing processes." 2>&1 | sudo tee -a $FULA_LOG_PATH
                            # Check again before attempting to remove
                            if [ -d "$PART" ] && [ -z "$(ls -A "$PART")" ]; then
                                echo "Removing mount point directory $PART." 2>&1 | sudo tee -a $FULA_LOG_PATH
                                sudo rm -r "$PART" 2>&1 | sudo tee -a $FULA_LOG_PATH
                            else
                                echo "$PART is not empty or does not exist as a directory." 2>&1 | sudo tee -a $FULA_LOG_PATH
                            fi
                        else
                            echo "Still could not unmount $PART. Not removing $PART." 2>&1 | sudo tee -a $FULA_LOG_PATH
                        fi
                    fi
                    sudo sync
                done
            fi
            DEVICE_PATH=$(basename "${DEVICE}${PARTITION_SUFFIX}")
            echo "The device $DEVICE is not formatted. Formatting now..." 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo umount "/media/pi/${DEVICE_PATH}" 2>&1 | sudo tee -a $FULA_LOG_PATH | true
            sudo sfdisk --delete "$DEVICE" 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo parted --script "$DEVICE" mklabel gpt 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo parted -a optimal "$DEVICE" mkpart primary ext4 "0%" "100%" 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo umount "/media/pi/${DEVICE_PATH}" 2>&1 | sudo tee -a $FULA_LOG_PATH | true
            sudo mkfs.ext4 -F "${DEVICE}${PARTITION_SUFFIX}" 2>&1 | sudo tee -a $FULA_LOG_PATH
            echo "The device $DEVICE has been formatted."

            # Create a mount point, mount the partition, create a test file
            sudo mkdir -p "/media/pi/${DEVICE_PATH}" 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo chown pi:pi "/media/pi/${DEVICE_PATH}" 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo chmod 777 "/media/pi/${DEVICE_PATH}" 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo mount "${DEVICE}${PARTITION_SUFFIX}" "/media/pi/${DEVICE_PATH}" 2>&1 | sudo tee -a $FULA_LOG_PATH
            sudo touch "/media/pi/${DEVICE_PATH}/formatted${DEVICE_PATH}.txt" 2>&1 | sudo tee -a $FULA_LOG_PATH
            trap - EXIT
            start_services 0
        else
            echo "The device $DEVICE is already formatted." 2>&1 | sudo tee -a $FULA_LOG_PATH
        fi
    done
}

resize_flag=/usr/bin/fula/.resize_flg
partition_flag=/usr/bin/fula/.partition_flg

#check if proxy.conf exist delete it
if test -f /etc/apt/apt.conf.d/proxy.conf; then sudo rm /etc/apt/apt.conf.d/proxy.conf; fi

resize_rootfs () {
  python /usr/bin/fula/control_led.py light_purple 999999 --persist &
  if [ -d "/sys/module/rockchipdrm" ]; then
    echo "Running on RockChip."

    sudo /usr/lib/armbian/armbian-resize-filesystem start
    echo "Rootfs expanded..."
    if [ -f $HOME_DIR/control_led.per ]; then
        sudo rm $HOME_DIR/control_led.per
    fi
    if [ -f /usr/bin/fula/control_led.py ]; then
        python /usr/bin/fula/control_led.py yellow 20 &
    fi
    sudo touch "${resize_flag}"
    sudo reboot
    exit 0
  else
    echo "Not running on RockChip."
    sudo raspi-config --expand-rootfs
    echo "Rootfs expanded..."
    if [ -f $HOME_DIR/control_led.per ]; then
        sudo rm $HOME_DIR/control_led.per
    fi
    if [ -f /usr/bin/fula/control_led.py ]; then
        python /usr/bin/fula/control_led.py yellow 20 &
    fi
    sudo touch "${resize_flag}"
    sudo reboot
    exit 0
  fi
}

partition_fs () {
  force_format="$1"
  if [ -d "/sys/module/rockchipdrm" ]; then
    format_storage_devices "sd" "$force_format" || { echo "Failed to format sd"; } || true
    format_storage_devices "nvme" "$force_format" || { echo "Failed to format nvme"; } || true
    trap - EXIT
    sudo touch "${partition_flag}"
    exit 0
  else
    format_storage_devices "sd" "$force_format" || { echo "Failed to format sd"; } || true
    format_storage_devices "nvme" "$force_format" || { echo "Failed to format nvme"; } || true
    trap - EXIT
    sudo touch "${partition_flag}"
    exit 0
  fi
}

if [ "$force_partition" -eq 1 ]; then
    # Replace `your_command_here` with the command you want to run
    echo "Force partition is set to 1. Running the specified command..."
    partition_fs "$force_partition"
fi

if [ -f "$resize_flag" ]; then
  echo "File exists. so no need to expand." 2>&1 | sudo tee -a $FULA_LOG_PATH
  if [ -f "$partition_flag" ]; then
    echo "Partition exists. so no need to parition." 2>&1 | sudo tee -a $FULA_LOG_PATH
    trap - EXIT
    exit 0
  else
    echo "partitioning with force=$force_partition"
    partition_fs "$force_partition"
  fi
else
  resize_rootfs
fi
