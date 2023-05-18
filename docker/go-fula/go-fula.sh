#!/bin/sh

check_internet() {
  ip addr show wlan0 | grep -q "inet " && ! (iwgetid -r | grep -q "FxBlox")
  return $?
}

check_files_exist() {
  [ -f "/internal/setupInitiated.info" ] && [ -f "/internal/config.yaml" ]
  return $?
}

wap_pid=0

sh /union-drive.sh &

# Check files at the beginning
if ! check_files_exist; then
  echo "Necessary files missing. Running /wap."
  /wap &
  wap_pid=$!
fi

while true; do
  if check_internet && check_files_exist; then
    echo "Internet connected and necessary files exist. Running /app."

    # Kill the /wap process if it's running
    if [ $wap_pid -ne 0 ]; then
      kill $wap_pid && wap_pid=0
    fi

    /app --config /internal/config.yaml
    break
  elif [ $wap_pid -eq 0 ]; then
    echo "Either Internet not connected or necessary files missing. Running /wap."

    # Run /wap in the background and store its PID
    /wap &
    wap_pid=$!
  fi

  sleep 20
done
