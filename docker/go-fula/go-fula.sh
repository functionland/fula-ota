#!/bin/sh

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_wifi_name() {
    # Get the name of the currently active Wi-Fi connection.
    wifi_name=$(nmcli -g GENERAL.CONNECTION device show $1)

    # Return 1 (false) if the Wi-Fi name is "FxBlox", or 0 (true) otherwise.
    if [ "$wifi_name" = "FxBlox" ]; then
        return 1
    else
        return 0
    fi
}

check_internet() {
  for iface in /sys/class/net/*; do
    iface_name=$(basename $iface)
    if [ "$iface_name" != "lo" ] && iwconfig $iface_name 2>&1 | grep -q "ESSID" && (ip addr show "$iface_name" | grep -q "inet ") && check_wifi_name $iface_name; then
      return 0
    fi
  done
  return 1
}



check_files_exist() {
  [ -f "/internal/config.yaml" ]
  return $?
}

check_writable() {
  # Check if /internal exists and is writable
  if [ -d "/internal" ]; then
    if ! touch /internal/.tmp_write || ! rm /internal/.tmp_write; then
      log "/internal is not writable."
      return 1
    fi
  else
    log "/internal does not exist."
    return 1
  fi

  # Check if /uniondrive exists and is writable
  if [ -d "/uniondrive" ]; then
    if ! touch /uniondrive/.tmp_write || ! rm /uniondrive/.tmp_write; then
      log "/uniondrive is not writable."
      return 1
    fi
  else
    log "/uniondrive does not exist."
    return 1
  fi

  log "Both /internal and /uniondrive exist and are writable."
  return 0
}

check_interfaces() {
  # Check for required commands
  if ! command -v ip &> /dev/null; then
      log "The 'ip' command is required but not found. Exiting."
      return 1
  fi

  if ! command -v iwconfig &> /dev/null; then
      log "The 'iwconfig' command is required but not found. Exiting."
      return 1
  fi
  # Get a list of all network interfaces
  interfaces=$(iwconfig 2>&1 | grep 'IEEE' | awk '{print $1}')
  if [ -z "$interfaces" ]; then
      log "No wireless network interfaces found. Exiting."
      return 1
  fi

  # Loop through each interface and check its status
  for interface in $interfaces; do
      log "Checking wireless interface: $interface"
      while : ; do
          # Get the current state of the interface
          state=$(ip link show "$interface" | awk '/state UP/ {print $9}')

          # Check if the interface is in the 'UP' state
          if [ "$state" = "UP" ]; then
              log "Interface $interface is up and ready."
              break
          else
              log "Waiting for interface $interface to be ready..."
              sleep 1
          fi
      done
  done

  # Wait an additional 5 seconds after all interfaces are up
  log "All interfaces are ready."
  return 0
}


# Loop until /internal and /uniondrive are verified to exist and be writable
while ! check_writable; do
  log "Waiting for /internal and /uniondrive to become writable..."
  sleep 5
done

check_interfaces
log "Waiting an additional 5 seconds after all wifi interfaces are up"
sleep 5

wap_pid=0

/wap &
wap_pid=$!

while true; do
  if check_internet && check_files_exist; then
    log "Internet connected and necessary files exist. Running /app."
    node_key_file="/internal/.secrets/node_key.txt"
    mkdir -p /internal/.secrets
    # Generate the node key
    new_key=$(/app --generateNodeKey | grep -E '^[a-f0-9]{64}$')
    # Check if the node_key file exists and has different content
    if [ ! -f "$node_key_file" ] || [ "$new_key" != "$(cat $node_key_file)" ]; then
      log "$new_key" > "$node_key_file"
      log "Node key saved to $node_key_file"
    else
      log "Node key file already exists and is up to date."
    fi
    nmcli con down FxBlox
    /app --config /internal/config.yaml
    break
  elif [ $wap_pid -eq 0 ]; then
    log "Either Internet not connected or necessary files missing. But wap is also not running. Reboot?"
  else 
    log "Either Internet not connected or necessary files missing"
  fi

  sleep 7
done
return 0