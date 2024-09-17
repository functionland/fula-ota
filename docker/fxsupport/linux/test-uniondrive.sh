#!/bin/bash

inotifywait -m /uniondrive -e create -e modify -e delete |
while read path action file; do
    echo "The file '$file' appeared in directory '$path' via '$action'"
    # Add your custom actions here
done