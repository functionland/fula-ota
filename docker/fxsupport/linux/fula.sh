#!/usr/bin/env bash
#
# Copyright (C) 2023 functionland
# SPDX-License-Identifier: AGPL-3.0-only
#
# Adapted UID parsing logic - Line 31-40
# fula-ota v6.0.4

set -e

# Setup

HOME_DIR=/home/pi
INSTALLATION_FULA_DIR=$HOME_DIR/fula-ota/docker/fxsupport/linux
FULA_PATH=/usr/bin/fula
FULA_LOG_PATH=$HOME_DIR/fula.sh.log
SYSTEMD_PATH=/etc/systemd/system
HW_CHECK_SC=$FULA_PATH/hw_test.py
RESIZE_SC=$FULA_PATH/resize.sh
WIFI_SC=$FULA_PATH/wifi.sh
UPDATE_SC=$FULA_PATH/update.sh
RM_DUP_NETWORK_SC=$FULA_PATH/docker_rm_duplicate_network.py
resize_flag=$FULA_PATH/.resize_flg
partition_flag=$FULA_PATH/.partition_flg

DATA_DIR=$FULA_PATH
if [ $# -gt 1 ]; then
  DATA_DIR=$2
fi

ENV_FILE="$FULA_PATH/.env"
DOCKER_DIR=$FULA_PATH

declare -x CURRENT_USER
CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

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
  if [ ! -f ${SYSTEMD_PATH}/dbus-org.bluez.service.bak ]; then
    cp ${SYSTEMD_PATH}/dbus-org.bluez.service ${SYSTEMD_PATH}/dbus-org.bluez.service.bak
  fi

  # Modify ExecStart
  sed -i 's|^ExecStart=/usr/libexec/bluetooth/bluetoothd$|ExecStart=/usr/libexec/bluetooth/bluetoothd  --compat --noplugin=sap -C|' $SYSTEMD_PATH/dbus-org.bluez.service

  # Modify ExecStartPost only if "ExecStartPost=/usr/bin/sdptool add SP" does not exist
  if ! grep -q "ExecStartPost=/usr/bin/sdptool add SP" ${SYSTEMD_PATH}/dbus-org.bluez.service; then
    sed -i '/ExecStart=/a ExecStartPost=/usr/bin/sdptool add SP' ${SYSTEMD_PATH}/dbus-org.bluez.service
  fi

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
  local cron_command_update="*/5 * * * * if [ -f $FULA_PATH/update.sh ]; then sudo bash $FULA_PATH/update.sh; fi"
  local cron_command_bluetooth="@reboot sudo bash $FULA_PATH/bluetooth.sh 2>&1 | tee -a $FULA_LOG_PATH"
  local cron_command_mount="*/4 * * * * if [ -f $FULA_PATH/check-mount.sh ]; then sudo bash $FULA_PATH/check-mount.sh; fi"
  local cron_command_resize="@reboot sudo bash $FULA_PATH/resize.sh 2>&1 | tee -a $FULA_LOG_PATH"

  # Create a temporary file
  local temp_file
  temp_file=$(mktemp)

  # Remove all existing instances of the update, bluetooth, and mount jobs
  # Write the results to the temporary file, while also removing any leading or trailing blank lines
  sudo crontab -l | grep -v -e "$FULA_PATH/update.sh" -e "$FULA_PATH/bluetooth.sh" -e "$FULA_PATH/check-mount.sh" | sed '/^$/d' > "$temp_file"

  # Add the cron jobs back in
  if ! grep -q -F "$cron_command_update" "$temp_file"; then
    echo "$cron_command_update" >> "$temp_file"
  fi
  if ! grep -q -F "$cron_command_resize" "$temp_file"; then
    echo "$cron_command_resize" >> "$temp_file"
  fi
  if ! grep -q -F "$cron_command_bluetooth" "$temp_file"; then
    echo "$cron_command_bluetooth" >> "$temp_file"
  fi
  # Ensure the mount command is added only once
  if ! grep -q -F "$cron_command_mount" "$temp_file"; then
    echo "$cron_command_mount" >> "$temp_file"
  fi

  # Remove any leading or trailing blank lines from the temp file
  sed -i '/^$/d' "$temp_file"

  # Replace the current cron jobs with the contents of the temporary file
  sudo crontab "$temp_file"

  # Remove the temporary file
  rm "$temp_file"

  echo "Cron jobs created/updated." 2>&1 | sudo tee -a $FULA_LOG_PATH
}

