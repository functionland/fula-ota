#!/bin/sh

check_internet() {
  wget -q --spider --timeout=10 https://www.google.com

  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

wap_pid=0

while true; do
  if check_internet; then
    echo "Internet connected. Running /app."

    # Kill the /wap process if it's running
    if [ $wap_pid -ne 0 ]; then
      kill $wap_pid
    fi

    /app
    break
  else
    echo "Internet not connected. Running /wap."

    # Run /wap in the background and store its PID
    /wap &
    wap_pid=$!

    sleep 60
  fi
done