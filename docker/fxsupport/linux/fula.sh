#!/usr/bin/env bash
#
# Copyright (C) 2023 functionland
# SPDX-License-Identifier: AGPL-3.0-only
#
# Adapted UID parsing logic - Line 31-40
#

set -e

# Setup

CYAN='\033[0;36m'
NC='\033[0m' # No Color


FULA_PATH=/usr/bin/fula
SYSTEMD_PATH=/etc/systemd/system
HW_CHECK_SC=$FULA_PATH/hw_test.py
RESIZE_SC=$FULA_PATH/resize.sh

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR=$DIR
if [ $# -gt 1 ]; then
  DATA_DIR=$2
fi

ENV_FILE="$DIR/docker.env"
DOCKER_DIR=$DIR

export CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

# Determine default host machine IP address
IP_ADDRESS=$(ip route get 1 | awk '{print $7}' | head -1)

check_internet() {
  wget -q --spider --timeout=10 https://www.google.com

  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

service_exists() {
    local n=$1
    if [[ $(systemctl list-units --all -t service --full --no-legend "$n.service" | sed 's/^\s*//g' | cut -f1 -d' ') == $n.service ]]; then
        return 0
    else
        return 1
    fi
}

# Functions
function install() {
  dockerComposeBuild
  echo "Installing Fula ..."
  mkdir -p $FULA_PATH/
  cp fula.sh $FULA_PATH/
  cp docker.env $FULA_PATH/
  cp docker-compose.yml $FULA_PATH/  
  cp fula.service $SYSTEMD_PATH/
  
  cp hw_test.py $FULA_PATH/
  cp resize.sh $FULA_PATH/
  chmod +x $FULA_PATH/fula.sh $FULA_PATH/hw_test.py $FULA_PATH/resize.sh
  
  systemctl daemon-reload
  systemctl enable fula.service
  systemctl start fula.service
  echo "Installing Fula Finished"
}

function dockerComposeUp() {
  update()
  docker-compose -f $DOCKER_DIR/docker-compose.yml  --env-file $ENV_FILE up -d --force-recreate
}

function dockerComposeDown() {
  if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE ps | wc -l) -gt 2 ]; then
    echo 'Shutting down existing deployment'
    docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE down
  fi
}

function dockerComposeBuild() {
  docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE pull
  docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE build --no-cache
}


function createDir() {
  if [ ! -d "${DATA_DIR}/$1" ]; then
    echo "Creating directory for docker volume $DATA_DIR/$1"
    mkdir -p $DATA_DIR/$1
  fi
}

function dockerPrune() {
  docker image prune --all --force
}

function restart() {
  if [ -f "$HW_CHECK_SC" ]; then
     python $HW_CHECK_SC
  fi
  if [ -f "$RESIZE_SC" ]; then
     sh $RESIZE_SC
  fi
  dockerComposeDown
  dockerComposeUp
}

function remove()
{
  
  echo "Removing Fula ..."
  if service_exists fula.service; then
  	systemctl stop fula.service -q
  	systemctl disable fula.service -q
  fi
  rm -f $SYSTEMD_PATH/fula.service 
  rm -rf $FULA_PATH/
  systemctl daemon-reload
  dockerPrune
  echo "Removing Fula Finished"
}

function rebuild() {
  remove
  install 
}

function update() {
  if check_internet; then
    docker-compose -f $DOCKER_DIR/docker-compose.yml  --env-file $ENV_FILE pull
  else
    echo "You are not connected to internet!"
    echo "Please check your connection"
  fi
}




# Commands
case $1 in
"install")
  install
  ;;
"start" | "restart")
  restart
  docker cp fula_fxsupport:/linux/. /usr/bin/fula/
  sync
  ;;
"stop")
  dockerComposeDown
  ;;
"rebuild")
  rebuild
  ;;
"removeall")
  docker rm -f $(docker ps -a -q)
  remove
   ;;
"update")
  update
   ;;
esac
