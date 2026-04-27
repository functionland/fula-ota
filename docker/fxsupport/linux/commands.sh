#!/bin/bash

# Define cleanup procedure
cleanup() {
    echo "Script is stopping, performing cleanup..."
    # Your cleanup commands here
    sudo rm -rf /home/pi/commands/*
}

# Trap SIGTERM
trap cleanup SIGTERM
sudo rm -rf /home/pi/commands/*
WATCH_PATH="/home/pi/commands/"
FILE_NAMES=(".command_partition" ".command_repairfs" ".command_led" ".command_reboot" ".command_restart_fula")  # Add your file names here
FILE_CONTENT=""

while true
do
    change=$(inotifywait -q -e create --format '%w%f' "$WATCH_PATH")
    for file_name in "${FILE_NAMES[@]}"; do
        if [ "$change" = "${WATCH_PATH}${file_name}" ]
        then
            echo "File $file_name created!"
            
            # Delete the file
            if [ -f "$change" ]; then
                FILE_CONTENT=$(cat "$change")  # Read the content before deletion for .command_led
                rm "$change"
                echo "File $change has been removed successfully"
            fi
            
            case "$file_name" in
            ".command_partition")
                # Delete the flag and run the script
                echo "Deleting .partition_flg and running resize.sh..."
                if [ -f "/usr/bin/fula/.partition_flg" ]; then
                    sudo rm "/usr/bin/fula/.partition_flg"
                fi
                sudo bash "/usr/bin/fula/resize.sh" 1
                ;;
            ".command_repairfs")
                # Perform the reboot
                echo "Repairing External Storage Filesystem now..."
                sync
                sudo bash /usr/bin/fula/repairfs.sh 1
                ;;
            ".command_led")
                # Extract color and time from FILE_CONTENT, default time to 999999 if not provided
                COLOR=$(echo $FILE_CONTENT | cut -d ' ' -f 1)
                TIME=$(echo $FILE_CONTENT | cut -s -d ' ' -f 2)
                TIME=${TIME:-999999}
                
                echo "Setting LED: Color=$COLOR, Time=$TIME"
                python /usr/bin/fula/control_led.py "$COLOR" "$TIME" 100 &
                ;;
            ".command_reboot")
                # Perform the reboot
                echo "Rebooting now..."
                sync
                sudo reboot
                ;;
            ".command_restart_fula")
                # Restart all fula services — used by fula_go's watchdog when
                # kubo's libp2p host has lost its circuit reservation and isn't
                # self-healing. Restarting kubo alone leaves ipfs-cluster in a
                # degraded state because cluster's one-time init (peering add,
                # p2p forward register) doesn't re-run on kubo restart. Doing
                # a compose restart re-runs every service's init script, so
                # cluster re-registers cleanly against the fresh kubo.
                # Less disruptive than a host reboot.
                echo "Restarting all fula services..."
                sync
                sudo docker compose -f /usr/bin/fula/docker-compose.yml restart
                ;;
            esac
        fi
    done
done
