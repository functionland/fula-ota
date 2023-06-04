#!/bin/sh

check_wifi_name() {
    # Get the name of the currently active Wi-Fi connection.
    wifi_name=$(nmcli -g GENERAL.CONNECTION device show wlan0)

    # Return 1 (false) if the Wi-Fi name is "FxBox", or 0 (true) otherwise.
    if [ "$wifi_name" = "FxBlox" ]; then
        return 1
    else
        return 0
    fi
}



check_internet() {
  ip addr show wlan0 | grep -q "inet " && check_wifi_name
  return $?
}

check_files_exist() {
  [ -f "/internal/config.yaml" ]
  return $?
}

wap_pid=0

sh /union-drive.sh &

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

  sleep 20
done
