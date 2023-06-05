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

HOME_DIR=/home/pi
FULA_PATH=/usr/bin/fula
FULA_LOG_PATH=$HOME_DIR/fula.sh.log
SYSTEMD_PATH=/etc/systemd/system
HW_CHECK_SC=$FULA_PATH/hw_test.py
RESIZE_SC=$FULA_PATH/resize.sh
WIFI_SC=$FULA_PATH/wifi.sh
BLUETOOTH_PY_SC=$FULA_PATH/bluetooth.py
UPDATE_SC=$FULA_PATH/update.sh

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

function setup_logrotate {
    # Check if logrotate is installed
    if ! command -v logrotate &> /dev/null
    then
        echo "logrotate could not be found. Installing..."
        sudo apt-get update
        sudo apt-get install logrotate -y
    else
        echo "logrotate is already installed."
    fi

    # Create logrotate configuration file
    local logfile_path=$1
    local config_path="/etc/logrotate.d/fula_logs"
    local temp_config_path="/tmp/fula_logs.tmp"

    cat << EOF > ${temp_config_path}
${logfile_path} {
    daily
    rotate 6
    compress
    missingok
    notifempty
    create 0640 root root
    copytruncate
}
EOF

    # Check if the existing config file is different than the temp config
    if [ ! -f ${config_path} ] || ! cmp -s ${config_path} ${temp_config_path}
    then
        # If they differ, replace the old config with the new one
        sudo mv ${temp_config_path} ${config_path}
        echo "Logrotate configuration file for $logfile_path has been updated."

        # Force logrotate to read the new configuration
        sudo logrotate -f /etc/logrotate.conf
    else
        echo "Logrotate configuration file for $logfile_path is already up to date."
        # Remove the temporary config file
        rm ${temp_config_path}
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

function create_cron() {
  local cron_command="*/5 * * * * if [ -f /usr/bin/fula/update.sh ]; then sudo bash /usr/bin/fula/update.sh; fi"
  
  # Create a temporary file
  local temp_file=$(mktemp)

  # Remove all existing instances of the job and write the results to the temporary file
  sudo crontab -l | grep -v "/usr/bin/fula/update.sh" > "$temp_file"
  
  # Add the cron job back in
  echo "$cron_command" >> "$temp_file"
  
  # Replace the current cron jobs with the contents of the temporary file
  sudo crontab "$temp_file"
  
  # Remove the temporary file
  rm "$temp_file"
  
  echo "Cron job created/updated." >> $FULA_LOG_PATH 2>&1
}



# Functions
function install() {
  all_success=true
  if test -f /etc/apt/apt.conf.d/proxy.conf; then sudo rm /etc/apt/apt.conf.d/proxy.conf; fi
  setup_logrotate $FULA_LOG_PATH || { echo "Error setting up logrotate" >> $FULA_LOG_PATH 2>&1; all_success=false; } || true
  echo "Installing dependencies..." >> $FULA_LOG_PATH 2>&1
  # Check if pip is installed
  command -v pip >/dev/null 2>&1 || {
    echo >&2 "pip not found, installing..."
    echo "pip not found, installing..." >> $FULA_LOG_PATH 2>&1
    sudo apt-get install -y python3-pip || { echo "Could not  install python3-pip" >> $FULA_LOG_PATH 2>&1; all_success=false; }
  }

  python -c "import dbus" 2>/dev/null || {
    echo "python3-dbus not found, installing..." >> $FULA_LOG_PATH 2>&1
    sudo apt-get install -y python3-dbus || { echo "Could not  install python3-dbus" >> $FULA_LOG_PATH 2>&1; all_success=false; }
  }

  # Check if RPi.GPIO is installed
  python -c "import RPi.GPIO" 2>/dev/null || {
    echo "RPi.GPIO not found, installing..." >> $FULA_LOG_PATH 2>&1
    pip install RPi.GPIO >> $FULA_LOG_PATH 2>&1 || { echo "Could not pip install RPi.GPIO" >> $FULA_LOG_PATH 2>&1; all_success=false; } || true
  }

  # Check if pexpect is installed
  python -c "import pexpect" 2>/dev/null || {
    echo "pexpect not found, installing..." >> $FULA_LOG_PATH 2>&1
    pip install pexpect >> $FULA_LOG_PATH 2>&1 || { echo "Could not pip install pexpect" >> $FULA_LOG_PATH 2>&1; all_success=false; } || true
  }

  echo "Call modify_bluetooth, but don't stop the script if it fails" >> $FULA_LOG_PATH 2>&1
  modify_bluetooth >> $FULA_LOG_PATH 2>&1 || { echo "modify_bluetooth failed, but continuing installation..." >> $FULA_LOG_PATH 2>&1; all_success=false; } || true

  echo "Installing Fula ..." >> $FULA_LOG_PATH 2>&1
  echo "Pulling Images..." >> $FULA_LOG_PATH 2>&1
  dockerPull || { echo "Error while dockerPull" >> $FULA_LOG_PATH 2>&1; all_success=false; }
  echo "Building Images..." >> $FULA_LOG_PATH
  dockerComposeBuild >> $FULA_LOG_PATH 2>&1 || { echo "Error while dockerComposeBuild" >> $FULA_LOG_PATH; all_success=false; }

  echo "Copying Files..." >> $FULA_LOG_PATH
  mkdir -p $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error making directory $FULA_PATH" >> $FULA_LOG_PATH; }
  
  cp fula.sh $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file fula.sh" >> $FULA_LOG_PATH; } || true
  cp .env $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file .env" >> $FULA_LOG_PATH; } || true
  cp docker-compose.yml $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file docker-compose.yml" >> $FULA_LOG_PATH; } || true
  sudo cp fula.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying fula.service" | sudo tee -a $FULA_LOG_PATH; } || true

  cp hw_test.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file hw_test.py" >> $FULA_LOG_PATH; } || true
  cp resize.sh $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file resize.sh" >> $FULA_LOG_PATH; } || true
  cp wifi.sh $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file wifi.sh" >> $FULA_LOG_PATH; } || true
  cp control_led.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file control_led.sh" >> $FULA_LOG_PATH; } || true
  cp service.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file service.py" >> $FULA_LOG_PATH; } || true
  cp advertisement.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file advertisement.py" >> $FULA_LOG_PATH; } || true
  cp bletools.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file bletools.py" >> $FULA_LOG_PATH; } || true
  cp service.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file service.py" >> $FULA_LOG_PATH; } || true
  cp bluetooth.py $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file bluetooth.py" >> $FULA_LOG_PATH; } || true
  cp update.sh $FULA_PATH/ >> $FULA_LOG_PATH 2>&1 || { echo "Error copying file update.sh" >> $FULA_LOG_PATH; } || true

  sudo rm /usr/bin/fula/docker.env 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing /usr/bin/fula/docker.env" >> $FULA_LOG_PATH; } || true

  echo "Setting chmod..." >> $FULA_LOG_PATH
  if [ -f "$FULA_PATH/fula.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/fula.sh" ]; then 
      echo "$FULA_PATH/fula.sh is not executable, changing permissions..." >> $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/fula.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file fula.sh" >> $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/resize.sh" ]; then 
    # Check if resize.sh is executable 
    if [ ! -x "$FULA_PATH/resize.sh" ]; then 
      echo "$FULA_PATH/resize.sh is not executable, changing permissions..." >> $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/resize.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file resize.sh" >> $FULA_LOG_PATH; }
    fi 
  fi
  

  if [ -f "$FULA_PATH/update.sh" ]; then 
    # Check if update.sh is executable 
    if [ ! -x "$FULA_PATH/update.sh" ]; then 
      echo "$FULA_PATH/update.sh is not executable, changing permissions..." >> $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/update.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file update.sh" >> $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/wifi.sh" ]; then 
    # Check if wifi.sh is executable 
    if [ ! -x "$FULA_PATH/wifi.sh" ]; then 
      echo "$FULA_PATH/wifi.sh is not executable, changing permissions..." >> $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/wifi.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file wifi.sh" >> $FULA_LOG_PATH; }
    fi 
  fi

  echo "Installing Services..." >> $FULA_LOG_PATH
  systemctl daemon-reload 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error daemon reload" >> $FULA_LOG_PATH; all_success=false; }
  systemctl enable fula.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error enableing fula.service" >> $FULA_LOG_PATH; all_success=false; }
  echo "Installing Fula Finished" >> $FULA_LOG_PATH
  echo "Setting up cron job for manual update" >> $FULA_LOG_PATH
  create_cron 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not setup cron job" >> $FULA_LOG_PATH; all_success=false; } || true
  echo "installation done" >> $FULA_LOG_PATH
  if $all_success; then
    touch $HOME_DIR/V3.info 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error creating version file" >> $FULA_LOG_PATH; }
  else
    echo "Installation finished with errors, version file not created." >> $FULA_LOG_PATH
  fi
}

