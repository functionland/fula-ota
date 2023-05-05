#!/bin/bash

# Get the list of saved connections
connections=$(nmcli --terse --fields NAME con show)

# Remove the connection named "FxBlox" if it exists
connections=$(echo "$connections" | grep -v "^FxBlox$")

# Get the first connection from the list
connection_name=$(echo "$connections" | head -n 1)

# If no connections are left in the list, just echo a message and exit
if [ -z "$connection_name" ]; then
    echo "No saved Wi-Fi connections were found."
    exit 1
fi

# Otherwise, try to connect to the first connection
echo "Trying to connect to '$connection_name'..."
sudo nmcli connection up "$connection_name"