#!/bin/bash

# Get current PID
current_pid=$$

# Kill other bluetooth processes but exclude current one
for pid in $(pgrep -f "bluetooth.py"); do
    if [ "$pid" != "$current_pid" ]; then
        kill $pid 2>/dev/null
    fi
done

sleep 60
sudo /usr/bin/python /usr/bin/fula/bluetooth.py 2>&1 | tee -a /home/pi/fula.sh.log