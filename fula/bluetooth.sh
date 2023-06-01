#!/bin/bash

FULA_LOG_PATH=/home/pi/fula.sh.log

script_start_time=$(date +%s)

# Define GPIO pin for blue LED
led_b_pin=16

# Global variable to control the loop
keep_flashing=0


function create_and_connect_wifi() {
    SSID=$1
    PASSWORD=$2

	sudo nmcli con add type wifi ifname "*" con-name "$SSID" ssid "$SSID"
	sudo nmcli con modify "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD"
	sudo nmcli con up "$SSID"
}

function remove_wifi_connections() {
    # Get a list of all connection names
    local wifi_connections
    wifi_connections=$(nmcli con show | grep wifi | awk '{print $1}')

    # Iterate over each connection
    for conn in $wifi_connections; do
        echo "Removing Wi-Fi connection: $conn"
        sudo nmcli con delete "$conn"
    done
}

sudo rfcomm release /dev/rfcomm0 1

# Wait for connection
while [ "$(hcitool con | grep -c 'ACL')" == "0" ]; do
    echo "Waiting for connection..."
    sleep 1
    current_time=$(date +%s)
	script_elapsed_time=$(($current_time - $script_start_time))
	if [ $script_elapsed_time -ge 240 ]
	then
		echo "240 seconds have passed. Stopping the script..."
        python control_led.py blue -1 > $FULA_LOG_PATH 2>&1 &
        break
    fi
done

# Device connected, get the MAC address
MAC_ADDRESS=$(hcitool con | grep 'ACL' | awk '{print $3}')
echo "Device connected, MAC Address: $MAC_ADDRESS"

# Trust the device
echo -e "trust $MAC_ADDRESS" | bluetoothctl

# Bind the RFCOMM channel
sudo rfcomm listen /dev/rfcomm0 1 &

# Wait until /dev/rfcomm0 exists and bind the RFCOMM channel
while [ ! -c "/dev/rfcomm0" ]; do
    echo "Waiting for /dev/rfcomm0..."
    sleep 1
    current_time=$(date +%s)
	script_elapsed_time=$(($current_time - $script_start_time))
	if [ $script_elapsed_time -ge 240 ]
	then
		echo "240 seconds have passed. Stopping the script..."
        python control_led.py blue -1 > $FULA_LOG_PATH 2>&1 &
        break
    fi
done

# Listen for commands
start_time=0

# check elapsed time in a separate function
function reset() {
    while :
    do
        current_time=$(date +%s)
        # check elapsed time since start_time...
        elapsed_time=$(($current_time - $start_time))

        if [ $elapsed_time -ge 20 ] && [ -f ~/reset.txt ]
        then
            echo "Resetting the device..."
            remove_wifi_connections
            sudo rm ~/reset.txt
            python control_led.py red -1 > $FULA_LOG_PATH 2>&1 &
            sudo reboot
        fi
        # check elapsed time since script_start_time...
        sleep 1
    done
}

function stop() {
    while :
    do
        current_time=$(date +%s)
        # check elapsed time since start_time...
        script_elapsed_time=$(($current_time - $script_start_time))
		if [ $script_elapsed_time -ge 240 ] && [ "$keep_flashing" -eq 0 ]
		then
			echo "240 seconds have passed and LED isn't flashing. Stopping the script..."
            if [ -f ~/stop_bluetooth.txt ]; then
                echo "Removing ~/stop_bluetooth.txt"
                sudo rm ~/stop_bluetooth.txt
                python control_led.py blue -1 > $FULA_LOG_PATH 2>&1 &
                start_time=0
                script_start_time=0
            fi
            echo "blue flashing stopped keep_flashing=$keep_flashing"
			break
		fi
        # check elapsed time since script_start_time...
        sleep 1
    done
}
function process_commands() {
    while read -r command
    do
        echo "Received command: $command" > ~/bluetooth_commands.txt
        if [[ "$command" == "connect "* ]]; then
            IFS=' ' read -ra ADDR <<< "$command"
            SSID=${ADDR[1]}
            PASSWORD=${ADDR[2]}
            echo "Connecting to $SSID"
            create_and_connect_wifi "$SSID" "$PASSWORD"
        elif [ "$command" == "reset" ]
        then
            echo "Creating ~/reset.txt"
            sudo touch ~/reset.txt
            python control_led.py red 20 > $FULA_LOG_PATH 2>&1 &
            keep_flashing=1
            start_time=$(date +%s)
        elif [ "$command" == "cancel" ]
        then
            if [ -f ~/reset.txt ]; then
                echo "Removing ~/reset.txt"
                sudo rm ~/reset.txt
                python control_led.py red -1 > $FULA_LOG_PATH 2>&1 &
                keep_flashing=0
                echo "red flashing stopped keep_flashing=$keep_flashing"
                start_time=0
            fi
        fi

        # Check if 20 seconds have passed since the creation of the reset.txt file
        current_time=$(date +%s)
        if [ $start_time -ne 0 ]; then
            reset &> ~/reset.log &
            echo $! > ~/reset.pid
        fi
		stop &> ~/stop_bluetooth.log &
        echo $! > ~/stop_bluetooth.pid
    done < /dev/rfcomm0
}

# Call the function with error handling
process_commands || {
    echo "An error occurred while processing commands. But the script will continue." > ~/bluetooth_commands.txt
}
python control_led.py blue 240 > $FULA_LOG_PATH 2>&1 &