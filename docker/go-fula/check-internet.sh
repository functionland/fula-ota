#!/bin/sh

check_internet() {
  wget -q --spider --timeout=10 https://www.google.com

  if [ $? -eq 0 ]; then
    return 0
  else
    return 1
  fi
}

while true; do
  if check_internet; then
    echo "Internet connected. Running /app."
    /app
    break
  else
    echo "Internet not connected. Running /wap."
    /wap
    sleep 15
  fi
done