# Functions
function install() {
  arch=${1:-RK1}  # Set arch based on the provided argument, default to RK1

  all_success=true
  mkdir -p ${HOME_DIR}/.internal
  mkdir -p ${FULA_PATH}/kubo
  mkdir -p ${HOME_DIR}/.internal/ipfs_data

  touch ${HOME_DIR}/.internal/ipfs_data/version
  touch ${HOME_DIR}/.internal/ipfs_data/datastore_spec

  if test -f /etc/apt/apt.conf.d/proxy.conf; then sudo rm /etc/apt/apt.conf.d/proxy.conf; fi
  setup_logrotate $FULA_LOG_PATH || { echo "Error setting up logrotate" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
  mkdir -p ${HOME_DIR}/commands/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error making directory $HOME_DIR/commands/" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true

  if [ "$arch" == "RK1" ] || [ "$arch" == "RPI4" ]; then
    connectwifi
  fi

  sudo sysctl -w net.core.rmem_max=2500000 || { echo "Could not set net.core.rmem_max" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
  sudo sysctl -w net.core.wmem_max=2500000 || { echo "Could not set net.core.wmem_max" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true

  if check_internet; then
    echo "Installing dependencies..." 2>&1 | sudo tee -a $FULA_LOG_PATH
    sudo apt-get update || { echo "Could not update before install" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; }
    # Check if pip is installed
    command -v pip >/dev/null 2>&1 || {
      echo >&2 "pip not found, installing..."
      echo "pip not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y python3-pip || { echo "Could not  install python3-pip" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; }
    }

    command -v mergerfs >/dev/null 2>&1 || {
      echo >&2 "mergerfs not found, installing..."
      echo "mergerfs not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y mergerfs || { echo "Could not install mergerfs" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; }
    }


    command -v inotifywait >/dev/null 2>&1 || {
      echo >&2 "inotify-tools not found, installing..."
      echo "inotify-tools not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y inotify-tools || { echo "Could not  install inotify-tools" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; }
    }

    python -c "import dbus" 2>/dev/null || {
      echo "python3-dbus not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y python3-dbus || { echo "Could not  install python3-dbus" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; }
    }

    # Check if RPi.GPIO is installed
    python -c "import RPi.GPIO" 2>/dev/null || {
      echo "RPi.GPIO not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      pip install RPi.GPIO 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not pip install RPi.GPIO" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
    }

    # Check if pexpect is installed
    python -c "import pexpect" 2>/dev/null || {
      echo "pexpect not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      pip install pexpect 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not pip install pexpect" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
    }

    # Check if psutil is installed
    python -c "import psutil" 2>/dev/null || {
      echo "psutil not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      pip install psutil 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not pip install psutil" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
    }
  else
    echo "Internet check failed, checking for existing dependencies..." 2>&1 | sudo tee -a $FULA_LOG_PATH
    command -v pip >/dev/null 2>&1 || { echo "pip not found"; all_success=false; }
    command -v inotifywait >/dev/null 2>&1 || { echo "inotifywait not found"; all_success=false; }
    python -c "import dbus" 2>/dev/null || { echo "python3-dbus not found"; all_success=false; }
    if [ ! -d "/sys/module/rockchipdrm" ]; then
      python -c "import RPi.GPIO" 2>/dev/null || { echo "RPi.GPIO not found"; all_success=false; }
    fi
    python -c "import pexpect" 2>/dev/null || { echo "pexpect not found"; all_success=false; }
    python -c "import psutil" 2>/dev/null || { echo "psutil not found"; all_success=false; }
  fi

  echo "Call modify_bluetooth, but don't stop the script if it fails" 2>&1 | sudo tee -a $FULA_LOG_PATH
  modify_bluetooth 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "modify_bluetooth failed, but continuing installation..." 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true

  echo "Copying Files..." | sudo tee -a $FULA_LOG_PATH
  mkdir -p $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error making directory $FULA_PATH" | sudo tee -a $FULA_LOG_PATH; }

  if [ "$(readlink -f .)" != "$(readlink -f $FULA_PATH)" ]; then
    cp ${INSTALLATION_FULA_DIR}/docker-compose.yml $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file docker-compose.yml" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/.env $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file .env" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/.env.cluster $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file .env.cluster" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/.env.gofula $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file .env.gofula" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/union-drive.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file union-drive.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/fula.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file fula.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/hw_test.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file hw_test.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/resize.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file resize.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/wifi.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file wifi.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/control_led.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file control_led.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/service.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file service.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/advertisement.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file advertisement.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/bletools.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file bletools.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/service.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file service.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/bluetooth.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file bluetooth.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/bluetooth.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file bluetooth.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/update.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file update.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/docker_rm_duplicate_network.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file docker_rm_duplicate_network.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/commands.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file commands.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/repairfs.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file repairfs.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/check-mount.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file check-mount.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/readiness-check.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file readiness-check.py" | sudo tee -a $FULA_LOG_PATH; } || true

    cp -r ${INSTALLATION_FULA_DIR}/kubo $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying kubo folder" | sudo tee -a $FULA_LOG_PATH; } || true
    cp -r ${INSTALLATION_FULA_DIR}/ipfs-cluster $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying ipfs-cluster folder" | sudo tee -a $FULA_LOG_PATH; } || true

    sudo chmod -R 755 ${FULA_PATH}/kubo
    sudo chmod -R 755 ${FULA_PATH}/ipfs-cluster

    cp ${INSTALLATION_FULA_DIR}/fula.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file fula.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/commands.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file commands.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/uniondrive.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file uniondrive.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/fula-readiness-check.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file fula-readiness-check.service" | sudo tee -a $FULA_LOG_PATH; } || true
  else
    echo "Source and destination are the same, skipping copy" | sudo tee -a $FULA_LOG_PATH
  fi
  sudo mv ${FULA_PATH}/fula.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying fula.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/commands.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying commands.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/uniondrive.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying uniondrive.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/fula-readiness-check.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying fula-readiness-check.service" | sudo tee -a $FULA_LOG_PATH; } || true

  if [[ -d "${HOME_DIR}/.internal/ipfs_data/config" ]]; then
    echo "Config exists as a directory, deleting..." | sudo tee -a $FULA_LOG_PATH
    sudo rm -rf "${HOME_DIR}/.internal/ipfs_data/config" || { echo "Error deleting directory config" | sudo tee -a $FULA_LOG_PATH; exit 1; }
  fi
  if [[ ! -f "${HOME_DIR}/.internal/ipfs_data/config" ]]; then
    cp ${FULA_PATH}/kubo/config "${HOME_DIR}/.internal/ipfs_data/config" 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file config" | sudo tee -a $FULA_LOG_PATH; } || true
  fi
  if [[ ! -f "${HOME_DIR}/.internal/ipfs_config" ]]; then
    # Below is to have a copy of config in the root avaialbe to gi-fula docker for copying if needed as a failsafe
    cp ${FULA_PATH}/kubo/config "${HOME_DIR}/.internal/ipfs_config" 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file config to internal root" | sudo tee -a $FULA_LOG_PATH; } || true
  fi

  if [ -f "$FULA_PATH/docker.env" ]; then 
    sudo rm ${FULA_PATH}/docker.env 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing $FULA_PATH/docker.env" | sudo tee -a $FULA_LOG_PATH; } || true
  else 
    echo "File $FULA_PATH/docker.env does not exist, skipping removal" | sudo tee -a $FULA_LOG_PATH
  fi


  echo "Setting chmod..." | sudo tee -a $FULA_LOG_PATH
  if [ -f "$FULA_PATH/fula.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/fula.sh" ]; then 
      echo "$FULA_PATH/fula.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/fula.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file fula.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/resize.sh" ]; then 
    # Check if resize.sh is executable 
    if [ ! -x "$FULA_PATH/resize.sh" ]; then 
      echo "$FULA_PATH/resize.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/resize.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file resize.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi
  

  if [ -f "$FULA_PATH/update.sh" ]; then 
    # Check if update.sh is executable 
    if [ ! -x "$FULA_PATH/update.sh" ]; then 
      echo "$FULA_PATH/update.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/update.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file update.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/wifi.sh" ]; then 
    # Check if wifi.sh is executable 
    if [ ! -x "$FULA_PATH/wifi.sh" ]; then 
      echo "$FULA_PATH/wifi.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/wifi.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file wifi.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/commands.sh" ]; then 
    # Check if commands.sh is executable 
    if [ ! -x "$FULA_PATH/commands.sh" ]; then 
      echo "$FULA_PATH/commands.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/commands.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file commands.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/check-mount.sh" ]; then 
    # Check if check-mount.sh is executable 
    if [ ! -x "$FULA_PATH/check-mount.sh" ]; then 
      echo "$FULA_PATH/check-mount.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH 
      sudo chmod +x $FULA_PATH/check-mount.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file check-mount.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/bluetooth.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/bluetooth.sh" ]; then 
      echo "$FULA_PATH/bluetooth.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/bluetooth.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file bluetooth.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/ipfs-cluster/ipfs-cluster-container-init.d.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/ipfs-cluster/ipfs-cluster-container-init.d.sh" ]; then 
      echo "$FULA_PATH/ipfs-cluster/ipfs-cluster-container-init.d.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/ipfs-cluster/ipfs-cluster-container-init.d.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file ipfs-cluster-container-init.d.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  if [ -f "$FULA_PATH/kubo/kubo-container-init.d.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/kubo/kubo-container-init.d.sh" ]; then 
      echo "$FULA_PATH/kubo/kubo-container-init.d.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/kubo/kubo-container-init.d.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file kubo-container-init.d.sh" | sudo tee -a $FULA_LOG_PATH; }
    fi 
  fi

  echo "Installing Fula ..." 2>&1 | sudo tee -a $FULA_LOG_PATH
  echo "Pulling Images..." 2>&1 | sudo tee -a $FULA_LOG_PATH
  dockerPull || { echo "Error while dockerPull" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; }
  echo "Building Images..." | sudo tee -a $FULA_LOG_PATH
  dockerComposeBuild 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error while dockerComposeBuild" | sudo tee -a $FULA_LOG_PATH; all_success=false; }

  echo "Installing Services..." | sudo tee -a $FULA_LOG_PATH
  if [ "$arch" == "RK1" ] || [ "$arch" == "RPI4" ]; then
    systemctl daemon-reload 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error daemon reload" | sudo tee -a $FULA_LOG_PATH; all_success=false; }
  fi
  
  systemctl enable uniondrive.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error enableing uniondrive.service" | sudo tee -a $FULA_LOG_PATH; all_success=false; }
  echo "Installing Uniondrive Finished" | sudo tee -a $FULA_LOG_PATH
  
  systemctl enable fula.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error enableing fula.service" | sudo tee -a $FULA_LOG_PATH; all_success=false; }
  echo "Installing Fula Finished" | sudo tee -a $FULA_LOG_PATH
  
  systemctl enable commands.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error enableing commands.service" | sudo tee -a $FULA_LOG_PATH; all_success=false; }
  echo "Installing Commands Finished" | sudo tee -a $FULA_LOG_PATH

  systemctl enable fula-readiness-check.service 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error enableing fula-readiness-check.service" | sudo tee -a $FULA_LOG_PATH; all_success=false; }
  echo "Installing fula-readiness-check Finished" | sudo tee -a $FULA_LOG_PATH

  echo "Setting up cron job for manual update" | sudo tee -a $FULA_LOG_PATH
  create_cron 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not setup cron job" | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
  echo "installation done with all_success=$all_success" | sudo tee -a $FULA_LOG_PATH
  if $all_success; then
    sudo rm -f ${HOME_DIR}/V[0-9].info || { echo "Error removing previous version files" | sudo tee -a $FULA_LOG_PATH; }
    touch ${HOME_DIR}/V6.info 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error creating version file" | sudo tee -a $FULA_LOG_PATH; }
    if [ "$arch" == "RK1" ] || [ "$arch" == "RPI4" ]; then
      if [ -f "$FULA_PATH/control_led.py" ]; then
        python ${FULA_PATH}/control_led.py white 5 2>&1 | sudo tee -a $FULA_LOG_PATH || true
      fi
    fi
  else
    echo "Installation finished with errors, version file not created." | sudo tee -a $FULA_LOG_PATH
    if [ "$arch" == "RK1" ] || [ "$arch" == "RPI4" ]; then
      if [ -f "$FULA_PATH/control_led.py" ]; then
        python ${FULA_PATH}/control_led.py red 5 2>&1 | sudo tee -a $FULA_LOG_PATH || true
      fi
    fi
  fi
}

