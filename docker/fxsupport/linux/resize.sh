#!/bin/sh

force_partition="${1:-0}"

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

            # Unmount any mounted partitions on the device before formatting
            MOUNTED_PARTS=$(lsblk -lnp -o NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}')
            if [ ! -z "$MOUNTED_PARTS" ]; then
                echo "Unmounting partitions on $DEVICE..."
                for PART in $MOUNTED_PARTS; do
                    sudo umount "$PART" || {
                        echo "Failed to unmount $PART. Still proceeding."
                    }
                done
            fi
            printf "The device %s is not formatted. Formatting now..." "$DEVICE"
            printf "o\nn\np\n1\n\n\nw" | sudo fdisk "$DEVICE"
            sudo mkfs.ext4 -F "${DEVICE}1"
            printf "The device %s has been formatted." "$DEVICE"

            # Create a mount point, mount the partition, create a test file
            sudo mkdir -p "/mnt/${DEVICE}1"
            sudo mount "${DEVICE}1" "/mnt/${DEVICE}1"
            sudo touch "/mnt/${DEVICE}1/formatted.txt"
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

       # Unmount any mounted partitions on the device before formatting
      MOUNTED_PARTS=$(lsblk -lnp -o NAME,MOUNTPOINT "$DEVICE" | awk '$2 != "" {print $1}')
      if [ ! -z "$MOUNTED_PARTS" ]; then
          echo "Unmounting partitions on $DEVICE..."
          for PART in $MOUNTED_PARTS; do
              sudo umount "$PART" || {
                  echo "Failed to unmount $PART. Still proceeding."
              }
          done
      fi
      printf "The device %s is not formatted. Formatting now..." "$DEVICE"
      printf "g\nn\n\n\n\nw" | sudo fdisk "$DEVICE"
      sudo mkfs.ext4 -F ${DEVICE}p1
      printf "The device %s has been formatted." "$DEVICE"

      # Create a mount point, mount the partition, create a test file
      sudo mkdir -p "/mnt/${DEVICE}p1"
      sudo mount "${DEVICE}p1" "/mnt/${DEVICE}p1"
      sudo touch "/mnt/${DEVICE}p1/formatted.txt"
  else
      echo "The device is formatted."
  fi
}

resize_flag=/usr/bin/fula/.resize_flg
partition_flag=/usr/bin/fula/.partition_flg

#check if proxy.conf exist delete it
if test -f /etc/apt/apt.conf.d/proxy.conf; then sudo rm /etc/apt/apt.conf.d/proxy.conf; fi

resize_rootfs () {
  if [ -d "/sys/module/rockchipdrm" ]; then
    echo "Running on RockChip."

    sudo /usr/lib/armbian/armbian-resize-filesystem start
    echo "Rootfs expanded..."
    
    python /usr/bin/fula/control_led.py blue 2
    touch /usr/bin/fula/.resize_flg
    sudo reboot
    exit 0
  else
    echo "Not running on RockChip."
    sudo raspi-config --expand-rootfs
    echo "Rootfs expanded..."
    python /usr/bin/fula/control_led.py blue 2
    touch /usr/bin/fula/.resize_flg
    sudo reboot
    exit 0
  fi
}

partition_fs () {
  force_format="$1"
  if [ -d "/sys/module/rockchipdrm" ]; then
    format_sd_devices "$force_format" || { echo "Failed to format nvme"; }
    format_nvme "$force_format" || { echo "Failed to format nvme"; }
    touch /usr/bin/fula/.partition_flg
    python /usr/bin/fula/control_led.py blue 2
    sudo reboot
    exit 0
  else
    touch /usr/bin/fula/.partition_flg
    python /usr/bin/fula/control_led.py green 3
    exit 0
  fi
}

if [ -f "$resize_flag" ]; then
  echo "File exists. so no need to expand."
  if [ -f "$partition_flag" ]; then
    echo "Partition exists. so no need to parition."
    python /usr/bin/fula/control_led.py green 3
  else
    partition_fs "$force_partition"
  fi
else
  resize_rootfs
fi
