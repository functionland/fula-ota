#!/usr/bin/env bash
#
# Copyright (C) 2023 Functionland
# SPDX-License-Identifier: MIT
#

set -e

cat <<"EOF"
  ___ _   _ _      _      ___ _____ _   
 | __| | | | |    /_\    / _ \_   _/_\  
 | _|| |_| | |__ / _ \  | (_) || |/ _ \ 
 |_|  \___/|____/_/ \_\  \___/ |_/_/ \_\

EOF

cat <<EOF
FULA OTA
===================================================
EOF

# Setup

SECOND_UPPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$SECOND_UPPER_DIR/blox-ota"

if [ $# -eq 2 ]; then
  DATA_DIR=$2
fi

CORE_VERSION="1.0.0"

echo "blox-linux.sh version $CORE_VERSION"
docker --version
docker-compose --version

echo ""

# Functions

function checkDataDirExists() {
  if [ ! -d "$DATA_DIR" ]; then
    echo "Cannot find a Fula OTA installation at $DATA_DIR."
    exit 1
  fi
}

function checkDataDirNotExists() {
  if [ -d "$DATA_DIR" ]; then
    echo "Looks like Fula OTA is already installed at $DATA_DIR."
    exit 1
  fi
}

function listCommands() {
  cat <<EOT
Available commands:
install
start
restart
stop
rebuild
help
EOT
}

# Commands

case $1 in
"install")
  checkDataDirNotExists
  mkdir -p $DATA_DIR
  $SCRIPTS_DIR/run.sh install $DATA_DIR
  ;;
"start" | "restart")
  checkDataDirExists
  $SCRIPTS_DIR/run.sh restart $DATA_DIR
  ;;
"stop")
  checkDataDirExists
  $SCRIPTS_DIR/run.sh stop $DATA_DIR
  ;;
"rebuild")
  checkDataDirExists
  $SCRIPTS_DIR/run.sh rebuild $DATA_DIR
  ;;
"help")
  listCommands
  ;;
*)
  echo "No command found."
  echo
  listCommands
  ;;
esac

# https://gist.github.com/mosquito/b23e1c1e5723a7fd9e6568e5cf91180f

#export CURRENT_USER=$(whoami)
#export MOUNT_PATH=/media/$CURRENT_USER

#mkdir -p /usr/share/fula/
##cp docker-compose.yaml
#cp fula.service /etc/systemd/system/fula.service
#systemctl enable fula.service
#systemctl start fula.service
#systemctl status fula.service

