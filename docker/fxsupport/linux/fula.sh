#!/usr/bin/env bash
#
# Copyright (C) 2023 functionland
# SPDX-License-Identifier: AGPL-3.0-only
#
# Adapted UID parsing logic - Line 31-40
# v1.0.0
# fula-ota v3.0.0

set -e

# Setup

CYAN='\033[0;36m'
NC='\033[0m' # No Color

FULA_PATH=/usr/bin/fula
FULA_LOG_PATH=~/fula.sh.log
SYSTEMD_PATH=/etc/systemd/system
HW_CHECK_SC=$FULA_PATH/hw_test.py
RESIZE_SC=$FULA_PATH/resize.sh
WIFI_SC=$FULA_PATH/wifi.sh
BLUETOOTH_SC=$FULA_PATH/bluetooth.sh
BLUETOOTH_PY_SC=$FULA_PATH/bluetooth.py

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DATA_DIR=$DIR
if [ $# -gt 1 ]; then
  DATA_DIR=$2
fi

ENV_FILE="$DIR/.env"
DOCKER_DIR=$DIR

declare -x CURRENT_USER
CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

# Determine default host machine IP address
IP_ADDRESS=$(ip route get 1 | awk '{print $7}' | head -1)

function check_and_delete_log() {
  # The path to your file
  local filepath=$1

  # Check if the file exists
  if [[ ! -e "$filepath" ]]; then
    echo "File $filepath does not exist."
    return
  fi

  # Get the last modified date of the file
  local file_date
  file_date=$(sudo stat -c %y "$filepath" | cut -d' ' -f1)

  # Get the current date
  local current_date
  current_date=$(date +%F)

  # If the dates don't match, delete the file and create a log file
  if [[ "$file_date" != "$current_date" ]]; then
    sudo rm "$filepath"
    echo "File $filepath was deleted."

    # Create another file
    local creation_time
    creation_time=$(date)

    echo "File $filepath was created on $creation_time" >> "$filepath"
  else
    echo "File $filepath was not modified today." >> "$filepath"
  fi
}


function check_internet() {
  wget -q --spider --timeout=10 https://hub.docker.com
  return $?   # Return the status directly, no need for if/else.
}

function modify_bluetooth() {
  # Backup the original file
  cp /etc/systemd/system/dbus-org.bluez.service /etc/systemd/system/dbus-org.bluez.service.bak

  # Modify ExecStart and ExecStartPost
  sed -i 's|^ExecStart=/usr/libexec/bluetooth/bluetoothd$|ExecStart=/usr/libexec/bluetooth/bluetoothd  --compat --noplugin=sap -C|' /etc/systemd/system/dbus-org.bluez.service
  sed -i '/ExecStart=/a ExecStartPost=/usr/bin/sdptool add SP' /etc/systemd/system/dbus-org.bluez.service

  # Reload the systemd manager configuration
  systemctl daemon-reload

  # Restart the bluetooth service
  sudo systemctl restart bluetooth
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
  echo "Installing dependencies..." >> $FULA_LOG_PATH
  # Check if pip is installed
  command -v pip >/dev/null 2>&1 || {
    echo >&2 "pip not found, installing..."
    echo "pip not found, installing..." >> $FULA_LOG_PATH
    sudo apt-get install python3-pip -y || { echo "Could not  install python3-pip" >> $FULA_LOG_PATH; }
  }

  # Check if pexpect is installed
  python -c "import pexpect" 2>/dev/null || {
    echo "pexpect not found, installing..." >> $FULA_LOG_PATH
    pip install pexpect || { echo "Could not pip install pexpect" >> $FULA_LOG_PATH; }
  }

  # Call modify_bluetooth, but don't stop the script if it fails
  modify_bluetooth || { echo "modify_bluetooth failed, but continuing installation..." >> $FULA_LOG_PATH; }

  echo "Installing Fula ..." >> $FULA_LOG_PATH
  echo "Pulling Images..." >> $FULA_LOG_PATH
  dockerPull || { echo "Error while dockerPull" >> $FULA_LOG_PATH; }
  echo "Building Images..." >> $FULA_LOG_PATH
  dockerComposeBuild || { echo "Error while dockerComposeBuild" >> $FULA_LOG_PATH; }

  echo "Copying Files..." >> $FULA_LOG_PATH
  mkdir -p $FULA_PATH/ || { echo "Error making directory $FULA_PATH" >> $FULA_LOG_PATH; }
  
  cp fula.sh $FULA_PATH/ 2>/dev/null || { echo "Error copying file fula.sh" >> $FULA_LOG_PATH; } || true
  cp .env $FULA_PATH/ 2>/dev/null || { echo "Error copying file .env" >> $FULA_LOG_PATH; } || true
  cp docker-compose.yml $FULA_PATH/ 2>/dev/null || { echo "Error copying file docker-compose.yml" >> $FULA_LOG_PATH; } || true
  sudo cp fula.service $SYSTEMD_PATH/ 2>/dev/null || { echo "Error copying fula.service" >> $FULA_LOG_PATH; } || true

  cp hw_test.py $FULA_PATH/ 2>/dev/null || { echo "Error copying file hw_test.py" >> $FULA_LOG_PATH; } || true
  cp resize.sh $FULA_PATH/ 2>/dev/null || { echo "Error copying file resize.sh" >> $FULA_LOG_PATH; } || true
  cp wifi.sh $FULA_PATH/ 2>/dev/null || { echo "Error copying file wifi.sh" >> $FULA_LOG_PATH; } || true
  cp bluetooth.sh $FULA_PATH/ 2>/dev/null || { echo "Error copying file bluetooth.sh" >> $FULA_LOG_PATH; } || true
  cp bluetooth.py $FULA_PATH/ 2>/dev/null || { echo "Error copying file bluetooth.py" >> $FULA_LOG_PATH; } || true

  echo "Setting chmod..." >> $FULA_LOG_PATH
  if [ -f "$FULA_PATH/fula.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/fula.sh" ]; then 
      echo "$FULA_PATH/fula.sh is not executable, changing permissions..." >> $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/fula.sh || { echo "Error chmod file fula.sh" >> $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/resize.sh" ]; then 
    # Check if resize.sh is executable 
    if [ ! -x "$FULA_PATH/resize.sh" ]; then 
      echo "$FULA_PATH/resize.sh is not executable, changing permissions..." >> $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/resize.sh || { echo "Error chmod file resize.sh" >> $FULA_LOG_PATH; }
    fi 
  fi
  
  if [ -f "$FULA_PATH/bluetooth.sh" ]; then 
    # Check if bluetooth.sh is executable 
    if [ ! -x "$FULA_PATH/bluetooth.sh" ]; then 
      echo "$FULA_PATH/bluetooth.sh is not executable, changing permissions..." >> $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/bluetooth.sh || { echo "Error chmod file bluetooth.sh" >> $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/wifi.sh" ]; then 
    # Check if wifi.sh is executable 
    if [ ! -x "$FULA_PATH/wifi.sh" ]; then 
      echo "$FULA_PATH/wifi.sh is not executable, changing permissions..." >> $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/wifi.sh || { echo "Error chmod file wifi.sh" >> $FULA_LOG_PATH; }
    fi 
  fi

  echo "Installing Services..." >> $FULA_LOG_PATH
  systemctl daemon-reload || { echo "Error daemon reload" >> $FULA_LOG_PATH; }
  systemctl enable fula.service || { echo "Error enableing fula.service" >> $FULA_LOG_PATH; }
  echo "Installing Fula Finished" >> $FULA_LOG_PATH
}

function remove_wifi_connections() {
    # Get a list of all connection names
    local wifi_connections
    wifi_connections=$(nmcli con show | grep wifi | awk '{print $1}')


    # Iterate over each connection
    for conn in $wifi_connections; do
        echo "Removing Wi-Fi connection: $conn" >> $FULA_LOG_PATH
        sudo nmcli con delete "$conn"
    done
}

function dockerPull() {
  if check_internet; then
    echo "Start polling images..." >> $FULA_LOG_PATH
    
    if [ -z "$1" ]; then
      echo "Full Image Updating..." >> $FULA_LOG_PATH
      
      # Iterate over services and pull images only if they do not exist locally
      for service in $(docker-compose config --services); do
        image=$(docker-compose config | awk '$1 == "image:" { print $2 }' | grep "$service")
        
        # Attempt to pull the image, if it fails use the local version
        if ! docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE pull $service; then
          echo "$service image pull failed, using local version" >> $FULA_LOG_PATH
        fi
      done
    else
      . "$ENV_FILE"
      echo "Updating fxsupport ($FX_SUPPROT)..." >> $FULA_LOG_PATH
      
      # Attempt to pull the image, if it fails use the local version
      if ! docker pull $FX_SUPPROT; then
        echo "fx_support image pull failed, using local version" >> $FULA_LOG_PATH
      fi
    fi
  else
    echo "You are not connected to internet!" >> $FULA_LOG_PATH
    echo "Please check your connection" >> $FULA_LOG_PATH
  fi
}

function connectwifi() {
  # Check internet connection and setup WiFi if needed
  if [ -f "$WIFI_SC" ]; then
    sleep 160
    if ! check_internet; then
      echo "Waiting for Wi-Fi adapter to be ready..." >> $FULA_LOG_PATH
      bash $WIFI_SC || { echo "Wifi setup failed" >> $FULA_LOG_PATH; }
    fi
  fi
}

function dockerComposeUp() {
  # Attempt to pull the fxsupport image, if it fails use the local version
  if ! dockerPull fxsupport; then
    echo "fxsupport image pull failed, using local version" >> $FULA_LOG_PATH
  fi

  echo "compsing up images..." >> $FULA_LOG_PATH

  # Try running docker-compose up the first time
  if ! docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE up -d --no-recreate; then
    # If the compose up fails, stop all containers, remove them, and try again
    # shellcheck disable=SC2046
    docker stop $(docker ps -a -q)
    # shellcheck disable=SC2046
    docker rm -f $(docker ps -a -q)

    # Try running docker-compose up the second time
    if ! docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE up -d --no-recreate; then
      echo "failed to start some images" >> $FULA_LOG_PATH
      pullFailedServices &
      echo "pull pid is" $! >> $FULA_LOG_PATH
    fi
  else
    echo "Images successfully composed up" >> $FULA_LOG_PATH
  fi
}


function dockerComposeDown() {
  echo "dockerComposeDown: killPullImage" >> $FULA_LOG_PATH
  killPullImage
  echo "dockerComposeDown: killing done" >> $FULA_LOG_PATH
  if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE ps | wc -l) -gt 2 ]; then
    echo 'Shutting down existing deployment' >> $FULA_LOG_PATH
    docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE down --remove-orphans || true
  fi
}

function dockerComposeBuild() {
  docker-compose -f $DOCKER_DIR/docker-compose.yml --env-file $ENV_FILE build --no-cache
}

function createDir() {
  if [ ! -d "${DATA_DIR}/$1" ]; then
    echo "Creating directory for docker volume $DATA_DIR/$1" >> $FULA_LOG_PATH
    mkdir -p $DATA_DIR/$1
  fi
}

function dockerPrune() {
  docker image prune --all --force
}

function restart() {

  # Check if ~/V3.info exists
  if [ ! -f ~/V3.info ]; then
      touch ~/V3.info || { echo "Error creating version file" >> $FULA_LOG_PATH; }
      install || { echo "Error install" >> $FULA_LOG_PATH; }
      remove_wifi_connections || { echo "Error removing wifi connectins" >> $FULA_LOG_PATH; }
      sudo reboot
  fi

  if [ -f "$HW_CHECK_SC" ]; then
    python $HW_CHECK_SC || { echo "Hardware check failed" >> $FULA_LOG_PATH; }
  fi
  
  if [ -f "$RESIZE_SC" ]; then
    sh $RESIZE_SC || { echo "Resize failed" >> $FULA_LOG_PATH; }
  fi

  if [ -f ~/bluetooth_py.pid ]; then
    kill $(cat ~/bluetooth_py.pid) || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm ~/bluetooth_py.pid || { echo "Error removing bluetooth_py.pid" >> $FULA_LOG_PATH; }
  fi
  
  if [ -f "$BLUETOOTH_PY_SC" ]; then
    python $BLUETOOTH_PY_SC &> ~/bluetooth_py.log &
    echo $! > ~/bluetooth_py.pid
    echo "Ran $BLUETOOTH_PY_SC" >> $FULA_LOG_PATH
  fi

  if [ -f ~/bluetooth.pid ]; then
    kill $(cat ~/bluetooth.pid) || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm ~/bluetooth.pid || { echo "Error removing bluetooth.pid" >> $FULA_LOG_PATH; }
  fi

  if [ -f "$BLUETOOTH_SC" ]; then
    sudo bash $BLUETOOTH_SC &> ~/bluetooth.log &
    sudo echo $! > ~/bluetooth.pid
    echo "Ran $BLUETOOTH_SC" >> $FULA_LOG_PATH
  fi

  echo "dockerComposeDown" >> $FULA_LOG_PATH
  dockerComposeDown || { echo "dockerComposeDown failed" >> $FULA_LOG_PATH; } || true
  echo "dockerComposeUp" >> $FULA_LOG_PATH
  dockerComposeUp || { echo "dockerComposeUp failed" >> $FULA_LOG_PATH; }

  # Remove dangling images
  if docker image prune --filter="dangling=true" -f; then
    echo "pruning unused dockers..." >> $FULA_LOG_PATH
  fi
}


function remove() {
  echo "Removing Fula ..." >> $FULA_LOG_PATH
  killPullImage
  if service_exists fula.service; then
    systemctl stop fula.service -q
    systemctl disable fula.service -q
  fi
  rm -f $SYSTEMD_PATH/fula.service
  rm -rf "${FULA_PATH:?}/" || { echo "could not remove FULA_PATH"; } || true
  systemctl daemon-reload
  dockerPrune
  echo "Removing Fula Finished" >> $FULA_LOG_PATH
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
          echo "Start polling $service images..." >> $FULA_LOG_PATH
          if [ -s "${DOCKER_DIR}/docker-compose.yml" ]; then
            echo "Pulling $service" >> $FULA_LOG_PATH
            if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull $service) ]; then
                echo "pulling $service" >> $FULA_LOG_PATH
            else
                echo "failed to get $service" >> $FULA_LOG_PATH
            fi
          fi
        fi
      fi
    done

    attempts=$(($attempts + 1))
    if [ $attempts -ge $DEFAULT_MAX_ATTEMPTS ]; then
      echo "Maximum number of attempts reached for service $service. Exiting..." >> $FULA_LOG_PATH
      break 1
    fi
    # Wait before checking again
    echo "Next Time Will be " $DEFAULT_INTERVAL " Seconds Later..." >> $FULA_LOG_PATH
    sleep $DEFAULT_INTERVAL
  done
}