function remove_wifi_connections() {
    # Get a list of all connection names
    local wifi_connections
    wifi_connections=$(nmcli con show | grep wifi | awk '{print $1}')


    # Iterate over each connection
    for conn in $wifi_connections; do
        echo "Removing Wi-Fi connection: $conn" >> $FULA_LOG_PATH
        sudo nmcli con delete "$conn" 2>&1 | sudo tee -a $FULA_LOG_PATH
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
        if ! docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull "$service"; then
          echo "$service image pull failed, using local version" >> $FULA_LOG_PATH
        fi
      done
    else
      . "$ENV_FILE"
      echo "Updating fxsupport ($FX_SUPPROT)..." >> $FULA_LOG_PATH
      
      # Attempt to pull the image, if it fails use the local version
      if ! docker pull "$FX_SUPPROT"; then
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
      bash $WIFI_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Wifi setup failed" >> $FULA_LOG_PATH; }
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
  if ! docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" up -d --no-recreate; then
    # If the compose up fails, stop all containers, remove them, and try again
    # shellcheck disable=SC2046
    docker stop $(docker ps -a -q) 2>&1 | sudo tee -a $FULA_LOG_PATH
    # shellcheck disable=SC2046
    docker rm -f $(docker ps -a -q) 2>&1 | sudo tee -a $FULA_LOG_PATH

    # Try running docker-compose up the second time
    if ! docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" up -d --no-recreate; then
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
  killPullImage 2>&1 | sudo tee -a $FULA_LOG_PATH
  echo "dockerComposeDown: killing done" >> $FULA_LOG_PATH
  # shellcheck disable=SC2046
  if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE ps | wc -l) -gt 2 ]; then
    echo 'Shutting down existing deployment' >> $FULA_LOG_PATH
    docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" down --remove-orphans || true
  fi
}

