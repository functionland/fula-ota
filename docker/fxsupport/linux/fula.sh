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
WIFI_SC=$FULA_PATH/wifi.sh

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

function check_internet() {
  wget -q --spider --timeout=10 https://www.google.com
  return $?   # Return the status directly, no need for if/else.
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
  echo "Installing Fula ..."
  echo "Pulling Images..."
  dockerPull
  echo "Building Images..."
  dockerComposeBuild

  echo "Copying Files..."
  mkdir -p $FULA_PATH/
  cp fula.sh $FULA_PATH/
  cp docker.env $FULA_PATH/
  cp docker-compose.yml $FULA_PATH/
  cp fula.service $SYSTEMD_PATH/

  cp hw_test.py $FULA_PATH/
  cp resize.sh $FULA_PATH/
  cp wifi.sh $FULA_PATH/
  chmod +x $FULA_PATH/fula.sh $FULA_PATH/hw_test.py $FULA_PATH/resize.sh
  chmod +x $FULA_PATH/wifi.sh

  echo "Installing Services..."
  systemctl daemon-reload
  systemctl enable fula.service
  echo "Installing Fula Finished"
}

function dockerPull() {
  if check_internet; then
    echo "Start polling images..."
    if [ -z "$1" ]; then
      echo "Full Image Updating..."
      docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE pull
    else
      . $ENV_FILE
      echo "Updating fxsupport ($FX_SUPPROT)..."
      if ! docker pull $FX_SUPPROT; then
        echo "failed to pull fx_support"
      fi
    fi
  else
    echo "You are not connected to internet!"
    echo "Please check your connection"
  fi
}

function dockerComposeUp() {
  dockerPull fxsupport
  echo "compsing up images..."
  if ! docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE up -d --no-recreate; then
    echo "failed to start some images"
    pullFailedServices &
    echo "pull pid is" $!
  fi

  # Check internet connection and setup WiFi if needed
  if [ -f "$WIFI_SC" ]; then
    if ! check_internet; then
      sh $WIFI_SC || { echo "Wifi setup failed"; exit 1; }
    fi
  fi
}

function dockerComposeDown() {
  killPullImage
  if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE ps | wc -l) -gt 2 ]; then
    echo 'Shutting down existing deployment'
    docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE down --remove-orphans
  fi
}

function dockerComposeBuild() {
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
    python $HW_CHECK_SC || { echo "Hardware check failed"; exit 1; }
  fi
  if [ -f "$RESIZE_SC" ]; then
    sh $RESIZE_SC || { echo "Resize failed"; exit 1; }
  fi

  dockerComposeDown
  dockerComposeUp

  # Remove dangling images
  if docker image prune --filter="dangling=true" -f; then
    echo "pruning unused dockers..."
  fi
}

function remove() {
  echo "Removing Fula ..."
  killPullImage
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

# Define the default interval between checks (in seconds)
DEFAULT_INTERVAL=360
# Define the default maximum number of attempts
DEFAULT_MAX_ATTEMPTS=10

function pullFailedServices() {
  SERVICES=$(docker-compose --env-file "$ENV_FILE" config --services)
  while :; do
    for service in $SERVICES; do
      # # Check if the service is running
      if ! status=$(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" ps -q $service | xargs docker inspect --format='{{.State.Status}}' 2>/dev/null) || [[ $status != "running" ]]; then

        # Pull the latest image
        if check_internet; then
          echo "Start polling $service images..."
          if [ -s "$1" ]; then
            echo "Pulling $service"
            if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull $service) ]; then
                echo "pulling $service"
            else
                echo "failed to get $service"
            fi
          fi
        fi
      fi
    done

    attempts=$(($attempts + 1))
    if [ $attempts -ge $DEFAULT_MAX_ATTEMPTS ]; then
      echo "Maximum number of attempts reached for service $service. Exiting..."
      break 1
    fi
    # Wait before checking again
    echo "Next Time Will be " $DEFAULT_INTERVAL " Seconds Later..."
    sleep $DEFAULT_INTERVAL
  done
}

function killPullImage() {
  if [ -f /var/run/fula.pid ] && [ ! -s /var/run/fula.pid ] ; then
     echo "Process already running."
     kill -9 `cat /var/run/fula.pid`
     rm -f /var/run/fula.pid
     echo `pidof $$` > /var/run/fula.pid
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
  containers=$(docker ps -a -q)
  if [ -n "$containers" ]; then
      docker rm -f $containers
  else
      echo "No containers to remove"
  fi
  remove
  ;;
"update")
  dockerPull "${@:2}"
  ;;
"pull-failed")
  pullFailedServices
  ;;
esac
