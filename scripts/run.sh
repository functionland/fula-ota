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

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR=".."
if [ $# -gt 1 ]; then
  DATA_DIR=$2
fi

ENV_DIR="$DATA_DIR/env"
DOCKER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../docker" && pwd)"
PORTAL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

# Ensure net-tools exists
echo "Upading Packages ..."
#sudo apt-get update -qq >/dev/null
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq net-tools >/dev/null

# Determine default host machine IP address
IP_ADDRESS=$(ip route get 1 | awk '{print $7}' | head -1)

# Initialize UID/GID which will be used to run services from within containers
if ! grep -q "^LOCAL_UID=" $ENV_DIR/uid.env 2>/dev/null || ! grep -q "^LOCAL_GID=" $ENV_DIR/uid.env 2>/dev/null; then
  LOCAL_UID="LOCAL_UID=$(id -u $USER)"
  [ "$LOCAL_UID" == "LOCAL_UID=0" ] && LOCAL_UID="LOCAL_UID=65534"
  LOCAL_GID="LOCAL_GID=$(id -g $USER)"
  [ "$LOCAL_GID" == "LOCAL_GID=0" ] && LOCAL_GID="LOCAL_GID=65534"
  mkdir -p $ENV_DIR
  echo $LOCAL_UID >$ENV_DIR/uid.env
  echo $LOCAL_GID >>$ENV_DIR/uid.env
fi

# Functions

function install() {
  # echo -e -n "${CYAN}(!)${NC} Enter the domain name for your Portal instance (e.g. functionland.com): "
  # read DOMAIN
  # echo ""

  # if [ "$DOMAIN" == "" ]; then
  #   DOMAIN=$IP_ADDRESS
  # fi

  dockerComposeVolumes

  source .env.staging && export COMPOSER_VERSION PHP_VERSION


  docker build --no-cache -t bloxota-build --build-arg HOSTNAME=$DOMAIN --build-arg COMPOSER_VERSION \
    --build-arg PHP_VERSION -f $DOCKER_DIR/fxsupport/Dockerfile $PORTAL_DIR

  docker run --rm --name setup -v $DATA_DIR:/iotportaldata --env-file $ENV_DIR/uid.env bloxota-build

  dockerComposeBuild
}

function dockerComposeUp() {
  docker-compose -f $PORTAL_DIR/docker/docker-compose.yml --env-file $ENV_DIR/uid.env up -d --force-recreate
}

function dockerComposeDown() {
  if [ $(docker-compose -f "${PORTAL_DIR}/docker/docker-compose.yml" --env-file "${ENV_DIR}/uid.env" ps | wc -l) -gt 2 ]; then
    echo 'Shutting down existing deployment'
    docker-compose -f "${PORTAL_DIR}/docker/docker-compose.yml" --env-file "${ENV_DIR}/uid.env" down
  fi
}

function dockerComposeBuild() {
  docker-compose -f $PORTAL_DIR/docker/docker-compose.yml --env-file $ENV_DIR/uid.env build --no-cache
}

function dockerComposeVolumes() {
  createDir "ca-certificates"
  createDir "env"
}

function createDir() {
  if [ ! -d "${DATA_DIR}/$1" ]; then
    echo "Creating directory for docker volume $DATA_DIR/$1"
    mkdir -p $DATA_DIR/$1
  fi
}

function dockerPrune() {
  docker image prune --all --force --filter="label=com.iotportal.product=iotportal"
}

function restart() {
  dockerComposeDown
  dockerComposeUp
}

function rebuild() {
  dockerComposeDown
  install
  dockerPrune
}


# Commands
case $1 in
"install")
  install
  ;;
"start" | "restart")
  restart
  ;;
"stop")
  dockerComposeDown
  ;;
"rebuild")
  rebuild
  ;;
esac
