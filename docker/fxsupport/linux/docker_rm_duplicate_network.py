#!/usr/bin/env python3
import subprocess
import json

seen_networks = {}

try:
    output = subprocess.check_output(["docker", "network", "ls", "--format", "{{json .}}"])
except subprocess.CalledProcessError as e:
    print(f"Failed to get docker networks: {e}")
    exit(1)

for line in output.decode("utf-8").split("\n"):
    line = line.strip()
    if not line: continue
    obj = json.loads(line.strip())
    id = obj["ID"]
    name = obj["Name"]

    if name in seen_networks:
        print(f"Detected duplicate network {name}. Attempting to remove duplicate network {id}...")
        try:
            subprocess.check_output(["docker", "network", "rm", id])
        except subprocess.CalledProcessError as e:
            print(f"Failed to remove duplicate network {id}: {e}")
            id_to_remove = seen_networks[name][0]
            print(f"Attempting to remove first instance of duplicate network {id_to_remove}...")
            try:
                subprocess.check_output(["docker", "network", "rm", id_to_remove])
                # Replace the first instance ID with the current one
                seen_networks[name][0] = id
            except subprocess.CalledProcessError as e2:
                print(f"Failed to remove first instance of duplicate network {id_to_remove}: {e2}")
                continue
    else:
        seen_networks[name] = [id]
