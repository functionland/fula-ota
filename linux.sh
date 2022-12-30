#!/bin/bash

export MOUNT_PATH=/media/$(whoami)

docker-compose up -d --remove-orphans