function dockerComposeBuild() {
  docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" build --no-cache 2>&1 | sudo tee -a $FULA_LOG_PATH
}

function createDir() {
  if [ ! -d "${DATA_DIR}/$1" ]; then
    echo "Creating directory for docker volume $DATA_DIR/$1" >> $FULA_LOG_PATH
    mkdir -p $DATA_DIR/$1 2>&1 | sudo tee -a $FULA_LOG_PATH
  fi
}

function dockerPrune() {
  docker image prune --all --force 2>&1 | sudo tee -a $FULA_LOG_PATH
}

function restart() {

  # Check if /home/pi/V3.info exists
  if [ ! -f $HOME_DIR/V3.info ]; then
      install 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error install" >> $FULA_LOG_PATH; }
      remove_wifi_connections 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing wifi connectins" >> $FULA_LOG_PATH; }
      sudo reboot
  fi

  if [ -f "$HW_CHECK_SC" ]; then
    python $HW_CHECK_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Hardware check failed" >> $FULA_LOG_PATH; }
  fi
  
  if [ -f "$RESIZE_SC" ]; then
    sh $RESIZE_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Resize failed" >> $FULA_LOG_PATH; }
  fi

  if [ -f $HOME_DIR/bluetooth_py.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/bluetooth_py.pid) 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/bluetooth_py.pid 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing bluetooth_py.pid" >> $FULA_LOG_PATH; }
  fi
  
  if [ -f "$BLUETOOTH_PY_SC" ]; then
    python $BLUETOOTH_PY_SC &> $HOME_DIR/bluetooth_py.log &
    echo $! > $HOME_DIR/bluetooth_py.pid
    echo "Ran $BLUETOOTH_PY_SC" >> $FULA_LOG_PATH
  fi

  if [ -f $HOME_DIR/update.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/update.pid) 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error Killing update Process" >> $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/update.pid 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing update.pid" >> $FULA_LOG_PATH; }
  fi

  if [ -f "$UPDATE_SC" ]; then
    sudo bash $UPDATE_SC 2>&1 | sudo tee $HOME_DIR/update.log > /dev/null &
    echo $! | sudo tee $HOME_DIR/update.pid > /dev/null
    echo "Ran $UPDATE_SC" >> $FULA_LOG_PATH
  fi

  echo "dockerComposeDown" >> $FULA_LOG_PATH
  dockerComposeDown 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "dockerComposeDown failed" >> $FULA_LOG_PATH; } || true
  echo "dockerComposeUp" >> $FULA_LOG_PATH
  dockerComposeUp 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "dockerComposeUp failed" >> $FULA_LOG_PATH; }

  # Remove dangling images
  if docker image prune --filter="dangling=true" -f; then
    echo "pruning unused dockers..." >> $FULA_LOG_PATH
  fi
}


