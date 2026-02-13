#!/usr/bin/env bash
#
# Copyright (C) 2023 functionland
# SPDX-License-Identifier: AGPL-3.0-only
#
# Adapted UID parsing logic - Line 31-40
# fula-ota v6.1.0

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
VERSION_FILE="${HOME_DIR}/.internal/ipfs_data/version"

DATA_DIR=$FULA_PATH
if [ $# -gt 1 ]; then
  DATA_DIR=$2
fi

ENV_FILE="$FULA_PATH/.env"
DOCKER_DIR=$FULA_PATH

if [ -d /sys/module/rockchipdrm ]; then
    arch=RK1
else
    arch=RPI4
fi

declare -x CURRENT_USER
CURRENT_USER=$(whoami)
export MOUNT_PATH=/media/$CURRENT_USER

function setup_logrotate {
    # Check if logrotate is installed
    if ! command -v logrotate &> /dev/null; then
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
    rotate 3
    compress
    missingok
    notifempty
    create 0640 root root
    copytruncate
    maxsize 20M
    maxage 7
    dateext
    dateformat -%Y%m%d
    delaycompress
}
EOF

    # Check if the existing config file is different than the temp config
    if [ ! -f ${config_path} ] || ! cmp -s ${config_path} ${temp_config_path}; then
        # If they differ, replace the old config with the new one
        sudo mv ${temp_config_path} ${config_path}
        echo "Logrotate configuration file for $logfile_path has been updated."
        sudo chown root:root ${config_path}
        sudo chmod 644 ${config_path}

        # Force logrotate to read the new configuration
        sudo logrotate -f ${config_path}
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

setup_storage_access() {
    local setup_flag="${HOME_DIR}/.storage_setup"
    local smb_conf="/etc/samba/smb.conf"
    local shared_folder="/uniondrive/fxblox"

    # Check if setup has already been done
    if [ -f "$setup_flag" ]; then
        echo "Storage access already set up."
        sudo mkdir -p "$shared_folder"
        sync
        sleep 1
        sudo chown -R pi:pi "$shared_folder"
        sudo chmod 777 -R "$shared_folder"
        sleep 1
        sleep 2
        
        # Ensure Samba configuration and user are properly set up
        echo "Verifying Samba configuration..."
        
        # Check and add SharedFolder configuration if missing
        if ! grep -q "\[SharedFolder\]" "$smb_conf" 2>/dev/null; then
            echo "Adding missing SharedFolder configuration..."
            local smb_config="[SharedFolder]
path = $shared_folder
browseable = yes
writable = yes
guest ok = yes
read only = no
create mask = 0777
directory mask = 0777"
            echo "" | sudo tee -a "$smb_conf" > /dev/null
            echo -e "$smb_config" | sudo tee -a "$smb_conf" > /dev/null
        fi
        
        # Ensure pi user exists in Samba
        if ! sudo pdbedit -L | grep -q "pi"; then
            echo "Adding missing Samba user 'pi'..."
            # Check if pi user exists in system
            if ! id "pi" &>/dev/null; then
                echo "Creating pi user..."
                sudo useradd -m -s /bin/bash pi
                echo "pi:fxblox" | sudo chpasswd
            fi
            
            # Add pi user to Samba
            if [ "${arch}" == "RPI4" ]; then
                echo -e "raspberry\nraspberry" | sudo smbpasswd -a pi 2>/dev/null || {
                    echo -e "raspberry\nraspberry" | sudo smbpasswd pi
                }
            else
                echo -e "fxblox\nfxblox" | sudo smbpasswd -a pi 2>/dev/null || {
                    echo -e "fxblox\nfxblox" | sudo smbpasswd pi
                }
            fi
        fi
        
        # Check if smbd service exists and handle it properly
        if service_exists "smbd"; then
            echo "Restarting smbd service..."
            sudo systemctl restart smbd
        elif service_exists "samba"; then
            echo "Restarting samba service..."
            sudo systemctl restart samba
        else
            echo "Warning: Neither smbd nor samba service found. Installing and setting up Samba..."
            # Install Samba if not already installed
            if ! dpkg -s samba samba-common-bin >/dev/null 2>&1; then
                echo "Installing Samba..."
                sudo apt update
                sudo apt install -y samba samba-common-bin
            fi
            
            # Enable and start the service
            if service_exists "smbd"; then
                sudo systemctl enable smbd
                sudo systemctl start smbd
            elif service_exists "samba"; then
                sudo systemctl enable samba
                sudo systemctl start samba
            fi
        fi
        return 0
    fi

    # Wait for uniondrive to be mounted
    while [ ! -d "/uniondrive" ]; do
        echo "Waiting for uniondrive to be mounted..."
        sleep 5
    done

    # Install Samba if not already installed
    if ! dpkg -s samba samba-common-bin >/dev/null 2>&1; then
        echo "Installing Samba..."
        sudo apt update
        sudo apt install -y samba samba-common-bin
    fi

    # Create shared folder
    sudo mkdir -p "$shared_folder"
    sync 
    sleep 1
    sudo chown -R pi:pi "$shared_folder"
    sudo chmod 777 -R "$shared_folder"
    sleep 1

    # Configure Samba
    local smb_config="[SharedFolder]
path = $shared_folder
browseable = yes
writable = yes
guest ok = yes
read only = no
create mask = 0777
directory mask = 0777"

    # Configure Samba - ensure SharedFolder section is added
    if ! grep -q "\[SharedFolder\]" "$smb_conf" 2>/dev/null; then
        echo "Adding SharedFolder configuration to Samba..."
        echo "" | sudo tee -a "$smb_conf" > /dev/null
        echo "$smb_config" | sudo tee -a "$smb_conf" > /dev/null
    else
        echo "SharedFolder configuration already exists in Samba config."
        # Update existing configuration if different
        if ! diff <(echo "$smb_config") <(sed -n '/\[SharedFolder\]/,/^$/p' "$smb_conf" | head -n -1) > /dev/null 2>&1; then
            echo "Updating existing SharedFolder configuration..."
            sudo sed -i '/\[SharedFolder\]/,/^$/d' "$smb_conf"
            echo "" | sudo tee -a "$smb_conf" > /dev/null
            echo "$smb_config" | sudo tee -a "$smb_conf" > /dev/null
        fi
    fi

    # Set up Samba user - ensure pi user exists in system first
    echo "Setting up Samba user..."
    
    # Check if pi user exists in system
    if ! id "pi" &>/dev/null; then
        echo "Creating pi user..."
        sudo useradd -m -s /bin/bash pi
        echo "pi:fxblox" | sudo chpasswd
    fi
    
    # Add pi user to Samba with appropriate password
    if [ "${arch}" == "RPI4" ]; then
        echo "Adding pi user to Samba with raspberry password..."
        echo -e "raspberry\nraspberry" | sudo smbpasswd -a pi 2>/dev/null || {
            echo "Failed to add pi user to Samba, trying to update existing user..."
            echo -e "raspberry\nraspberry" | sudo smbpasswd pi
        }
    else
        echo "Adding pi user to Samba with fxblox password..."
        echo -e "fxblox\nfxblox" | sudo smbpasswd -a pi 2>/dev/null || {
            echo "Failed to add pi user to Samba, trying to update existing user..."
            echo -e "fxblox\nfxblox" | sudo smbpasswd pi
        }
    fi
    
    # Verify Samba user was created
    if sudo pdbedit -L | grep -q "pi"; then
        echo "Samba user 'pi' successfully configured."
    else
        echo "Warning: Failed to configure Samba user 'pi'."
    fi

    # Restart Samba service
    echo "Restarting Samba service..."
    if service_exists "smbd"; then
        sudo systemctl enable smbd
        sudo systemctl restart smbd
    elif service_exists "samba"; then
        sudo systemctl enable samba
        sudo systemctl restart samba
    else
        echo "Error: Neither smbd nor samba service found after installation. This should not happen."
        return 1
    fi

    # Create setup flag
    touch "$setup_flag"
    echo "Storage access setup completed."
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

    if [ ! -d "/sys/module/rockchipdrm" ]; then
      # Check if RPi.GPIO is installed
      python -c "import RPi.GPIO" 2>/dev/null || {
        echo "RPi.GPIO not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
        sudo apt-get install -y python3-rpi.gpio 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not apt-get install python3-rpi.gpio" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
      }
    fi

    # Check if pexpect is installed
    python -c "import pexpect" 2>/dev/null || {
      echo "pexpect not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y python3-pexpect 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not apt install python3-pexpect" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
    }

    # Check if requests is installed
    python -c "import requests" 2>/dev/null || {
      echo "requests not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y python3-requests 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not apt install python3-requests" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
    }

    # Check if psutil is installed
    python -c "import psutil" 2>/dev/null || {
      echo "psutil not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
      sudo apt-get install -y python3-psutil 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not apt install python3-psutil" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
    }
  else
    echo "Internet check failed, checking for existing dependencies..." 2>&1 | sudo tee -a $FULA_LOG_PATH
    command -v pip >/dev/null 2>&1 || { echo "pip not found"; all_success=false; }
    command -v inotifywait >/dev/null 2>&1 || { echo "inotifywait not found"; all_success=false; }
    command -v mergerfs >/dev/null 2>&1 || { echo "mergerfs not found"; all_success=false; }
    python -c "import dbus" 2>/dev/null || { echo "python3-dbus not found"; all_success=false; }
    if [ ! -d "/sys/module/rockchipdrm" ]; then
      python -c "import RPi.GPIO" 2>/dev/null || { echo "RPi.GPIO not found"; all_success=false; }
    fi
    python -c "import requests" 2>/dev/null || { echo "requests not found"; all_success=false; }
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
    cp ${INSTALLATION_FULA_DIR}/plugins.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file plugins.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/service.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file service.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/bluetooth.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file bluetooth.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/bletools.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file bletools.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/go_server_client.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file go_server_client.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/local_command_server.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file local_command_server.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/bluetooth.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file bluetooth.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/update.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file update.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/docker_rm_duplicate_network.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file docker_rm_duplicate_network.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/commands.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file commands.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/repairfs.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file repairfs.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/check-mount.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file check-mount.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/readiness-check.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file readiness-check.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/update_kubo_config.py $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file update_kubo_config.py" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/automount.sh $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file automount.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/version $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file version" | sudo tee -a $FULA_LOG_PATH; } || true


    cp -r ${INSTALLATION_FULA_DIR}/kubo $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying kubo folder" | sudo tee -a $FULA_LOG_PATH; } || true
    cp -r ${INSTALLATION_FULA_DIR}/ipfs-cluster $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying ipfs-cluster folder" | sudo tee -a $FULA_LOG_PATH; } || true
    cp -r ${INSTALLATION_FULA_DIR}/plugins $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying plugins folder" | sudo tee -a $FULA_LOG_PATH; } || true


    sudo chmod -R 755 ${FULA_PATH}/kubo
    sudo chmod -R 755 ${FULA_PATH}/ipfs-cluster
    sudo chmod -R 755 ${FULA_PATH}/plugins
    
    # Set execute permissions for shell scripts to prevent permission denied errors
    sudo chmod +x ${FULA_PATH}/fula.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on fula.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/union-drive.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on union-drive.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/resize.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on resize.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/wifi.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on wifi.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/bluetooth.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on bluetooth.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/update.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on update.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/commands.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on commands.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/repairfs.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on repairfs.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/check-mount.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on check-mount.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/automount.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on automount.sh" | sudo tee -a $FULA_LOG_PATH; } || true
    sudo chmod +x ${FULA_PATH}/plugins.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error setting permissions on plugins.sh" | sudo tee -a $FULA_LOG_PATH; } || true

    cp ${INSTALLATION_FULA_DIR}/fula.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file fula.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/commands.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file commands.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/uniondrive.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file uniondrive.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/fula-readiness-check.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file fula-readiness-check.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/automount@.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file automount@.service" | sudo tee -a $FULA_LOG_PATH; } || true
    cp ${INSTALLATION_FULA_DIR}/fula-plugins.service $FULA_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying file fula-plugins.service" | sudo tee -a $FULA_LOG_PATH; } || true

  else
    echo "Source and destination are the same, skipping copy" | sudo tee -a $FULA_LOG_PATH
  fi
  sudo mv ${FULA_PATH}/fula.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying fula.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/commands.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying commands.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/uniondrive.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying uniondrive.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/fula-readiness-check.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying fula-readiness-check.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/automount@.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying automount@.service" | sudo tee -a $FULA_LOG_PATH; } || true
  sudo mv ${FULA_PATH}/fula-plugins.service $SYSTEMD_PATH/ 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error copying fula-plugins.service" | sudo tee -a $FULA_LOG_PATH; } || true

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

  if [ -f "$FULA_PATH/plugins.sh" ]; then 
    # Check if fula.sh is executable 
    if [ ! -x "$FULA_PATH/plugins.sh" ]; then 
      echo "$FULA_PATH/plugins.sh is not executable, changing permissions..." | sudo tee -a $FULA_LOG_PATH
      sudo chmod +x $FULA_PATH/plugins.sh 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error chmod file plugins.sh" | sudo tee -a $FULA_LOG_PATH; }
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

  # Install bootup reset service for fresh installations
  install_bootup_reset || { echo "Error installing bootup reset service" | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
  echo "Installing bootup-reset service Finished" | sudo tee -a $FULA_LOG_PATH

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
      bash $WIFI_SC 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Wifi setup failed" | sudo tee -a $FULA_LOG_PATH; } || true
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
      else
        # Save the newly pulled image to tar file
        echo "Saving $image to $tar_path" | sudo tee -a $FULA_LOG_PATH
        if ! docker save "$image" -o "$tar_path.tmp" 2>/dev/null; then
          echo "Failed to save $image to $tar_path.tmp" | sudo tee -a $FULA_LOG_PATH
        else
          # Safely replace the existing tar file
          mv -f "$tar_path.tmp" "$tar_path" 2>/dev/null || rm -f "$tar_path.tmp"
          echo "Successfully saved $image to $tar_path" | sudo tee -a $FULA_LOG_PATH
        fi
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
        disown $!
        
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
    mkdir -p $DATA_DIR/$1 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "mkdir directory for docker volume failed" | sudo tee -a $FULA_LOG_PATH; } || true
  fi
}

