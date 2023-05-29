#!/bin/bash

script_start_time=$(date +%s)

# Define GPIO pin for blue LED
led_b_pin=16

# Global variable to control the loop
keep_flashing=1

control_blue() {
    action=$1  # Get the first argument to the function

    # Try
    {
        if [ "$action" = "start" ]; then
            keep_flashing = 1
            # Export GPIO pin
            echo $led_b_pin > /sys/class/gpio/export

            # Set GPIO pin direction
            echo out > /sys/class/gpio/gpio$led_b_pin/direction

            # Start flashing blue LED for 5 seconds
            for i in {1..20}
            do
                if [ "$keep_flashing" -eq 1 ]; then
                    echo 0 > /sys/class/gpio/gpio$led_b_pin/value
                    sleep 1
                    echo 1 > /sys/class/gpio/gpio$led_b_pin/value
                else
                    break
                fi
            done
        elif [ "$action" = "stop" ]; then
            # Turn off blue LED and stop flashing
            keep_flashing=0
            echo 1 > /sys/class/gpio/gpio$led_b_pin/value
            if [ -f ~/control_blue.pid ]; then
                kill $(cat ~/control_blue.pid) || { echo "Error Killing control_blue Process"; } || true
                sudo rm ~/control_blue.pid || { echo "Error removing control_blue.pid"; }
            fi
        else
            echo "Invalid action. Use either 'start' or 'stop'."
        fi
    } || {
        # Catch
        echo "An error occurred while controlling the blue LED. But the script will continue."
    }

    # Always
    {
        # Unexport GPIO pin after use
        echo $led_b_pin > /sys/class/gpio/unexport
    }
}


function create_and_connect_wifi() {
    SSID=$1
    PASSWORD=$2

	sudo nmcli con add type wifi ifname "*" con-name "$SSID" ssid "$SSID"
	sudo nmcli con modify "$SSID" wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PASSWORD"
	sudo nmcli con up "$SSID"
}

function remove_wifi_connections() {
    # Get a list of all connection names
    local wifi_connections=$(nmcli con show | grep wifi | awk '{print $1}')

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
	if [ $script_elapsed_time -ge 120 ]
	then
		echo "120 seconds have passed. Stopping the script..."
        if [ "$keep_flashing" -eq 1 ]; then
            control_blue stop || { echo "control_blue stop failed"; }
        fi
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
	if [ $script_elapsed_time -ge 120 ]
	then
		echo "120 seconds have passed. Stopping the script..."
        if [ "$keep_flashing" -eq 1 ]; then
            control_blue stop || { echo "control_blue stop failed"; }
        fi
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
            control_blue stop || { echo "control_blue stop failed"; }
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
		if [ $script_elapsed_time -ge 120 ] && [ "$keep_flashing" -eq 0 ]
		then
			echo "120 seconds have passed and LED isn't flashing. Stopping the script..."
            if [ -f ~/stop_bluetooth.txt ]; then
                echo "Removing ~/stop_bluetooth.txt"
                sudo rm ~/stop_bluetooth.txt
                control_blue stop || { echo "control_blue stop failed"; }
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
            if [ -f ~/control_blue.pid ]; then
                kill $(cat ~/control_blue.pid) || { echo "Error Killing control_blue Process"; } || true
                sudo rm ~/control_blue.pid || { echo "Error removing control_blue.pid"; }
            fi
            control_blue start &> ~/control_blue.log &
            echo $! > ~/control_blue.pid
            start_time=$(date +%s)
        elif [ "$command" == "cancel" ]
        then
            if [ -f ~/reset.txt ]; then
                echo "Removing ~/reset.txt"
                sudo rm ~/reset.txt
                control_blue stop || { echo "control_blue stop failed"; }
                echo "blue flashing stopped keep_flashing=$keep_flashing"
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