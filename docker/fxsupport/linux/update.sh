#!/bin/bash

FULA_LOG_PATH=/home/pi/fula.sh.log

# Get a list of USB devices
mapfile -t devices < <(ls /media/pi)

for device in "${devices[@]}"; do
    # Prepare the path for this device
    mountpoint="/media/pi/$device"

    # Check if the update directory exists on this device
    if [ -d "$mountpoint/fula_update" ]; then

        # Check if the update file exists on this device
        if [ -f "$mountpoint/fula_update/update.yaml" ]; then
            mv "$mountpoint/fula_update/update.yaml" "$mountpoint/fula_update/update.inprogress.yaml"
            sudo rm /home/pi/stop_docker_copy.txt

            if [ -f "$mountpoint/fula_update/repair_init.sh" ]; then
                sudo bash "$mountpoint/fula_update/repair_init.sh" 2>&1 | sudo tee -a $FULA_LOG_PATH || { echo "Error Running repair_init" >> $FULA_LOG_PATH 2>&1; }
            fi

            if pgrep -f "control_led.py" > /dev/null; then
                sudo pkill -f "control_led.py" || { echo "Error Killing control_led" >> $FULA_LOG_PATH 2>&1; }
            fi

            python /usr/bin/fula/control_led.py blue 200 >> $FULA_LOG_PATH 2>&1 &
            sudo systemctl stop fula

            if [ -d "$mountpoint/fula_update/fula" ]; then
                sudo cp -r "$mountpoint/fula_update/fula"/* /usr/bin/fula
                sudo cp -r "$mountpoint/fula_update/fula"/* /home/pi/fula-ota
            else
                echo "Error: fula_update/fula directory not found on device $device" >> $FULA_LOG_PATH 2>&1
                sudo cp /home/pi/fula.sh.log* "$mountpoint/fula_update/"
                mv "$mountpoint/fula_update/update.inprogress.yaml" "$mountpoint/fula_update/update.error.yaml"
                python /usr/bin/fula/control_led.py red 3 >> $FULA_LOG_PATH 2>&1
                exit 1;
            fi

            sudo chmod +x /usr/bin/fula/*.sh
            sudo chmod +x /home/pi/fula-ota/*.sh

            sudo mkdir -p /usr/bin/fula

            if cd /usr/bin/fula; then
                sudo bash ./fula.sh install

                if [ -f "$mountpoint/fula_update/repair.sh" ]; then
                    sudo bash "$mountpoint/fula_update/repair.sh"
                fi
                sudo cp /home/pi/fula.sh.log* "$mountpoint/fula_update/"
                date | sudo tee -a /home/pi/stop_docker_copy.txt > /dev/null
                mv "$mountpoint/fula_update/update.inprogress.yaml" "$mountpoint/fula_update/update.completed.yaml"
                python /usr/bin/fula/control_led.py blue -1 >> $FULA_LOG_PATH 2>&1 &

                if pgrep -f "control_led.py" > /dev/null; then
                    sudo pkill -f "control_led.py"
                fi
                sleep 2
                python /usr/bin/fula/control_led.py green 3 >> $FULA_LOG_PATH 2>&1
                sudo reboot
            else
                echo "Error: unable to navigate to /usr/bin/fula" >> $FULA_LOG_PATH 2>&1
                sudo cp /home/pi/fula.sh.log* "$mountpoint/fula_update/"
                mv "$mountpoint/fula_update/update.inprogress.yaml" "$mountpoint/fula_update/update.error.yaml"
                python /usr/bin/fula/control_led.py red 3 >> $FULA_LOG_PATH 2>&1
                exit 1;
            fi
        else
            echo "Info: update.yaml not found on device $device" >> $FULA_LOG_PATH 2>&1
        fi
    fi
done