function dockerPrune() {
  docker image prune --all --force 2>&1 | sudo tee -a $FULA_LOG_PATH
}

migrate_to_pebble() {
    local CONFIG_FILE="/home/pi/.internal/ipfs_config"
    local PEBBLE_FLAG="/home/pi/.ipfs_pebble"
    local DATASTORE_SPEC="/home/pi/.internal/ipfs_data/datastore_spec"
    local IPFS_DATA_CONFIG="/home/pi/.internal/ipfs_data/config"

    # Check if config file exists
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "IPFS config file not found"
        return 1
    fi

    # Check if pebble flag doesn't exist
    if [ ! -f "$PEBBLE_FLAG" ]; then
        # Update the ipfs_config file
        sed -i 's/"type": "levelds"/"type": "pebbleds"/g' "$CONFIG_FILE"
        sed -i 's/"prefix": "leveldb.datastore"/"prefix": "pebble.datastore"/g' "$CONFIG_FILE"
        
        # Update the datastore_spec file if it exists
        if [ -f "$DATASTORE_SPEC" ]; then
            sed -i 's/"type":"levelds"/"type":"pebbleds"/g' "$DATASTORE_SPEC"
        fi

        # Update the ipfs_data config file if it exists
        if [ -f "$IPFS_DATA_CONFIG" ]; then
            sed -i 's/"type":"levelds"/"type":"pebbleds"/g' "$IPFS_DATA_CONFIG"
        fi
        
        # Clean up the datastore
        if [ -d "/uniondrive/ipfs_datastore/datastore" ]; then
          sudo rm -rf /uniondrive/ipfs_datastore/datastore/*
        fi
        
        # Create pebble flag file
        touch "$PEBBLE_FLAG"
        
        echo "Migration to pebble completed"
    else
        echo "Pebble migration has already been performed"
    fi
}


# Install bootup reset service for device reset functionality
function install_bootup_reset() {
  local service_name="bootup-reset"
  local service_file="${SYSTEMD_PATH}/${service_name}.service"
  local action_script="${FULA_PATH}/bootup_reset_action.py"
  
  echo "Checking bootup-reset service..." | sudo tee -a $FULA_LOG_PATH
  
  # Check if service already exists
  if systemctl list-unit-files | grep -q "^${service_name}.service"; then
    echo "bootup-reset service already exists, skipping installation" | sudo tee -a $FULA_LOG_PATH
    return 0
  fi
  
  echo "Installing bootup-reset service..." | sudo tee -a $FULA_LOG_PATH
  
  # Create the Python action script
  cat > /tmp/bootup_reset_action.py << 'EOF'
#!/usr/bin/env python3
"""
Bootup Reset Action Script
Handles device reset logic based on boot frequency and WiFi connections
"""

import os
import sys
import time
import subprocess
import logging
from pathlib import Path

# Configuration
HOME_DIR = "/home/pi"
FULA_PATH = "/usr/bin/fula"
BOOT_TIMESTAMP_FILE = f"{HOME_DIR}/boot.tmp"
CONFIG_FILE = f"{HOME_DIR}/.internal/config.yaml"
CONTROL_LED_SCRIPT = f"{FULA_PATH}/control_led.py"
LOG_FILE = f"{HOME_DIR}/fula.sh.log"
MAX_TIMESTAMP_RECORDS = 10
RESET_TIME_WINDOW = 15 * 60  # 15 minutes in seconds

# Setup logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.FileHandler(LOG_FILE, mode='a'),
        logging.StreamHandler()
    ]
)
logger = logging.getLogger(__name__)

def get_current_timestamp():
    """Get current timestamp in seconds with time sync attempt"""
    logger.info("=== Getting current timestamp ===")
    
    # Log system time info
    try:
        date_output = subprocess.run(['date'], capture_output=True, text=True)
        logger.info(f"System date command output: {date_output.stdout.strip()}")
    except Exception as e:
        logger.error(f"Error getting system date: {e}")
    
    # Try to force time sync
    try:
        logger.info("Attempting to sync time with systemd-timesyncd...")
        subprocess.run(['systemctl', 'restart', 'systemd-timesyncd'], check=False, timeout=5)
        time.sleep(3)  # Wait for sync
        
        # Check if timedatectl is available
        timedatectl_output = subprocess.run(['timedatectl', 'status'], capture_output=True, text=True, timeout=5)
        if timedatectl_output.returncode == 0:
            logger.info(f"timedatectl status: {timedatectl_output.stdout[:200]}...")  # Truncate long output
    except Exception as e:
        logger.warning(f"Time sync attempt failed: {e}")
    
    # Get timestamp
    current_time = int(time.time())
    logger.info(f"Final timestamp: {current_time}")
    
    # Flash yellow LED for 2 seconds to indicate timestamp recording
    try:
        subprocess.run(['python3', CONTROL_LED_SCRIPT, 'yellow', '2'], check=True, timeout=5)
        logger.info("Flashed yellow LED for timestamp recording")
    except Exception as e:
        logger.warning(f"Failed to flash yellow LED: {e}")
    
    # Convert to human readable for logging
    try:
        human_time = time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime(current_time))
        logger.info(f"Timestamp in human format: {human_time}")
    except Exception as e:
        logger.error(f"Error converting timestamp to human format: {e}")
    
    return current_time

def read_boot_timestamps():
    """Read last boot timestamps from file"""
    timestamps = []
    try:
        if os.path.exists(BOOT_TIMESTAMP_FILE):
            with open(BOOT_TIMESTAMP_FILE, 'r') as f:
                lines = f.read().strip().split('\n')
                # Get last 4 lines (or all if less than 4)
                timestamps = [int(line.strip()) for line in lines[-4:] if line.strip().isdigit()]
        logger.info(f"Read {len(timestamps)} timestamps from boot file")
    except Exception as e:
        logger.error(f"Error reading boot timestamps: {e}")
    return timestamps

def check_reset_conditions(timestamps, current_timestamp):
    """Check if reset conditions are met"""
    # Need at least 4 previous timestamps plus current one (total 5)
    if len(timestamps) < 4:
        logger.info(f"Only {len(timestamps)} previous timestamps, need 4 for reset check")
        return False
    
    # Add current timestamp to check 5 total timestamps
    all_timestamps = timestamps + [current_timestamp]
    all_timestamps.sort()
    
    # Check if all 5 timestamps are within 15 minutes
    time_window_check = (all_timestamps[-1] - all_timestamps[0]) <= RESET_TIME_WINDOW
    logger.info(f"Time window check (15 min): {time_window_check} - Range: {all_timestamps[-1] - all_timestamps[0]} seconds")
    
    # Check for non-docker, non-FxBlox WiFi connections
    wifi_check = has_user_wifi_connections()
    logger.info(f"User WiFi connection check: {wifi_check}")
    
    return time_window_check and wifi_check

def has_user_wifi_connections():
    """Check if there are WiFi connections other than docker and FxBlox"""
    try:
        result = subprocess.run(['nmcli', 'con', 'show'], capture_output=True, text=True, check=True)
        connections = result.stdout.strip().split('\n')[1:]  # Skip header
        
        for line in connections:
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 3:
                name = parts[0]
                conn_type = parts[2]
                # Check for WiFi connections that are not docker or FxBlox
                if conn_type == 'wifi' and name not in ['docker0', 'FxBlox']:
                    logger.info(f"Found user WiFi connection: {name}")
                    return True
        return False
    except Exception as e:
        logger.error(f"Error checking WiFi connections: {e}")
        return False

def perform_reset_actions():
    """Perform reset actions when conditions are met"""
    logger.info("Reset conditions met, performing reset actions...")
    
    try:
        # 1. Clear timestamp file content
        with open(BOOT_TIMESTAMP_FILE, 'w') as f:
            f.write('')
        logger.info("Cleared boot timestamp file")
        
        # 2. Delete user WiFi connections (keep FxBlox and docker)
        delete_user_wifi_connections()
        
        # 3. Delete config.yaml
        if os.path.exists(CONFIG_FILE):
            os.remove(CONFIG_FILE)
            logger.info(f"Deleted {CONFIG_FILE}")
        
        # 4. Start LED flashing
        start_led_flashing()
        
    except Exception as e:
        logger.error(f"Error during reset actions: {e}")

def delete_user_wifi_connections():
    """Delete WiFi connections except FxBlox and docker"""
    try:
        result = subprocess.run(['nmcli', 'con', 'show'], capture_output=True, text=True, check=True)
        connections = result.stdout.strip().split('\n')[1:]  # Skip header
        
        for line in connections:
            if not line.strip():
                continue
            parts = line.split()
            if len(parts) >= 3:
                name = parts[0]
                conn_type = parts[2]
                # Delete WiFi connections that are not docker or FxBlox
                if conn_type == 'wifi' and name not in ['docker0', 'FxBlox']:
                    try:
                        subprocess.run(['nmcli', 'con', 'delete', name], check=True)
                        logger.info(f"Deleted WiFi connection: {name}")
                    except subprocess.CalledProcessError as e:
                        logger.error(f"Failed to delete WiFi connection {name}: {e}")
    except Exception as e:
        logger.error(f"Error deleting WiFi connections: {e}")

def start_led_flashing():
    """Flash LED blue for 5 seconds"""
    try:
        # Remove persistence file if it exists
        persist_file = f"{HOME_DIR}/control_led.per"
        if os.path.exists(persist_file):
            os.remove(persist_file)
            logger.info("Removed LED persistence file")
        
        if os.path.exists(CONTROL_LED_SCRIPT):
            # Flash blue LED for 5 seconds
            subprocess.run(['python3', CONTROL_LED_SCRIPT, 'blue', '5'], check=True, timeout=10)
            logger.info("Flashed blue LED for 5 seconds")
        else:
            logger.warning(f"LED control script not found: {CONTROL_LED_SCRIPT}")
    except Exception as e:
        logger.error(f"Error flashing LED: {e}")

def update_boot_timestamps(timestamps, current_timestamp):
    """Update boot timestamps file with current timestamp"""
    try:
        # Add current timestamp
        all_timestamps = timestamps + [current_timestamp]
        # Keep only last MAX_TIMESTAMP_RECORDS
        all_timestamps = all_timestamps[-MAX_TIMESTAMP_RECORDS:]
        
        # Write to file
        os.makedirs(os.path.dirname(BOOT_TIMESTAMP_FILE), exist_ok=True)
        with open(BOOT_TIMESTAMP_FILE, 'w') as f:
            for ts in all_timestamps:
                f.write(f"{ts}\n")
        
        logger.info(f"Updated boot timestamps file with {len(all_timestamps)} records")
    except Exception as e:
        logger.error(f"Error updating boot timestamps: {e}")

def main():
    """Main execution function"""
    logger.info("=== Bootup Reset Action Started ===")
    
    try:
        # 1. Record current timestamp
        current_timestamp = get_current_timestamp()
        logger.info(f"Current timestamp: {current_timestamp}")
        
        # 2. Read existing timestamps
        timestamps = read_boot_timestamps()
        
        # 3. Check reset conditions
        if check_reset_conditions(timestamps, current_timestamp):
            # Flash purple LED with persist to indicate reset conditions met
            try:
                subprocess.run(['python3', CONTROL_LED_SCRIPT, 'light_purple', '999999', '--persist'], check=True, timeout=5)
                logger.info("Flashed purple LED with persist for reset conditions")
            except Exception as e:
                logger.warning(f"Failed to flash purple LED: {e}")
            
            perform_reset_actions()
            # After reset actions, record current timestamp in the now-empty file
            update_boot_timestamps([], current_timestamp)
            logger.info("Reset actions completed, recorded current timestamp")
        else:
            # Update timestamp file with current timestamp
            update_boot_timestamps(timestamps, current_timestamp)
            logger.info("Reset conditions not met, updated timestamp file")
        
    except Exception as e:
        logger.error(f"Unexpected error in main: {e}")
        sys.exit(1)
    
    logger.info("=== Bootup Reset Action Completed ===")

if __name__ == "__main__":
    main()
EOF

  # Move the script to the correct location with proper permissions
  sudo mv /tmp/bootup_reset_action.py "$action_script" || {
    echo "Error moving bootup reset action script" | sudo tee -a $FULA_LOG_PATH
    return 1
  }
  sudo chmod +x "$action_script" || {
    echo "Error setting permissions on bootup reset action script" | sudo tee -a $FULA_LOG_PATH
    return 1
  }
  
  # Create the systemd service file
  cat > /tmp/bootup-reset.service << EOF
[Unit]
Description=Bootup Reset Service
After=network.target time-sync.target systemd-timesyncd.service
Wants=network.target time-sync.target
Requires=network.target

[Service]
Type=oneshot
User=root
# Add a delay to ensure time is properly synchronized
ExecStartPre=/bin/sleep 10
ExecStart=/usr/bin/python3 ${action_script}
StandardOutput=append:${FULA_LOG_PATH}
StandardError=append:${FULA_LOG_PATH}
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
EOF

  # Move service file to systemd directory
  sudo mv /tmp/bootup-reset.service "$service_file" || {
    echo "Error moving bootup reset service file" | sudo tee -a $FULA_LOG_PATH
    return 1
  }
  
  # Reload systemd and enable the service
  sudo systemctl daemon-reload || {
    echo "Error reloading systemd daemon" | sudo tee -a $FULA_LOG_PATH
    return 1
  }
  
  sudo systemctl enable "$service_name.service" || {
    echo "Error enabling bootup-reset service" | sudo tee -a $FULA_LOG_PATH
    return 1
  }
  
  echo "Successfully installed bootup-reset service" | sudo tee -a $FULA_LOG_PATH
  return 0
}

function restart() {
  # Moved while loop to after installation
  if [ -d ${FULA_PATH}/kubo ]; then
    sudo chmod -R 755 ${FULA_PATH}/kubo || { echo "chmod /kubo" | sudo tee -a $FULA_LOG_PATH; } || true
    if [ -f ${FULA_PATH}/kubo/kubo-container-init.d.sh ]; then
      sudo chmod 755 ${FULA_PATH}/kubo/kubo-container-init.d.sh || { echo "chmod kubo/.sh failed" | sudo tee -a $FULA_LOG_PATH; } || true
    fi
  fi
  if [ -d ${FULA_PATH}/ipfs-cluster ];then
    sudo chmod -R 755 ${FULA_PATH}/ipfs-cluster || { echo "chmod ipfs-cluster failed" | sudo tee -a $FULA_LOG_PATH; } || true
    if [ -f ${FULA_PATH}/ipfs-cluster/ipfs-cluster-container-init.d.sh ]; then
      sudo chmod 755 ${FULA_PATH}/ipfs-cluster/ipfs-cluster-container-init.d.sh || { echo "chmod ipfs-cluster/.sh failed" | sudo tee -a $FULA_LOG_PATH; } || true
    fi
  fi
  
  setup_logrotate $FULA_LOG_PATH || { echo "Error setting up logrotate" | sudo tee -a $FULA_LOG_PATH; } || true

  # Install bootup reset service for backward compatibility with existing installations
  install_bootup_reset || { echo "Error installing bootup reset service" | sudo tee -a $FULA_LOG_PATH; } || true

  sudo sysctl -w net.core.rmem_max=2500000 || { echo "Could not set net.core.rmem_max" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true
  sudo sysctl -w net.core.wmem_max=2500000 || { echo "Could not set net.core.wmem_max" 2>&1 | sudo tee -a $FULA_LOG_PATH; all_success=false; } || true

  
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
  mkdir -p ${HOME_DIR}/.internal/plugins
  mkdir -p ${HOME_DIR}/.internal/ipfs_data

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

  # Check if the directory exists and the version file contains '15' or '16'
  if [ -d "${HOME_DIR}/.internal/ipfs_data" ] && [ -f "$VERSION_FILE" ]; then
      chmod 777 "$VERSION_FILE"
      case "$(cat "$VERSION_FILE")" in
          15)
              sed -i 's/^15$/17/' "$VERSION_FILE"
              echo "Updated version from 15 to 17 in $VERSION_FILE"
              ;;
          16)
              sed -i 's/^16$/17/' "$VERSION_FILE"
              echo "Updated version from 16 to 17 in $VERSION_FILE"
              ;;
      esac
  fi

  # TODO: Find a better solution than opening the permission
  MOUNT_PATH="/uniondrive"
  SETUP_DONE_FILE="$MOUNT_PATH/setup.done"

  while [ ! -d "$MOUNT_PATH" ] || [ ! -f "$SETUP_DONE_FILE" ]; do
      if [ ! -d "$MOUNT_PATH" ]; then
          echo "Waiting for $MOUNT_PATH directory to be created..."
      elif [ ! -f "$SETUP_DONE_FILE" ]; then
          echo "Waiting for $SETUP_DONE_FILE to be created..."
      fi
      sleep 20  # Wait for 5 seconds before checking again
  done

  #Migrating from leveldb to pebble
  migrate_to_pebble

  if [ -d /uniondrive ]; then
    # Check if main directory or any of the required subdirectories don't have 777 permissions
    if [ "$(stat -c %a /uniondrive)" != "777" ] || \
       [ ! -d "/uniondrive/ipfs_datastore" ] || [ ! -d "/uniondrive/ipfs_staging" ] || [ ! -d "/uniondrive/ipfs-cluster" ] || [ ! -d "/uniondrive/chain" ] || \
       [ -d "/uniondrive/ipfs_datastore" -a "$(stat -c %a /uniondrive/ipfs_datastore)" != "777" ] || \
       [ -d "/uniondrive/ipfs_staging" -a "$(stat -c %a /uniondrive/ipfs_staging)" != "777" ] || \
       [ -d "/uniondrive/chain" -a "$(stat -c %a /uniondrive/chain)" != "777" ] || \
       [ -d "/uniondrive/ipfs-cluster" -a "$(stat -c %a /uniondrive/ipfs-cluster)" != "777" ]; then
        
        echo "Changing permissions for contents of /uniondrive..."
        find /uniondrive \( -type d -o -type f \) ! -perm 777 -print0 | sudo xargs -0 -r chmod -v 777

        # Create all directories in one command
        sudo mkdir -p \
            /uniondrive/ipfs_datastore/blocks \
            /uniondrive/ipfs_datastore/datastore \
            /uniondrive/ipfs_staging \
            /uniondrive/chain \
            /uniondrive/ipfs-cluster || { 
                echo "Failed to create one or more directories" | sudo tee -a $FULA_LOG_PATH
            }

        # Single chmod for all directories since parent directory permissions were already set
        find /uniondrive -type d ! -perm 777 -print0 | sudo xargs -0 -r chmod -v 777
    else
        echo "All required directories exist and have 777 permissions."
    fi
  fi


  # Check if requests is installed
  python -c "import requests" 2>/dev/null || {
    echo "requests not found, installing..." 2>&1 | sudo tee -a $FULA_LOG_PATH
    sudo apt install python3-requests 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Could not apt install python3-requests" 2>&1 | sudo tee -a $FULA_LOG_PATH; } || true
  }

  #setup samba for blox storage access /uniondrive/fxblox
  setup_storage_access
  sleep 2

  # Merge kubo config updates from template into deployed config
  if [ -f "${FULA_PATH}/update_kubo_config.py" ]; then
    echo "Running kubo config merge..." | sudo tee -a $FULA_LOG_PATH
    python3 ${FULA_PATH}/update_kubo_config.py 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "kubo config merge failed" | sudo tee -a $FULA_LOG_PATH; } || true
  else
    echo "update_kubo_config.py not found, running inline fallback merge..." | sudo tee -a $FULA_LOG_PATH
    python3 - "${HOME_DIR}" "${FULA_PATH}" <<'PYEOF' 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "inline kubo config merge failed" | sudo tee -a $FULA_LOG_PATH; } || true
import json, sys, os, shutil
from copy import deepcopy

home_dir = sys.argv[1]
fula_path = sys.argv[2]
deployed_path = os.path.join(home_dir, ".internal", "ipfs_data", "config")
template_path = os.path.join(fula_path, "kubo", "config")
template_copy_path = os.path.join(home_dir, ".internal", "ipfs_config")

if not os.path.isfile(deployed_path):
    print("kubo_config_merge_inline: deployed config not found, skipping")
    sys.exit(0)

try:
    with open(deployed_path) as f:
        deployed = json.load(f)
except Exception as e:
    print(f"kubo_config_merge_inline: failed to read deployed config: {e}")
    sys.exit(0)

# Always use hardcoded values in the inline fallback.
# The on-device template file may also be stale (same problem we're fixing),
# so we cannot trust it as source of truth here.
template = {
        "Bootstrap": [
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
            "/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
            "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
            "/ip4/104.131.131.82/udp/4001/quic-v1/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
            "/ip4/172.65.0.13/tcp/4009/p2p/QmcfgsJsMtx6qJb74akCw1M24X1zFwgGo11h1cuhwQjtJP"
        ],
        "Peering": {"Peers": [
            {"Addrs": ["/dns/relay.dev.fx.land/tcp/4001"],
             "ID": "12D3KooWDRrBaAfPwsGJivBoUw5fE7ZpDiyfUjqgiURq2DEcL835"}
        ]},
        "Swarm": {
            "ConnMgr": {"HighWater": 200, "LowWater": 50, "GracePeriod": "20s"},
            "RelayClient": {
                "Enabled": True,
                "StaticRelays": [
                    "/dns/relay.dev.fx.land/tcp/4001/p2p/12D3KooWDRrBaAfPwsGJivBoUw5fE7ZpDiyfUjqgiURq2DEcL835"
                ]
            }
        },
        "Experimental": {
            "FilestoreEnabled": False,
            "Libp2pStreamMounting": True,
            "OptimisticProvide": True,
            "OptimisticProvideJobsPoolSize": 60,
            "P2pHttpProxy": False,
            "StrategicProviding": False,
            "UrlstoreEnabled": False
        },
        "Addresses": {"Swarm": [
            "/ip4/0.0.0.0/tcp/4001", "/ip6/::/tcp/4001",
            "/ip4/0.0.0.0/udp/4001/quic-v1",
            "/ip4/0.0.0.0/udp/4001/quic-v1/webtransport",
            "/ip6/::/udp/4001/quic-v1",
            "/ip6/::/udp/4001/quic-v1/webtransport"
        ]},
        "Discovery": {"MDNS": {"Enabled": True}},
        "Routing": {"AcceleratedDHTClient": True}
    }

# Managed fields as (dotpath, getter-from-template)
def get_nested(obj, keys):
    cur = obj
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return None, False
        cur = cur[k]
    return cur, True

def set_nested(obj, keys, val):
    cur = obj
    for k in keys[:-1]:
        if k not in cur or not isinstance(cur[k], dict):
            cur[k] = {}
        cur = cur[k]
    cur[keys[-1]] = val

MANAGED = [
    ["Bootstrap"],
    ["Peering", "Peers"],
    ["Swarm", "RelayClient", "StaticRelays"],
    ["Swarm", "RelayClient", "Enabled"],
    ["Swarm", "ConnMgr"],
    ["Experimental"],
    ["Addresses", "Swarm"],
    ["Discovery"],
    ["Routing", "AcceleratedDHTClient"],
]

result = deepcopy(deployed)
changes = []
for field_keys in MANAGED:
    tmpl_val, found = get_nested(template, field_keys)
    if not found:
        continue
    deployed_val, dfound = get_nested(result, field_keys)
    if dfound and deployed_val == tmpl_val:
        continue
    set_nested(result, field_keys, deepcopy(tmpl_val))
    changes.append(".".join(field_keys))

# Dynamic StorageMax based on /uniondrive available space
import shutil as _shutil
try:
    _usage = _shutil.disk_usage("/uniondrive")
    _total_gb = _usage.total / (1024**3)
    _storage_max_gb = int(_total_gb * 0.8)
    _storage_max_gb = max(_storage_max_gb, 800)  # minimum 800GB floor
    _storage_max = f"{_storage_max_gb}GB"
    if "Datastore" not in result:
        result["Datastore"] = {}
    old_max = result.get("Datastore", {}).get("StorageMax", "")
    if old_max != _storage_max:
        result["Datastore"]["StorageMax"] = _storage_max
        changes.append("Datastore.StorageMax")
        print(f"kubo_config_merge_inline: StorageMax set to {_storage_max} (drive total: {_total_gb:.0f}GB)")
except Exception as _e:
    print(f"kubo_config_merge_inline: could not detect /uniondrive size: {_e}")

if not changes:
    print("kubo_config_merge_inline: config already up to date")
    sys.exit(0)

print(f"kubo_config_merge_inline: updating {len(changes)} field(s): {', '.join(changes)}")

# Backup then write
try:
    shutil.copy2(deployed_path, deployed_path + ".bak")
except Exception:
    pass

tmp = deployed_path + ".tmp"
with open(tmp, "w") as f:
    json.dump(result, f, indent=2)
    f.write("\n")
shutil.move(tmp, deployed_path)

# Also update template copy if it exists
if os.path.isfile(template_copy_path):
    try:
        with open(template_copy_path) as f:
            tcopy = json.load(f)
        tcopy_updated = deepcopy(tcopy)
        for field_keys in MANAGED:
            tmpl_val, found = get_nested(template, field_keys)
            if not found:
                continue
            cv, cf = get_nested(tcopy_updated, field_keys)
            if cf and cv == tmpl_val:
                continue
            set_nested(tcopy_updated, field_keys, deepcopy(tmpl_val))
        tmp2 = template_copy_path + ".tmp"
        with open(tmp2, "w") as f:
            json.dump(tcopy_updated, f, indent=2)
            f.write("\n")
        shutil.move(tmp2, template_copy_path)
        print("kubo_config_merge_inline: template copy updated")
    except Exception as e:
        print(f"kubo_config_merge_inline: could not update template copy: {e}")

print("kubo_config_merge_inline: done")
PYEOF
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

  if [ -f "${SYSTEMD_PATH}/fula-plugins.service" ]; then
        echo "Removing fula-plugins service" | sudo tee -a $FULA_LOG_PATH
        sudo systemctl stop fula-plugins
        sudo systemctl disable fula-plugins
        sudo rm fula-plugins
        sudo systemctl daemon-reload
  else
        echo "fula-plugins service is not installed" | sudo tee -a $FULA_LOG_PATH
  fi
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

# Function to compare and copy service files
function copy_service_file() {
    local source_file="$1"
    local dest_file="$2"
    local service_name="$3"

    if ! cmp -s "$source_file" "$dest_file"; then
      echo "Updating $service_name service file" | sudo tee -a $FULA_LOG_PATH
      sudo cp "$source_file" "$dest_file"
      return 0  # File was updated
    else
      echo "$service_name service file is up to date" | sudo tee -a $FULA_LOG_PATH
      return 1  # File was not updated
    fi
}

function process_plugins() {
    local SERVICE_NAME="fula-plugins"
    local SERVICE_FILE="${SYSTEMD_PATH}/${SERVICE_NAME}.service"

    # Function to install and activate the service
    install_service() {
        echo "Installing ${SERVICE_NAME} service" | sudo tee -a $FULA_LOG_PATH
        cat << EOF | sudo tee $SERVICE_FILE > /dev/null
[Unit]
Description=Fula Plugins Service
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/fula/plugins.sh
Restart=on-failure
RestartSec=300
StartLimitInterval=3000
StartLimitBurst=10

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable $SERVICE_NAME
        echo "${SERVICE_NAME} service installed and activated" | sudo tee -a $FULA_LOG_PATH
    }

    # Check if service is installed
    if [ ! -f "$SERVICE_FILE" ]; then
        install_service
    else
        echo "${SERVICE_NAME} service already installed" | sudo tee -a $FULA_LOG_PATH
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
  sync
  sleep 1
  process_plugins
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

  sync
  echo "sync status=> $?" | sudo tee -a $FULA_LOG_PATH 
  if ! restart 2>&1 | sudo tee -a $FULA_LOG_PATH; then
    echo "restart command failed" | sudo tee -a $FULA_LOG_PATH
  fi
  echo "restart V6 status=> $?" | sudo tee -a $FULA_LOG_PATH

  sleep 15
  # Get the creation time of the Docker image "functionland/fxsupport:release"
  last_pull_time_docker_raw=$(sudo docker inspect --format='{{.Created}}' "$FX_SUPPROT" 2>/dev/null || echo "")
  # Parse the ISO 8601 date format - try multiple methods for compatibility
  if [ -n "$last_pull_time_docker_raw" ]; then
    # Try GNU date first (works on most full Linux distros)
    last_pull_time_docker=$(date -d"$last_pull_time_docker_raw" +%s 2>/dev/null) || \
    # Try parsing ISO 8601 format manually (for BusyBox/embedded systems)
    # Extract date part and convert: 2025-12-05T10:30:00.123456789Z -> 2025-12-05 10:30:00
    last_pull_time_docker=$(date -d"$(echo "$last_pull_time_docker_raw" | sed 's/T/ /; s/\.[0-9]*Z$//')" +%s 2>/dev/null) || \
    # Fallback: use 0 (epoch) if all parsing fails
    last_pull_time_docker=0
  else
    last_pull_time_docker=0
  fi
  echo "docker cp for $FX_SUPPROT : last_pull_time_docker= $last_pull_time_docker and last_modification_time_stop_docker= $last_modification_time_stop_docker" | sudo tee -a $FULA_LOG_PATH;
  
  container_status=$(sudo docker inspect --format='{{.State.Status}}' fula_fxsupport 2>/dev/null || echo "not found")
  while [ "$container_status" != "running" ]; do
      echo "Waiting for fula_fxsupport container to be up..." | sudo tee -a $FULA_LOG_PATH
      sleep 5  # Wait for 5 seconds before checking again
      container_status=$(sudo docker inspect --format='{{.State.Status}}' fula_fxsupport 2>/dev/null || echo "not found")
  done
  if [ "$last_pull_time_docker" -gt "$last_modification_time_stop_docker" ] || ! find /home/pi -name stop_docker_copy.txt -mmin -1440 | grep -q 'stop_docker_copy.txt'; then
    declare -A file_info
    for file in fula.sh union-drive.sh; do
      if [ -f "${FULA_PATH}/${file}" ]; then
        size=$(stat -c %s "${FULA_PATH}/${file}")
        mtime=$(stat -c %Y "${FULA_PATH}/${file}")
        file_info["${file}"]="${size}:${mtime}"
      fi
    done
  
    sudo docker cp fula_fxsupport:/linux/. ${FULA_PATH}/ 2>&1 | sudo tee -a $FULA_LOG_PATH
    sleep 2
    sync

    echo "docker cp status=> $?" | sudo tee -a $FULA_LOG_PATH
    # Check if fula.sh or union-drive.sh have changed
    restart_uniondrive=false
    restart_fula=false
    for file in fula.sh union-drive.sh; do
      if [ -f "${FULA_PATH}/${file}" ]; then
        new_size=$(stat -c %s "${FULA_PATH}/${file}")
        new_mtime=$(stat -c %Y "${FULA_PATH}/${file}")
        old_info="${file_info["${file}"]}"
        if [ -n "$old_info" ] && [ "${new_size}:${new_mtime}" != "$old_info" ]; then
          if [ "$file" = "union-drive.sh" ]; then
            restart_uniondrive=true
            restart_fula=true
          elif [ "$file" = "fula.sh" ]; then
            restart_fula=true
          fi
        fi
      fi
    done

    systemd_reload_needed=false
    # Check and update fula.service
    if copy_service_file "${FULA_PATH}/fula.service" "$SYSTEMD_PATH/fula.service" "fula"; then
      systemd_reload_needed=true
      restart_fula=true
    fi

    # Check and update uniondrive.service
    if copy_service_file "${FULA_PATH}/uniondrive.service" "$SYSTEMD_PATH/uniondrive.service" "uniondrive"; then
      systemd_reload_needed=true
      restart_uniondrive=true
    fi

    # Reload systemd if needed
    if [ "$systemd_reload_needed" = true ]; then
      echo "Reloading systemd" | sudo tee -a $FULA_LOG_PATH
      sudo systemctl daemon-reload
    fi

    if [ "$restart_uniondrive" = true ]; then
      echo "union-drive.sh has changed, restarting uniondrive" | sudo tee -a $FULA_LOG_PATH
      sudo systemctl restart uniondrive
    fi

    if [ "$restart_fula" = true ]; then
      echo "fula.sh has changed, calling restart" | sudo tee -a $FULA_LOG_PATH
      if ! restart 2>&1 | sudo tee -a $FULA_LOG_PATH; then
        echo "restart command failed" | sudo tee -a $FULA_LOG_PATH
      fi
    fi
  else
    echo "File stop_docker_copy.txt has been modified in the last 24 hours or remote docker image was not updated after the file was modified, skipping docker cp command." | sudo tee -a $FULA_LOG_PATH
  fi
  sync
  sleep 1
  process_plugins
  if systemctl is-active --quiet fula-plugins; then
      echo "Restarting fula-plugins service" | sudo tee -a $FULA_LOG_PATH
      sudo systemctl restart fula-plugins
  else
      echo "Starting fula-plugins service" | sudo tee -a $FULA_LOG_PATH
      sudo systemctl start fula-plugins
  fi
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
  if systemctl is-active --quiet fula-plugins; then
        echo "Stopping fula-plugins service" | sudo tee -a $FULA_LOG_PATH
        sudo systemctl stop fula-plugins
  else
        echo "fula-plugins service is not running" | sudo tee -a $FULA_LOG_PATH
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
