#!/bin/sh

resize_flag=/usr/bin/fula/.resize_flg

resize_rootfs () {
  touch /usr/bin/fula/.resize_flg
  sh /usr/lib/raspi-config/init_resize.sh
  exit 0
}

if [ -f "$resize_flag" ]; then
  echo "File exists. so no need to expand."
else
  resize_rootfs
fi