function killPullImage() {
  if [ -f /var/run/fula.pid ] && [ ! -s /var/run/fula.pid ] ; then
     echo "Process already running." >> "$FULA_LOG_PATH"
     kill -9 $(cat /var/run/fula.pid)
     rm -f /var/run/fula.pid
     printf "%s" "$(pidof $$)" > /var/run/fula.pid
  fi
}


# Commands
case $1 in
"install")
  check_and_delete_log $FULA_LOG_PATH
  echo "ran install at: $(date)" >> $FULA_LOG_PATH
  install
  ;;
"start" | "restart")
  echo "ran start at: $(date)" >> $FULA_LOG_PATH
  check_and_delete_log $FULA_LOG_PATH
  echo "check_and_delete_log status=> $?" >> $FULA_LOG_PATH; 
  restart
  echo "restart status=> $?" >> $FULA_LOG_PATH; 
  docker cp fula_fxsupport:/linux/. /usr/bin/fula/
  echo "docker cp status=> $?" >> $FULA_LOG_PATH; 
  sync
  cho "sync status=> $?" >> $FULA_LOG_PATH; 
  ;;
"stop")
  check_and_delete_log $FULA_LOG_PATH
  echo "ran stop at: $(date)" >> $FULA_LOG_PATH
  dockerComposeDown
  if [ -f ~/bluetooth_py.pid ]; then
    kill $(cat ~/bluetooth_py.pid) || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm ~/bluetooth_py.pid
  fi
  if [ -f ~/bluetooth.pid ]; then
    kill $(cat ~/bluetooth.pid) || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm ~/bluetooth.pid
  fi
  ;;
"rebuild")
  check_and_delete_log $FULA_LOG_PATH
  echo "ran rebuild at: $(date)" >> $FULA_LOG_PATH
  rebuild
  ;;
"removeall")
  check_and_delete_log $FULA_LOG_PATH
  echo "ran removeall at: $(date)" >> $FULA_LOG_PATH
  containers=$(docker ps -a -q)
  if [ -n "$containers" ]; then
      docker rm -f $containers
  else
      echo "No containers to remove" >> $FULA_LOG_PATH
  fi
  remove
  ;;
"update")
  check_and_delete_log $FULA_LOG_PATH
  echo "ran update at: $(date)" >> $FULA_LOG_PATH
  dockerPull "${@:2}"
  ;;
"pull-failed")
  check_and_delete_log $FULA_LOG_PATH
  echo "ran pull-failed at: $(date)" >> $FULA_LOG_PATH
  pullFailedServices
  ;;
esac
