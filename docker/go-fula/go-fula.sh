#!/bin/sh

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
      echo "/internal is not writable."
      return 1
    fi
  else
    echo "/internal does not exist."
    return 1
  fi

  # Check if /uniondrive exists and is writable
  if [ -d "/uniondrive" ]; then
    if ! touch /uniondrive/.tmp_write || ! rm /uniondrive/.tmp_write; then
      echo "/uniondrive is not writable."
      return 1
    fi
  else
    echo "/uniondrive does not exist."
    return 1
  fi

  echo "Both /internal and /uniondrive exist and are writable."
  return 0
}


# Loop until /internal and /uniondrive are verified to exist and be writable
while ! check_writable; do
  echo "Waiting for /internal and /uniondrive to become writable..."
  sleep 5
done

wap_pid=0

/wap &
wap_pid=$!

while true; do
  if check_internet && check_files_exist; then
    echo "Internet connected and necessary files exist. Running /app."

    /app --config /internal/config.yaml
    break
  elif [ $wap_pid -eq 0 ]; then
    echo "Either Internet not connected or necessary files missing. Running /wap."
  fi

  sleep 7
done
