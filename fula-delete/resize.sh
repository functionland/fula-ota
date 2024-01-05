#!/bin/sh

format_sd_devices() {
    for DEVICE in $(lsblk -dpno NAME | grep '^/dev/sd'); do
        PARTITIONS=$(sudo fdisk -l "$DEVICE" | grep "^${DEVICE}[0-9]*")
        if [ -z "$PARTITIONS" ]; then
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
  DEVICE="/dev/nvme0n1"
  PARTITIONS=$(sudo fdisk -l $DEVICE | grep "^${DEVICE}p[0-9]*")
  if [ -z "$PARTITIONS" ]; then
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
  if [ -d "/sys/module/rockchipdrm" ]; then
    format_sd_devices || { echo "Failed to format nvme"; }
    format_nvme || { echo "Failed to format nvme"; }
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
    partition_fs
  fi
else
  resize_rootfs
fi
