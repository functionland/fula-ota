#!/bin/bash

WATCH_PATH="/home/pi/commands/"
FILE_NAMES=(".command_partition" ".command_repairfs" ".command_led" ".command_reboot")  # Add your file names here
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
                    rm "/usr/bin/fula/.partition_flg"
                fi
                sudo bash "/usr/bin/fula/resize.sh"
                ;;
            ".command_repairfs")
                # Perform the reboot
                echo "Repairing External Storage Filesystem now..."
                sync
                sudo bash /usr/bin/fula/repairfs.sh
                ;;
            ".command_led")
                # Extract color and time from FILE_CONTENT, default time to 999999 if not provided
                COLOR=$(echo $FILE_CONTENT | cut -d ' ' -f 1)
                TIME=$(echo $FILE_CONTENT | cut -s -d ' ' -f 2)
                TIME=${TIME:-999999}
                
                echo "Setting LED: Color=$COLOR, Time=$TIME"
                python /usr/bin/fula/control_led.py "$COLOR" "$TIME" 100
                ;;
            ".command_reboot")
                # Perform the reboot
                echo "Rebooting now..."
                sync
                sudo reboot
                ;;
            esac
        fi
    done
done
