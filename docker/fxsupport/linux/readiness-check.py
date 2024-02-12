import os
import subprocess
import time
import logging
import sys

# Configure logging to write to standard output
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    stream=sys.stdout,
)

def check_conditions():
    # Check all required conditions
    conditions = [
        os.path.exists("/usr/bin/fula/.partition_flg"),
        os.path.exists("/usr/bin/fula/.resize_flg"),
        os.path.exists("/home/pi/V6.info"),
        "fula_go" in subprocess.getoutput("docker ps --format '{{.Names}}'"),
        os.path.exists("/uniondrive"),  # Check if /uniondrive directory exists
        "active" in subprocess.getoutput("systemctl is-active fula.service"),
        "active" in subprocess.getoutput("systemctl is-active uniondrive.service")  # Check if uniondrive service is running
    ]
    return all(conditions)

def check_wifi_connection():
    # Check the active WiFi connection
    output = subprocess.getoutput("nmcli con show --active")
    logging.info(f"Active connections: {output}")  # Log the output for debugging
    if "FxBlox" in output:
        return "FxBlox"
    elif "wifi" in output:
        return "other"
    return None

def main():
    logging.info("readiness check started")
    while True:
        if check_conditions():
            logging.info("check_conditions passed")
            wifi_status = check_wifi_connection()
            if wifi_status == "FxBlox":
                logging.info("wifi_status FxBlox")
                subprocess.run(["python", "/usr/bin/fula/control_led.py", "cyan", "5"])
            elif wifi_status == "other":
                logging.info("wifi_status other")
                subprocess.run(["python", "/usr/bin/fula/control_led.py", "green", "30"])
                break  # Exit the loop as no further check is needed
            else:
                logging.info("wifi_status not connected")
                subprocess.run(["python", "/usr/bin/fula/control_led.py", "yellow", "5"])
        else:
            logging.info("check_conditions failed")
            time.sleep(5)

if __name__ == "__main__":
    main()
