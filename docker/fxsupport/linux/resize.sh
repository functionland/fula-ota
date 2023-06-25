#!/bin/sh

resize_flag=/usr/bin/fula/.resize_flg

#check if proxy.conf exist delete it
if test -f /etc/apt/apt.conf.d/proxy.conf; then sudo rm /etc/apt/apt.conf.d/proxy.conf; fi

resize_rootfs () {
  touch /usr/bin/fula/.resize_flg
  #sh /usr/lib/raspi-config/init_resize.sh
  if [ -d "/sys/module/rockchipdrm" ]; then
    echo "Running on RockChip. No action needed"
    exit 0
  else
    sudo raspi-config --expand-rootfs
    echo "Rootfs expanded..."
    sudo reboot
    exit 0
  fi
}

if [ -f "$resize_flag" ]; then
  echo "File exists. so no need to expand."
else
  resize_rootfs
fi