function remove_wifi_connections() {
    # Get a list of all connection names
    local wifi_connections
    wifi_connections=$(nmcli con show | grep wifi | awk '{print $1}')


    # Iterate over each connection
    for conn in $wifi_connections; do
        echo "Removing Wi-Fi connection: $conn" | sudo tee -a $FULA_LOG_PATH
        sudo nmcli con delete "$conn" 2>&1 | sudo tee -a $FULA_LOG_PATH
    done
}

function dockerPull() {
  local service image tar_path latest_release_url latest_release_tag download_url

  echo "Start polling images..." | sudo tee -a $FULA_LOG_PATH
  
  # Get the latest release tag from GitHub
  latest_release_url="https://api.github.com/repos/functionland/fula-ota/releases/latest"
  latest_release_tag=$(curl --retry 2 -s $latest_release_url | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
  
  # Check if the curl command succeeded and a tag was found
  if [[ -z "$latest_release_tag" ]]; then
    echo "Failed to retrieve the latest release tag from GitHub." | sudo tee -a $FULA_LOG_PATH
  fi

  # Get list of services from the docker-compose.yml file
  services=$(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" config --services)

  for service in $services; do
    image=$(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" config | awk '$1 == "image:" { print $2 }' | grep "$service")
    tar_path="${DOCKER_DIR}/${service}.tar"  # Construct the path from the service name

    # First, try to pull from Docker Hub if internet is available
    if check_internet; then
      if docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull "$service"; then
        echo "$service image successfully pulled from Docker Hub."
      else
        echo "$service image pull failed from Docker Hub, attempting to download from GitHub."

        # If pull fails, try to download the latest image from GitHub
        if [[ -n "$latest_release_tag" ]]; then
          download_url="https://github.com/functionland/fula-ota/releases/download/${latest_release_tag}/${service}.tar"
          echo "Attempting to download $service from $download_url"
          if [ -f $tar_path ] ; then
            echo "load $service from local file."
            docker load -i "$tar_path" || echo "Failed to load $image from downloaded $tar_path"
          else  
            if sudo curl --retry 5 -L $download_url -o "$tar_path"; then
              echo "Successfully downloaded $service from GitHub."
              docker load -i "$tar_path" || echo "Failed to load $image from downloaded $tar_path"
            else
              echo "Failed to download $service tar file from GitHub."
            fi
          fi
        fi
      fi
    else
      echo "Internet is not available. Attempting to load $service image from local storage."
      # If internet is not available, try to load from local storage
      if [ -f "$tar_path" ]; then
        docker load -i "$tar_path" || echo "Failed to load $image from $tar_path"
      else
        echo "Local tar file for $service is not found."
      fi
    fi
  done
}

function connectwifi() {
  # Check internet connection and setup WiFi if needed
  if [ -f "$WIFI_SC" ]; then
    if ! check_internet; then
      echo "connectwifi: Waiting for Wi-Fi adapter to be ready..." | sudo tee -a $FULA_LOG_PATH
      sleep 15
      bash $WIFI_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Wifi setup failed" | sudo tee -a $FULA_LOG_PATH; }
      sleep 15
    else
      echo "connectwifi: Already has internet..." | sudo tee -a $FULA_LOG_PATH
    fi
  fi
}
function dockerComposeUp() {
  local service image tar_path

  # Get list of services from the docker-compose.yml file
  services=$(docker-compose --env-file "$ENV_FILE" config --services)

  # Attempt to start each service individually
  for service in $services; do
    pullFailed=0
    image=$(docker-compose config | awk '$1 == "image:" { print $2 }' | grep "$service")
    tar_path="${DOCKER_DIR}/${service}.tar"  # Directly construct the path from the service name

    # Check for internet connectivity before pulling from Docker Hub
    if check_internet; then
      echo "Internet is available. Attempting to pull $service image"
      if ! docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull "$service"; then
        echo "$service image pull failed, using local version" | sudo tee -a $FULA_LOG_PATH
        pullFailed=1
      fi
    else
      pullFailed=1
      echo "Internet is not available. Skipping pull for $service"
    fi

    # Check if a tar file for the service exists and load it
    # Check if the specified service image exists locally
    current_image=$(docker images -q $image)
    if [ -f "$tar_path" ] && [ "$pullFailed" -eq 1 ] && [ -z "$current_image" ]; then
      echo "Loading $image from local file $tar_path"
      docker load -i "$tar_path" || echo "Failed to load $image from $tar_path"
    fi

    echo "Starting $service..." | sudo tee -a $FULA_LOG_PATH

    # Try to start the service
    if ! docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" up -d --no-recreate $service; then
      echo "$service failed to start. Attempting to stop, remove and restart..." | sudo tee -a $FULA_LOG_PATH

      # Get the container ID for the specific service
      container_id=$(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" ps -q $service)
      

      # Check if container_id is not empty
      if [ -n "$container_id" ]; then
        # Stop the failed service's container and remove it
        docker stop $container_id 2>&1 | sudo tee -a $FULA_LOG_PATH
        docker rm -f $container_id 2>&1 | sudo tee -a $FULA_LOG_PATH
      else
        echo "No container ID found for $service, skipping stop and remove." | sudo tee -a $FULA_LOG_PATH
      fi

      # Try to start the service again
      if ! docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" up -d --no-recreate $service; then
        echo "$service failed to start again. Trying to pull the image..." | sudo tee -a $FULA_LOG_PATH

        # Pull the failed service's image and try to start the service again
        (nohup pullFailedServices "$service" > $FULA_LOG_PATH 2>&1 &) >/dev/null 2>&1
        echo "Pull for $service initiated with PID: $!" | sudo tee -a $FULA_LOG_PATH
        disown
        
      fi
    else
      echo "$service started successfully." | sudo tee -a $FULA_LOG_PATH
    fi
  done
}

function dockerComposeDown() {
  echo "dockerComposeDown: killPullImage" | sudo tee -a $FULA_LOG_PATH
  killPullImage 2>&1 | sudo tee -a $FULA_LOG_PATH
  echo "dockerComposeDown: killing done" | sudo tee -a $FULA_LOG_PATH
  # shellcheck disable=SC2046
  if [ $(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file $ENV_FILE ps | wc -l) -gt 2 ]; then
    echo 'Shutting down existing deployment' | sudo tee -a $FULA_LOG_PATH
    docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" down --remove-orphans || true
  fi
}

function dockerComposeBuild() {
  docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" build --no-cache 2>&1 | sudo tee -a $FULA_LOG_PATH
}

function createDir() {
  if [ ! -d "${DATA_DIR}/$1" ]; then
    echo "Creating directory for docker volume $DATA_DIR/$1" | sudo tee -a $FULA_LOG_PATH
    mkdir -p $DATA_DIR/$1 2>&1 | sudo tee -a $FULA_LOG_PATH
  fi
}

function dockerPrune() {
  docker image prune --all --force 2>&1 | sudo tee -a $FULA_LOG_PATH
}

function restart() {
  if [ -d ${FULA_PATH}/kubo ]; then
    sudo chmod -R 755 ${FULA_PATH}/kubo
    if [ -f ${FULA_PATH}/kubo/kubo-container-init.d.sh ]; then
      sudo chmod 755 ${FULA_PATH}/kubo/kubo-container-init.d.sh
    fi
  fi
  if [ -d ${FULA_PATH}/ipfs-cluster ];then
    sudo chmod -R 755 ${FULA_PATH}/ipfs-cluster
    if [ -f ${FULA_PATH}/ipfs-cluster/ipfs-cluster-container-init.d.sh ]; then
      sudo chmod 755 ${FULA_PATH}/ipfs-cluster/ipfs-cluster-container-init.d.sh
    fi
  fi
  # TODO: Find a better solution than opening the permission
  if [ -d /uniondrive ];then
    sudo chmod -R 777 ${FULA_PATH}/uniondrive
    sudo mkdir -p /uniondrive/ipfs_datastore
    if [ -d /uniondrive/ipfs_datastore ]; then
      sudo chmod 777 /uniondrive/ipfs_datastore
      sudo mkdir -p /uniondrive/ipfs_datastore/blocks
      if [ -d /uniondrive/ipfs_datastore/blocks ]; then
        sudo chmod 777 /uniondrive/ipfs_datastore/blocks
      fi
    fi
  fi
  if sudo crontab -l | grep -q "$FULA_PATH/resize.sh"; then
    echo "Resize cron job found, proceeding..."
    # Proceed only if the cron job exists
    if [ -f "$RESIZE_SC" ]; then 
      # Wait for specific flags to indicate completion
      while [ ! -f $partition_flag ] || [ ! -f $resize_flag ]; do
          sleep 1  # Adjust sleep as needed
      done
    else
        echo "Resize script not found" | sudo tee -a $FULA_LOG_PATH
    fi
  else
    echo "Resize cron job not found in crontab" | sudo tee -a $FULA_LOG_PATH
    # Optionally, handle the case when the cron job does not exist
  fi
  mkdir -p ${HOME_DIR}/.internal

  if [ -f "$HW_CHECK_SC" ]; then
    python $HW_CHECK_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Hardware check failed" | sudo tee -a $FULA_LOG_PATH; } || true
  fi
  sleep 1

  # Check if $HOME_DIR/V6.info exists
  if [ ! -f ${HOME_DIR}/V6.info ]; then
      install 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error install" | sudo tee -a $FULA_LOG_PATH; }
      if [ -f ${HOME_DIR}/V6.info ] && [ -f "$HOME_DIR/go_fula_version.info" ]; then
        # remove_wifi_connections 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing wifi connectins" | sudo tee -a $FULA_LOG_PATH; }
        sudo reboot
      fi
  fi

  if [ -f "$RM_DUP_NETWORK_SC" ]; then
    python $RM_DUP_NETWORK_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Remove duplicate network failed" | sudo tee -a $FULA_LOG_PATH; } || true
  fi

  if [ -f $HOME_DIR/update.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/update.pid) 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error Killing update Process" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/update.pid 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error removing update.pid" | sudo tee -a $FULA_LOG_PATH; } || true
  fi

  if [ -f "$UPDATE_SC" ]; then
    sudo bash $UPDATE_SC 2>&1 | sudo tee -a $FULA_LOG_PATH > /dev/null &
    echo $! | sudo tee $HOME_DIR/update.pid > /dev/null
    echo "Ran $UPDATE_SC" | sudo tee -a $FULA_LOG_PATH
  fi

  echo "dockerComposeDown" | sudo tee -a $FULA_LOG_PATH
  dockerComposeDown 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "dockerComposeDown failed" | sudo tee -a $FULA_LOG_PATH; } || true
  echo "dockerComposeUp" | sudo tee -a $FULA_LOG_PATH
  dockerComposeUp 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "dockerComposeUp failed" | sudo tee -a $FULA_LOG_PATH; } || true

  # Remove dangling images
  if docker image prune --filter="dangling=true" -f; then
    { echo "pruning unused dockers..." | sudo tee -a $FULA_LOG_PATH; }  || true
  fi
}


function remove() {
  echo "Removing Fula ..." | sudo tee -a $FULA_LOG_PATH
  killPullImage 2>&1 | sudo tee -a $FULA_LOG_PATH
  if service_exists fula.service; then
    systemctl stop fula.service -q
    systemctl disable fula.service -q
  fi
  rm -f $SYSTEMD_PATH/fula.service
  rm -rf "${FULA_PATH:?}/" || { echo "could not remove FULA_PATH"; } || true

  if service_exists uniondrive.service; then
    systemctl stop uniondrive.service -q
    systemctl disable uniondrive.service -q
  fi
  rm -f $SYSTEMD_PATH/uniondrive.service

  if service_exists commands.service; then
    systemctl stop commands.service -q
    systemctl disable commands.service -q
  fi
  rm -f $SYSTEMD_PATH/commands.service

  if service_exists fula-readiness-check.service; then
    systemctl stop fula-readiness-check.service -q
    systemctl disable fula-readiness-check.service -q
  fi
  rm -f $SYSTEMD_PATH/fula-readiness-check.service

  systemctl daemon-reload
  dockerPrune
  echo "Removing Fula Finished" | sudo tee -a $FULA_LOG_PATH
}

function rebuild() {
  remove
  install
}

# Define the default interval between checks (in seconds)
DEFAULT_INTERVAL=360
# Define the default maximum number of attempts
DEFAULT_MAX_ATTEMPTS=10

# pullFailedServices: Optionally takes a single service name as an argument.
# If no argument is given, operates on all services.
# shellcheck disable=SC2120
function pullFailedServices() {
  # If a parameter is provided, consider it as a single service
  if [ $# -gt 0 ]; then
    SERVICES=$1
  else
    # Otherwise get all services from the docker-compose file
    SERVICES=$(docker-compose --env-file "$ENV_FILE" config --services)
  fi

  while :; do
    for service in $SERVICES; do
      # Check if the service is running
      if ! status=$(docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" ps -q $service | xargs docker inspect --format='{{.State.Status}}' 2>/dev/null) || [[ $status != "running" ]]; then
        # Pull the latest image
        if check_internet; then
          echo "Start polling $service images..." | sudo tee -a $FULA_LOG_PATH
          if [ -s "${DOCKER_DIR}/docker-compose.yml" ]; then
            echo "Pulling $service" | sudo tee -a $FULA_LOG_PATH
            # shellcheck disable=SC2046
            if docker-compose -f "${DOCKER_DIR}/docker-compose.yml" --env-file "$ENV_FILE" pull $service; then
              echo "Successfully pulled $service" | sudo tee -a $FULA_LOG_PATH
            else
              echo "Failed to get $service" | sudo tee -a $FULA_LOG_PATH
            fi
          fi
        fi
      fi
    done

    attempts=$((attempts + 1))
    if [ $attempts -ge $DEFAULT_MAX_ATTEMPTS ]; then
      echo "Maximum number of attempts reached for service $service. Exiting..." | sudo tee -a $FULA_LOG_PATH
      break 1
    fi
    # Wait before checking again
    echo "Next Time Will be " $DEFAULT_INTERVAL " Seconds Later..." | sudo tee -a $FULA_LOG_PATH
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
  arch=${2:-RK1}
  echo "ran install at: $(date) for $arch" | sudo tee -a $FULA_LOG_PATH
  
  if [ "$arch" == "RK1" ] || [ "$arch" == "RPI4" ]; then
    if [ -f "$FULA_PATH/control_led.py" ]; then
      python ${FULA_PATH}/control_led.py light_purple 9000 &
    fi
  fi
  install "$arch" 2>&1 | sudo tee -a $FULA_LOG_PATH
  ;;
"start" | "restart")
  arch=${2:-RK1}
  echo "ran start V6 at: $(date) for $arch" | sudo tee -a $FULA_LOG_PATH

  if [ -z "$ENV_FILE" ]; then
    echo "ENV_FILE variable is not set" | sudo tee -a $FULA_LOG_PATH
  elif [ ! -f "$ENV_FILE" ]; then
    echo "ENV_FILE ($ENV_FILE) does not exist" | sudo tee -a $FULA_LOG_PATH
  elif ! . "${ENV_FILE}" 2>&1 | sudo tee -a $FULA_LOG_PATH; then
    echo "Failed to source ENV_FILE ($ENV_FILE)" | sudo tee -a $FULA_LOG_PATH
  else
    echo "Sourced ENV_FILE ($ENV_FILE) successfully" | sudo tee -a $FULA_LOG_PATH
  fi
  # Store the last modification time of the "stop_docker_copy.txt" file
  last_modification_time_stop_docker=$(stat -c %Y /home/pi/stop_docker_copy.txt 2>/dev/null || echo 0)

  # Get the creation time of the Docker image "functionland/fxsupport:release"
  last_pull_time_docker=$(sudo docker inspect --format='{{.Created}}' "$FX_SUPPROT" 2>/dev/null || echo "1970-01-01T00:00:00Z")
  last_pull_time_docker=$(date -d"$last_pull_time_docker" +%s)
  echo "docker cp for $FX_SUPPROT : last_pull_time_docker= $last_pull_time_docker and last_modification_time_stop_docker= $last_modification_time_stop_docker" | sudo tee -a $FULA_LOG_PATH;
  
  if [ "$last_pull_time_docker" -gt "$last_modification_time_stop_docker" ] || ! find /home/pi -name stop_docker_copy.txt -mmin -1440 | grep -q 'stop_docker_copy.txt'; then
    sudo docker cp fula_fxsupport:/linux/. ${FULA_PATH}/ 2>&1 | sudo tee -a $FULA_LOG_PATH
    echo "docker cp status=> $?" | sudo tee -a $FULA_LOG_PATH
  else
    echo "File stop_docker_copy.txt has been modified in the last 24 hours or docker image was not pulled after the file was modified, skipping docker cp command." | sudo tee -a $FULA_LOG_PATH
  fi
  sync
  echo "sync status=> $?" | sudo tee -a $FULA_LOG_PATH 
  if ! restart 2>&1 | sudo tee -a $FULA_LOG_PATH; then
    echo "restart command failed" | sudo tee -a $FULA_LOG_PATH
  fi
  echo "restart V6 status=> $?" | sudo tee -a $FULA_LOG_PATH
  ;;
"stop")
  arch=${2:-RK1}
  echo "ran stop at: $(date) for $arch" | sudo tee -a $FULA_LOG_PATH
  dockerComposeDown

  if [ -f $HOME_DIR/update.pid ]; then
    # shellcheck disable=SC2046
    kill $(cat $HOME_DIR/update.pid) || { echo "Error Killing update Process" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo rm $HOME_DIR/update.pid  | sudo tee -a $FULA_LOG_PATH || { echo "Error removing update.pid" | sudo tee -a $FULA_LOG_PATH; } || true
  fi
  
  if [ "$arch" == "RK1" ] || [ "$arch" == "RPI4" ]; then
    if [ -f "$FULA_PATH/control_led.py" ]; then
      python ${FULA_PATH}/control_led.py red 0 2>&1 | sudo tee -a $FULA_LOG_PATH
    fi
  fi
  ;;
"rebuild")
  echo "ran rebuild at: $(date)" | sudo tee -a $FULA_LOG_PATH
  rebuild
  ;;
"removeall")
  echo "ran removeall at: $(date)" | sudo tee -a $FULA_LOG_PATH
  containers=$(docker ps -a -q)
  if [ -n "$containers" ]; then
      # shellcheck disable=SC2086
      docker rm -f $containers
  else
      echo "No containers to remove" | sudo tee -a $FULA_LOG_PATH
  fi
  remove
  ;;
"update")
  echo "ran update at: $(date)" | sudo tee -a $FULA_LOG_PATH
  dockerPull "${@:2}"
  ;;
"pull-failed")
  echo "ran pull-failed at: $(date)" | sudo tee -a $FULA_LOG_PATH
  pullFailedServices
  ;;
esac
