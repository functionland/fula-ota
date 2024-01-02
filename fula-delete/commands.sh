#!/bin/bash

WATCH_PATH="/home/pi/commands/"
FILE_NAMES=(".command_partition" ".command_reboot")  # Add your file names here


while true
do
    change=$(inotifywait -q -e create --format '%w%f' "$WATCH_PATH")
    for file_name in "${FILE_NAMES[@]}"; do
        if [ "$change" = "${WATCH_PATH}${file_name}" ]
        then
            echo "File $file_name created!"
            
            # Delete the file
            if [ -f "$change" ]; then
                rm "$change"
                echo "File $change has been removed successfully"
            fi
            
            case "$file_name" in
            ".command_reboot")
                # Perform the reboot
                echo "Rebooting now..."
                sync
                sudo reboot
                ;;
            ".command_partition")
                # Delete the flag and run the script
                echo "Deleting .partition_flg and running resize.sh..."
                if [ -f "/usr/bin/fula/.partition_flg" ]; then
                    rm "/usr/bin/fula/.partition_flg"
                fi
                sudo bash "/usr/bin/fula/resize.sh"
                ;;
            esac

        fi
    done
done
