import os
import subprocess
import time
import logging
import sys

FULA_PATH = "/usr/bin/fula"
HOME_PATH = "/home/pi"

# Configure logging to write to standard output
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    stream=sys.stdout,
)

def check_conditions():
    # Check all required conditions
    conditions = [
        os.path.exists(os.path.join(FULA_PATH, ".partition_flg")),
        os.path.exists(os.path.join(FULA_PATH, ".resize_flg")),
        os.path.exists(os.path.join(HOME_PATH, "V6.info")),
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

def attempt_wifi_connection():
    config_yaml_path = os.path.join(HOME_PATH, ".internal", "config.yaml")
    if os.path.exists(config_yaml_path):
        logging.info("config.yaml exists, checking for non-FxBlox WiFi connections")
        connections_output = subprocess.getoutput("nmcli con show | grep wifi")
        wifi_connections = [line.split()[0] for line in connections_output.split('\n') if "wifi" in line and "FxBlox" not in line]

        wifi_connected = False
        for wifi_con in wifi_connections:
            logging.info(f"Attempting to connect to {wifi_con}")
            result = subprocess.run(["sudo", "nmcli", "con", "up", wifi_con], capture_output=True)
            if result.returncode == 0:
                logging.info(f"Successfully connected to {wifi_con}")
                wifi_connected = True
                break
            else:
                logging.error(f"Failed to connect to {wifi_con}")
                if result.stderr:
                    logging.error(f"nmcli error: {result.stderr}")

        if not wifi_connected:
            logging.info("No successful WiFi connections, defaulting to FxBlox hotspot")
            subprocess.run(["sudo", "nmcli", "con", "up", "FxBlox"], capture_output=True)

    else:
        logging.info("config.yaml does not exist, attempting to start FxBlox hotspot")
        subprocess.run(["sudo", "nmcli", "con", "up", "FxBlox"], capture_output=True)

    return None

def main():
    logging.info("readiness check started")
    fula_restart_attempts = 0
    cycles_with_no_wifi = 0
    while True:
        if check_conditions():
            logging.info("check_conditions passed")
            wifi_status = check_wifi_connection()
            if wifi_status == "FxBlox":
                logging.info("wifi_status FxBlox")
                subprocess.run(["python", os.path.join(FULA_PATH, "control_led.py"), "cyan", "5"])
            elif wifi_status == "other":
                logging.info("wifi_status other")
                subprocess.run(["python", os.path.join(FULA_PATH, "control_led.py"), "green", "30"])
                break  # Exit the loop as no further check is needed
            else:
                logging.info("wifi_status not connected")
                if cycles_with_no_wifi == 6:
                    logging.info("wifi not connected, attempting to start FxBlox hotspot")
                    attempt_wifi_connection()
                    cycles_with_no_wifi = 0

                subprocess.run(["python", os.path.join(FULA_PATH, "control_led.py"), "red", "10"])
                cycles_with_no_wifi += 1
        else:
            logging.info("check_conditions failed")
            # Check if 'fula_go' exists in `docker ps -a`
            docker_ps_a_output = subprocess.getoutput("docker ps -a --format '{{.Names}}'")
            docker_ps_output = subprocess.getoutput("docker ps --format '{{.Names}}'")

            if "fula_go" in docker_ps_a_output and \
                all(container in docker_ps_output for container in ["fula_node", "fula_fxsupport", "fula_updater"]) and \
                fula_restart_attempts < 4:
                    logging.info("fula_go container found but is not running. Attempting to restart fula.service")
                    result = subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True)
                    if result.returncode == 0:
                        logging.info("fula.service restarted successfully.")
                        if result.stdout:
                            logging.info(f"Restart output: {result.stdout}")
                    else:
                        logging.error("Failed to restart fula.service.")
                        if result.stderr:
                            logging.error(f"Restart error: {result.stderr}")

                    fula_restart_attempts += 1
            time.sleep(7)

if __name__ == "__main__":
    main()
