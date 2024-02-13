#!/bin/sh
HOME_DIR=/home/pi
force_partition="${1:-0}"
services_stopped=0
services_started=0

if [ -f $HOME_DIR/control_led.per ]; then
    sudo rm $HOME_DIR/control_led.per
fi

# Function to stop services
stop_services() {
    if [ "$services_stopped" -eq 0 ]; then
        echo "Stopping services..."
        python /usr/bin/fula/control_led.py light_purple 999999 --persist &
        sudo systemctl stop fula.service
        echo "Fula service stopped..."
        sudo systemctl stop uniondrive.service
        echo "uniondrive service stopped..."
        sudo systemctl stop commands.service
        echo "commands service stopped..."
        services_stopped=1
    fi
}

# Function to start services
start_services() {
    if [ "$services_started" -eq 0 ]; then
        echo "Starting services..."
        sudo systemctl start uniondrive.service
        echo "uniondrive service started..."
        sudo systemctl start fula.service
        echo "fula service started..."
        sudo rm -rf "$HOME_DIR/commands/*"
        sudo systemctl start commands.service
        echo "commands service stopped..."
        if [ -f $HOME_DIR/control_led.per ]; then
            sudo rm $HOME_DIR/control_led.per
        fi
        if [ -f /usr/bin/fula/control_led.py ]; then
            python /usr/bin/fula/control_led.py yellow 30 &
        fi
        services_started=1
    fi
}

format_sd_devices() {
    force="$1"
    for DEVICE in $(lsblk -dpno NAME | grep '^/dev/sd'); do
        if [ ! -e "$DEVICE" ]; then
            echo "The device $DEVICE does not exist."
            continue  # Skip to the next device
        fi
        PARTITIONS=$(sudo fdisk -l "$DEVICE" | grep "^${DEVICE}[0-9]*")
        if [ -z "$PARTITIONS" ] || [ "$force" -eq 1 ]; then
            echo "The device $DEVICE is not formatted or force format is requested. Formatting now..."
            stop_services

            # Unmount any mounted partitions on the device before formatting
            MOUNTED_PARTS=$(lsblk -lnp -o NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}')
            if [ ! -z "$MOUNTED_PARTS" ]; then
                echo "Unmounting partitions on $DEVICE..."
                for PART in $MOUNTED_PARTS; do
                    PART_NAME=$(basename "$PART")
                    SERVICE_NAME="automount@${PART_NAME}.service"

                    echo "Stopping service $SERVICE_NAME..."
                    sudo systemctl stop "$SERVICE_NAME"
                    if sudo umount "$PART"; then
                        echo "Unmounted $PART successfully."
                        # Check if the mount point directory exists and is empty before removing
                        if [ -d "$PART" ] && [ -z "$(ls -A "$PART")" ]; then
                            echo "Removing mount point directory $PART."
                            sudo rm -r "$PART"
                        else
                            echo "$PART is not empty or does not exist as a directory."
                        fi
                    else
                        echo "Failed to unmount $PART. Attempting to kill processes using it."
                        sudo fuser -km "$PART"
                        sleep 2  # Give some time for processes to terminate
                        if sudo umount "$PART"; then
                            echo "Unmounted $PART after killing processes."
                            # Check again before attempting to remove
                            if [ -d "$PART" ] && [ -z "$(ls -A "$PART")" ]; then
                                echo "Removing mount point directory $PART."
                                sudo rm -r "$PART"
                            else
                                echo "$PART is not empty or does not exist as a directory."
                            fi
                        else
                            echo "Still could not unmount $PART. Not removing $PART."
                        fi
                    fi
                    sudo sync
                done
            fi
            printf "The device %s is not formatted. Formatting now..." "$DEVICE"
            printf "o\nn\np\n1\n\n\nw" | sudo fdisk "$DEVICE"
            sudo mkfs.ext4 -F "${DEVICE}1"
            printf "The device %s has been formatted." "$DEVICE"

            # Create a mount point, mount the partition, create a test file
            DEVICE_PATH=$(basename "${DEVICE}1")
            sudo mkdir -p "/media/pi/${DEVICE_PATH}"
            sudo chown pi:pi "/media/pi/${DEVICE_PATH}"
            sudo chmod 777 "/media/pi/${DEVICE_PATH}"
            sudo mount "${DEVICE}1" "/media/pi/${DEVICE_PATH}"
            sudo touch "/media/pi/${DEVICE_PATH}/formatted${DEVICE_PATH}.txt"
            sudo sync
            start_services
            sleep 1
            sudo reboot
        else
            printf "The device %s is already formatted." "$DEVICE"
        fi
    done
}

