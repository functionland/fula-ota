#!/bin/bash

#v4@2023-05-05

# Check if NetworkManager is active. If it's not, start it.
if ! systemctl is-active --quiet NetworkManager; then
    echo "NetworkManager is not active. Starting it..."
    sudo systemctl start NetworkManager
fi

# Force a rescan
echo "Forcing a rescan of Wi-Fi networks..."
sudo nmcli device wifi rescan

# Wait for a few seconds to let the rescan complete
sleep 5

# Get the list of saved connections
connections=$(nmcli --terse --fields TYPE,NAME con show)

# Remove the connection named "FxBlox" if it exists and only keep wifi connections
connections=$(echo "$connections" | grep "^802-11-wireless" | grep -v ":FxBlox$")

# Get the first connection from the list
connection_name=$(echo "$connections" | head -n 1 | cut -d ':' -f2)

# If no connections are left in the list, just echo a message and exit
if [ -z "$connection_name" ]; then
    echo "No saved Wi-Fi connections were found."
    exit 1
fi

# Otherwise, try to connect to the first connection
echo "Trying to connect to '$connection_name'..."
sudo nmcli connection up "$connection_name"