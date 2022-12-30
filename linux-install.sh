#!/bin/bash

# https://gist.github.com/mosquito/b23e1c1e5723a7fd9e6568e5cf91180f

export CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

mkdir -p /usr/share/fula/
cp docker-compose.yaml
cp fula.service /etc/systemd/system/fula.service
systemctl enable fula.service
systemctl start fula.service

systemctl status fula.service