format_nvme() {
  force="$1"
  DEVICE="/dev/nvme0n1"
  if [ ! -e "$DEVICE" ]; then
      echo "The NVMe device $DEVICE does not exist."
      return  # Exit the function
  fi
  PARTITIONS=$(sudo fdisk -l $DEVICE | grep "^${DEVICE}p[0-9]*")
  if [ -z "$PARTITIONS" ] || [ "$force" -eq 1 ]; then
      echo "The device $DEVICE is not formatted or force format is requested. Formatting now..."
      stop_services

       # Unmount any mounted partitions on the device before formatting
      MOUNTED_PARTS=$(lsblk -lnp -o NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}')
      if [ ! -z "$MOUNTED_PARTS" ]; then
          echo "Unmounting partitions on $DEVICE..."
          for PART in $MOUNTED_PARTS; do
              PART_NAME=$(basename "$PART")
              SERVICE_NAME="automount@${PART_NAME}.service"

              echo "Stopping service $SERVICE_NAME..."
              sudo systemctl stop "$SERVICE_NAME"
              if sudo umount "$PART"; then
                  echo "Unmounted $PART successfully."
                  # Check if the mount point directory exists and is empty before removing
                  if [ -d "$PART" ] && [ -z "$(ls -A "$PART")" ]; then
                      echo "Removing mount point directory $PART."
                      sudo rm -r "$PART"
                  else
                      echo "$PART is not empty or does not exist as a directory."
                  fi
              else
                  echo "Failed to unmount $PART. Attempting to kill processes using it."
                  sudo fuser -km "$PART"
                  sleep 2  # Give some time for processes to terminate
                  if sudo umount "$PART"; then
                      echo "Unmounted $PART after killing processes."
                      # Check again before attempting to remove
                      if [ -d "$PART" ] && [ -z "$(ls -A "$PART")" ]; then
                          echo "Removing mount point directory $PART."
                          sudo rm -r "$PART"
                      else
                          echo "$PART is not empty or does not exist as a directory."
                      fi
                  else
                      echo "Still could not unmount $PART. Not removing $PART."
                  fi
              fi
              sudo sync
          done
      fi
      printf "The device %s is not formatted. Formatting now..." "$DEVICE"
      printf "g\nn\n\n\n\nw" | sudo fdisk "$DEVICE"
      sudo mkfs.ext4 -F ${DEVICE}p1
      printf "The device %s has been formatted." "$DEVICE"

      # Create a mount point, mount the partition, create a test file
      DEVICE_PATH=$(basename "${DEVICE}p1")
      sudo mkdir -p "/media/pi/${DEVICE_PATH}"
      sudo chown pi:pi "/media/pi/${DEVICE_PATH}"
      sudo chmod 777 "/media/pi/${DEVICE_PATH}"
      sudo mount "${DEVICE}p1" "/media/pi/${DEVICE_PATH}"
      sudo touch "/media/pi/${DEVICE_PATH}/formatted${DEVICE_PATH}.txt"
      sudo sync
      start_services
      sleep 1
      sudo reboot
  else
      echo "The device is formatted."
  fi
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
    format_sd_devices "$force_format" || { echo "Failed to format nvme"; } || true
    format_nvme "$force_format" || { echo "Failed to format nvme"; } || true
    sudo touch "${partition_flag}"
    exit 0
  else
    sudo touch "${partition_flag}"
    exit 0
  fi
}

if [ -f "$resize_flag" ]; then
  echo "File exists. so no need to expand."
  if [ -f "$partition_flag" ]; then
    echo "Partition exists. so no need to parition."
  else
    partition_fs "$force_partition"
  fi
else
  resize_rootfs
fi
