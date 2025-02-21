#!/bin/sh

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1"
}

check_wifi_name() {
    # Get the name of the currently active Wi-Fi connection.
    wifi_name=$(nmcli -g GENERAL.CONNECTION device show "$1")

    # Return 1 (false) if the Wi-Fi name is "FxBlox", or 0 (true) otherwise.
    if [ "$wifi_name" = "FxBlox" ]; then
        return 1
    else
        return 0
    fi
}

check_internet() {
    # First determine which wireless tool to use
    if command -v iw > /dev/null 2>&1; then
        for iface in /sys/class/net/*; do
            iface_name=$(basename "$iface")
            if [ "$iface_name" != "lo" ] && iw dev "$iface_name" info 2>/dev/null | grep -q "type managed" && ip addr show "$iface_name" | grep -q "inet " && check_wifi_name "$iface_name"; then
                return 0
            fi
        done
    else
        log "iw command not found"
        return 1
    fi
    return 1
}

check_ping() {
  # Ping a well-known website (Google's DNS) to check for connectivity
  if ping -c 1 -W 1 8.8.8.8 >/dev/null 2>&1; then
    log "Ping to 8.8.8.8 successful."
    return 0
  else
    log "Ping to 8.8.8.8 failed."
    return 1
  fi
}

check_files_exist() {
  [ -f "/internal/config.yaml" ]
  return $?
}

wait_for_ipfs() {
    log "Waiting for IPFS daemon to be ready..."
    while : ; do
        # Attempt to query the IPFS daemon
        response=$(curl -X POST -s -o /dev/null -w "%{http_code}" http://127.0.0.1:5001/api/v0/id)

        # Check if the response status is 200
        if [ "$response" -eq 200 ]; then
            log "IPFS daemon is ready."
            break
        else
            log "Waiting for IPFS daemon..."
            sleep 5
        fi
    done
}


check_writable() {
  is_writable=0  # Assume both directories are writable initially

  # Check if /internal exists and is writable
  if [ -d "/internal" ]; then
    touch /internal/.tmp_write 2>/dev/null
    if [ -f /internal/.tmp_write ]; then
      rm /internal/.tmp_write 2>/dev/null
    else
      log "/internal is not writable."
      is_writable=1
    fi
  else
    log "/internal does not exist."
    is_writable=1
  fi

  # Check if /uniondrive exists and is writable
  if [ -d "/uniondrive" ]; then
    touch /uniondrive/.tmp_write 2>/dev/null
    if [ -f /uniondrive/.tmp_write ]; then
      rm /uniondrive/.tmp_write 2>/dev/null
    else
      log "/uniondrive is not writable."
      is_writable=1
    fi
  else
    log "/uniondrive does not exist."
    is_writable=1
  fi

  if [ $is_writable -eq 0 ]; then
    log "Both /internal and /uniondrive exist and are writable."
    return 0
  else
    return 1
  fi
}


is_interface_ready() {
    local_interface=$1
    if ip link show "$local_interface" | grep -q "UP"; then
        return 0
    else
        return 1
    fi
}

check_interfaces() {
    # Check for required commands
    if ! command -v ip > /dev/null 2>&1; then
        log "The 'ip' command is required but not found. Exiting."
        return 1
    fi

    # Initialize interfaces variable
    interfaces=""

    # Then check for iw
    if ! command -v iw > /dev/null 2>&1; then
        log "iw command not found. Exiting."
        return 1
    else
        log "Using iw command for wireless operations"
        interfaces=$(iw dev | awk '$1=="Interface"{print $2}')
    fi

    if [ -z "$interfaces" ]; then
        log "No wireless network interfaces found. Exiting."
        return 1
    fi

    # Check for saved Wi-Fi connections
    saved_connections=$(nmcli -t -f TYPE,UUID connection show | grep 802-11-wireless | cut -d: -f2)
    if [ -z "$saved_connections" ]; then
      # Flag to control the while loop
      interface_ready=false
      start_time=$(date +%s)
      timeout=90  # 60 seconds timeout
      # Infinite loop to wait for an interface to become ready
      while ! $interface_ready; do
        for interface in $interfaces; do
          if is_interface_ready "$interface"; then
            # Set the flag to true and break out of the for loop
            interface_ready=true
            break
          fi
        done
        sleep 2
        if [ $elapsed_time -ge $timeout ]; then
          log "Timeout reached for interfaces. Exiting."
          return 1
        fi
      done

      log "No saved Wi-Fi connections found. Exiting."
      return 0
    fi

    start_time=$(date +%s)
    timeout=120  # 60 seconds timeout
    interface_connected=false
    # Loop through each interface and check its status
    while ! $interface_connected; do
        for interface in $interfaces; do
            log "Checking wireless interface: $interface"
            
            # Get the current state of the interface
            state=$(ip link show "$interface" | awk '/state UP/ {print $9}')

            # Check if the interface is in the 'UP' state
            if [ -n "$state" ] && [ "$state" = "UP" ]; then
                log "Interface $interface is up and connected."
                interface_connected=true
                break
            else
                log "Waiting for interface $interface to be connected..."
                sleep 2
            fi
        done
        current_time=$(date +%s)
        elapsed_time=$((current_time - start_time))
        if [ $elapsed_time -ge $timeout ]; then
            log "Timeout reached for interface $interface. Exiting."
            return 1
        fi
    done

    # Wait an additional 5 seconds after all interfaces are up
    log "All interfaces are ready."
    return 0
}

disconnect_others() {
    log "Trying to disconnect other wifis"
    # Get a list of currently connected Wi-Fi networks
    connections=$(nmcli -t -f NAME,TYPE connection show --active | grep ":802-11-wireless" | cut -d: -f1)

    for conn in $connections; do
        # If the connection is not "FxBlox", disconnect it
        if [ "$conn" != "FxBlox" ]; then
            log "Disconnecting from $conn"
            nmcli con down "$conn"
        fi
    done
}

disconnect_attempted=0

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
  if (check_internet || check_ping) && check_files_exist; then
    log "Internet connected and necessary files exist. Running /app."
    node_key_file="/internal/.secrets/node_key.txt"
    secret_phrase_file="/internal/.secrets/secret_phrase.txt"
    mkdir -p "/internal/.secrets"

    # Generate the node key
    new_key=$(/app --generateNodeKey --config /internal/config.yaml | grep -E '^[a-f0-9]{64}$')
    # Check if the node_key file exists and has different content
    if [ ! -f "$node_key_file" ] || [ "$new_key" != "$(cat $node_key_file)" ]; then
      printf "%s" "$new_key" > "$node_key_file"
      log "Node key saved to $node_key_file"
    else
      log "Node key file already exists and is up to date."
    fi

    # Generate the 12-word secret phrase
    untrimmed_secret_phrase=$(/app --generateSecretPhrase --config /internal/config.yaml)

    # Process the new secret phrase
    new_secret_phrase=$(echo "$untrimmed_secret_phrase" | grep -v "Error loading .env file open .env: no such file or directory" | tr -d '\n' | sed 's/^[ \t]*//;s/[ \t]*$//')

    # Check if the secret_phrase file exists and has different content
    if [ ! -f "$secret_phrase_file" ] || [ "$new_secret_phrase" != "$(cat $secret_phrase_file)" ]; then
      printf "%s" "$new_secret_phrase" > "$secret_phrase_file"
      log "Secret Phrase saved to $secret_phrase_file"
    else
      log "Secret Phrase file already exists and is up to date."
    fi

    /initipfs
    touch /internal/.ipfs_setup

    wait_for_ipfs
    
    exit_code=$?

    # Check if the program exited due to a panic (or any error)
    if [ $exit_code -ne 0 ]; then
      log "The initipfs exited with an error: Exit code $exit_code"
    fi

    /initipfscluster
    touch /internal/.ipfscluster_setup

    nmcli con down FxBlox
    /app --config /internal/config.yaml --blockchainEndpoint "api.node3.functionyard.fula.network"
    break
  elif [ $wap_pid -eq 0 ]; then
    log "Either Internet not connected or necessary files missing. But wap is also not running. Reboot?"
  else 
    if [ $disconnect_attempted -eq 0 ]; then
        disconnect_others
        disconnect_attempted=1
    fi
    log "Either Internet not connected or necessary files missing"
  fi

  sleep 7
done
return 0