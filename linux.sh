#!/bin/bash

export CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

docker-compose build
docker-compose up -d --remove-orphans