#!/bin/bash
sleep 60
sudo /usr/bin/python /usr/bin/fula/bluetooth.py 2>&1 | tee -a /home/pi/fula.sh.log