function remove() {
  echo "Removing Fula ..." >> $FULA_LOG_PATH
  killPullImage 2>&1 | sudo tee -a $FULA_LOG_PATH
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
            # shellcheck disable=SC2046
            if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull $service) ]; then
                echo "pulling $service" >> $FULA_LOG_PATH
            else
                echo "failed to get $service" >> $FULA_LOG_PATH
            fi
          fi
        fi
      fi
    done

    attempts=$((attempts + 1))
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
     # shellcheck disable=SC2046
     kill -9 $(cat /var/run/fula.pid)
     rm -f /var/run/fula.pid
     printf "%s" "$(pidof $$)" > /var/run/fula.pid
  fi
}


# Commands
case $1 in
"install")
  echo "ran install at: $(date)" >> $FULA_LOG_PATH
  install 2>&1 | sudo tee -a $FULA_LOG_PATH
  ;;
"start" | "restart")
  echo "ran start at: $(date)" >> $FULA_LOG_PATH
  restart 2>&1 | sudo tee -a $FULA_LOG_PATH
  echo "restart status=> $?" >> $FULA_LOG_PATH; 
  if ! find /home/pi -name stop_docker_copy.txt -mmin +1440 | grep -q 'stop_docker_copy.txt'; then
    docker cp fula_fxsupport:/linux/. /usr/bin/fula/ 2>&1 | sudo tee -a $FULA_LOG_PATH
    echo "docker cp status=> $?" >> $FULA_LOG_PATH;
  else
    echo "File stop_docker_copy.txt has been modified in the last 24 hours, skipping docker cp command." >> $FULA_LOG_PATH;
  fi
  sync
  echo "sync status=> $?" >> $FULA_LOG_PATH; 
  ;;
"stop")
  echo "ran stop at: $(date)" >> $FULA_LOG_PATH
  dockerComposeDown
  if [ -f $HOME_DIR/bluetooth_py.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/bluetooth_py.pid) || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/bluetooth_py.pid
  fi
  if [ -f $HOME_DIR/bluetooth.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/bluetooth.pid) || { echo "Error Killing Process" >> $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/bluetooth.pid
  fi

  if [ -f $HOME_DIR/update.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/update.pid) || { echo "Error Killing update Process" >> $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/update.pid
  fi
  ;;
"rebuild")
  echo "ran rebuild at: $(date)" >> $FULA_LOG_PATH
  rebuild
  ;;
"removeall")
  echo "ran removeall at: $(date)" >> $FULA_LOG_PATH
  containers=$(docker ps -a -q)
  if [ -n "$containers" ]; then
      # shellcheck disable=SC2086
      docker rm -f $containers
  else
      echo "No containers to remove" >> $FULA_LOG_PATH
  fi
  remove
  ;;
"update")
  echo "ran update at: $(date)" >> $FULA_LOG_PATH
  dockerPull "${@:2}"
  ;;
"pull-failed")
  echo "ran pull-failed at: $(date)" >> $FULA_LOG_PATH
  pullFailedServices
  ;;
esac
