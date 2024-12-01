import os
import subprocess
import time
import logging
import sys
import requests
import re

FULA_PATH = "/usr/bin/fula"
HOME_PATH = "/home/pi"
COMMAND_PARTITION_PATH = os.path.join(HOME_PATH, "commands/.command_partition")
REBOOT_FLAG_PATH = os.path.join(HOME_PATH, ".reboot_flag")
LED_PATH = os.path.join(FULA_PATH, "control_led.py")

# Configure logging to write to standard output
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    stream=sys.stdout,
)

def get_wifi_info_and_ping():
    try:
        # Get the list of connections
        nmcli_output = subprocess.check_output(["sudo", "nmcli", "con", "show"], universal_newlines=True)
        
        # Find the non-FxBlox WiFi connection
        wifi_connection = None
        for line in nmcli_output.split('\n'):
            if 'wifi' in line.lower() and 'fxblox' not in line.lower():
                wifi_connection = line.split()[0]
                break
        
        if not wifi_connection:
            return "No non-FxBlox WiFi connection found."
        
        # Get the device for this connection
        device_output = subprocess.check_output(["sudo", "nmcli", "con", "show", wifi_connection], universal_newlines=True)
        device_match = re.search(r'GENERAL.DEVICES:\s+(\S+)', device_output)
        if not device_match:
            return f"Could not find device for connection {wifi_connection}"
        
        device = device_match.group(1)
        
        # Get the router IP (gateway)
        gateway_output = subprocess.check_output(["sudo", "nmcli", "dev", "show", device], universal_newlines=True)
        gateway_match = re.search(r'IP4.GATEWAY:\s+(\S+)', gateway_output)
        if not gateway_match:
            return f"Could not find gateway IP for device {device}"
        
        gateway_ip = gateway_match.group(1)
        
        # Ping the router 6 times
        ping_output = subprocess.check_output(["ping", "-c", "6", gateway_ip], universal_newlines=True)
        
        return f"Connection: {wifi_connection}\nDevice: {device}\nGateway IP: {gateway_ip}\nPing results:\n{ping_output}"
    
    except subprocess.CalledProcessError as e:
        return f"An error occurred: {str(e)}"

def check_fs_type(mount_path, expected_type):
    if not os.path.exists(mount_path):
        return False
    
    try:
        result = subprocess.run(["findmnt", "-no", "FSTYPE", mount_path], capture_output=True, text=True)
        actual_type = result.stdout.strip()
        return expected_type in actual_type.split('\n')
    except subprocess.CalledProcessError:
        return False

def check_conditions():
    # Check all required conditions
    conditions = [
        os.path.exists(os.path.join(FULA_PATH, ".partition_flg")),
        os.path.exists(os.path.join(FULA_PATH, ".resize_flg")),
        os.path.exists(os.path.join(HOME_PATH, "V6.info")),
        "fula_go" in subprocess.getoutput("sudo docker ps --format '{{.Names}}'"),
        os.path.exists("/uniondrive"),  # Check if /uniondrive directory exists
        check_fs_type("/uniondrive", "fuse.mergerfs"),
        "active" in subprocess.getoutput("sudo systemctl is-active docker.service"),
        "active" in subprocess.getoutput("sudo systemctl is-active fula.service"),
        "active" in subprocess.getoutput("sudo systemctl is-active uniondrive.service")  # Check if uniondrive service is running
    ]
    return all(conditions)

def check_wifi_connection():
    # Check the active WiFi connection
    output = subprocess.getoutput("sudo nmcli con show --active")
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
        connections_output = subprocess.getoutput("sudo nmcli con show | grep wifi")
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

def check_and_fix_ipfs_cluster():
    try:
        ipfs_cluster_logs = subprocess.getoutput("sudo docker logs ipfs_cluster --tail 15 2>&1")
        cluster_error_found = False
        
        if "error creating datastore: failed to open pebble database" in ipfs_cluster_logs or "unknown to the objstorage provider: file does not exist" in ipfs_cluster_logs:
            logging.warning("IPFS Cluster Pebble database issue detected. Attempting to fix.")
            subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True, check=True)
            time.sleep(10)
            pebble_dir = "/uniondrive/ipfs-cluster/pebble"
            if os.path.exists(pebble_dir):
                subprocess.run(f"sudo rm -rf {pebble_dir}/*", shell=True, check=True)
                logging.info("Pebble directory contents removed.")
            else:
                logging.warning("Pebble directory not found.")
            subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True, check=True)
            time.sleep(30)
            cluster_error_found = True
        elif "error obtaining execution lock: cannot acquire lock:" in ipfs_cluster_logs:
            logging.warning("IPFS Cluster lock issue detected. Attempting to fix.")
            subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True, check=True)
            time.sleep(10)
            subprocess.run(["sudo", "rm", "-f", "/uniondrive/ipfs-cluster/cluster.lock"], capture_output=True, check=True)
            logging.info("IPFS Cluster lock file removed.")
            subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True, check=True)
            time.sleep(30)
            cluster_error_found = True
        elif "status_code=000" in ipfs_cluster_logs and "Request failed, retrying in 60 seconds" in ipfs_cluster_logs:
            logging.warning("IPFS Cluster status code issue detected. Attempting to restart fula.")
            subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
            time.sleep(30)
            cluster_error_found = True
        
        # Try to clear logs only if the container exists
        if cluster_error_found:
            container_id = subprocess.getoutput("docker inspect --format='{{.Id}}' ipfs_cluster 2>/dev/null")
            if container_id:
                try:
                    subprocess.run(["sudo", "truncate", "-s", "0", f"/var/lib/docker/containers/{container_id}/ipfs_cluster-json.log"], check=True)
                    logging.info("fix applied and IPFS Cluster logs cleared successfully.")
                except subprocess.CalledProcessError:
                    logging.warning("Failed to truncate logs, but applied with the fix of ipfs cluster")
        
        return cluster_error_found
    except subprocess.CalledProcessError as e:
        logging.error(f"Error during IPFS cluster fix: {str(e)}")
        return False


def check_and_fix_ipfs_host():
    ipfs_host_logs = subprocess.getoutput("sudo docker logs ipfs_host --tail 10 2>&1")
    
    if "Error: invalid or no prefix in shard identifier:" in ipfs_host_logs or "Error: directory missing SHARDING file:" in ipfs_host_logs or "mkdir /uniondrive/ipfs_datastore/blocks/X3: no such file or directory" in ipfs_host_logs:
        logging.warning("IPFS Host issue 1 detected. Attempting to fix.")
        subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True)
        time.sleep(10)
        ipfs_dir = "/uniondrive/ipfs_datastore/blocks"
        if os.path.exists(ipfs_dir):
            subprocess.run(["sudo", "rm", "-rf", ipfs_dir])
            logging.info("Ipfs Blocks directory contents removed.")
        else:
            logging.warning("Ipfs Blocks directory not found.")
        subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True)
        time.sleep(30)
        return True
    
    return False

def check_and_fix_node():
    fula_node_logs = subprocess.getoutput("sudo docker logs fula_node --tail 5 2>&1")
    
    if "Invalid argument: Column families not opened:" in fula_node_logs:
        logging.warning("Fula Node issue 1 detected. Attempting to fix.")
        fula_node_dir = "/uniondrive/chain/chains/functionyard/db/full"
        if os.path.exists(fula_node_dir):
            subprocess.run(["sudo", "rm", "-rf", fula_node_dir])
            logging.info("Fula Node directory contents removed.")
        else:
            logging.warning("Fula Node  directory not found.")

        subprocess.run(["sudo", "docker", "restart", "fula_node"], capture_output=True)
        time.sleep(30)
        return True
    
    return False

def check_internet_connection():
    try:
        requests.head("https://www.google.com", timeout=5)
        logging.info("Internet connection is available.")
        return True
    except requests.ConnectionError:
        logging.error("No internet connection available.")
        return False

def safe_run(command):
    try:
        subprocess.run(command, check=True)
    except subprocess.CalledProcessError as e:
        logging.error(f'Error running command {command}: {e}')

def format_drive(drive):
    try:
        # Delete all partitions on the drive
        safe_run(["sudo", "wipefs", "--all", drive])
        
        # Create a new partition table and a single ext4 partition
        safe_run(["sudo", "parted", "-s", drive, "mklabel", "gpt"])
        safe_run(["sudo", "parted", "-s", drive, "mkpart", "primary", "ext4", "0%", "100%"])
        
        # Format the new partition as ext4
        partition = f"{drive}1"  # Assuming the first partition is created
        safe_run(["sudo", "mkfs.ext4", partition])

        logging.info(f'Successfully formatted {drive} as ext4')
        return True
    except subprocess.CalledProcessError as e:
        logging.error(f'Error during formatting the drive {drive}: {e}')
        return False

def check_external_drive():
    logging.info("Checking external drives for correct formatting")
    try:
        blkid_output = subprocess.check_output(["sudo", "blkid"], universal_newlines=True)
        drives = [line.split(':') for line in blkid_output.splitlines() if line.startswith('/dev/sd') or line.startswith('/dev/nvme')]
        
        for drive_info in drives:
            drive = drive_info[0]
            fstype = next((item.split('=')[1].strip('"') for item in drive_info[1].split() if item.startswith('TYPE=')), None)
            
            # Check the disk size
            size_output = subprocess.check_output(["sudo", "lsblk", "-b", "-n", "-o", "SIZE", drive], universal_newlines=True)
            disk_size = int(size_output.split()[0])  # Size in bytes
            disk_size_gb = disk_size / (1024 ** 3)  # Convert to GB

            if fstype and (fstype.lower() != 'ext4') and (disk_size_gb > 500):
                logging.warning(f"Drive {drive} is formatted as {fstype} and is larger than 500GB. Attempting to fix.")
                
                # Stop services
                safe_run(["sudo", "systemctl", "stop", "fula.service"])
                time.sleep(10)
                safe_run(["sudo", "systemctl", "stop", "uniondrive.service"])
                time.sleep(10)

                # Stop automount service for the drive
                partition = drive.split('/')[-1]
                safe_run(["sudo", "systemctl", "stop", f"automount@{partition}.service"])
                time.sleep(10)

                # Delete mount folder
                mount_folder = f"/media/pi/{partition}"
                if os.path.exists(mount_folder):
                    safe_run(["sudo", "umount", mount_folder])
                    time.sleep(5)
                    safe_run(["sudo", "rm", "-rf", mount_folder])

                # Delete and recreate /uniondrive
                if os.path.exists("/uniondrive"):
                    safe_run(["sudo", "rm", "-rf", "/uniondrive"])
                safe_run(["sudo", "mkdir", "/uniondrive"])
                safe_run(["sudo", "chown", "-R", "pi:pi", "/uniondrive"])
                safe_run(["sudo", "chmod", "-R", "777", "/uniondrive"])

                # Format the drive as ext4
                format_drive(drive)

                return True

        logging.info("No drives needing format correction found")
        return False
        
    except subprocess.CalledProcessError as e:
        logging.error(f"Error in check_external_drive: {e}")
        return False
    except Exception as e:
        logging.error(f"Unexpected error in check_external_drive: {e}")
        return False

def monitor_docker_logs_and_restart():
    if not check_internet_connection():
        logging.error("No internet connection. Skipping Docker log monitoring and restart.")
        subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"])
        time.sleep(500)
        return
    
    containers_to_check = ["fula_go", "ipfs_host", "ipfs_cluster"]
    restart_attempts = 0
    if check_external_drive():
        # a partition needs reformatting, skip the loop and go to partition section
        restart_attempts = 3

    while restart_attempts < 3:
        logging.info("Entered into monitor while loop")
        time.sleep(450)
        get_wifi_info_and_ping()
        # Check if Docker service is running
        docker_service_status = subprocess.getoutput("sudo systemctl is-active docker.service")
        if not check_conditions():
            logging.error("conditions not pass")
            subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"])
            subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True)
            subprocess.run(["sudo", "systemctl", "stop", "docker.service"], capture_output=True)
            time.sleep(15)
            subprocess.run(["sudo", "systemctl", "restart", "uniondrive.service"], capture_output=True)
            # Wait a moment to let Docker restart
            time.sleep(15)
            subprocess.run(["sudo", "systemctl", "start", "docker.service"], capture_output=True)
            # Wait a moment to let Docker restart
            time.sleep(20)
            subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True)
            time.sleep(35)
            restart_attempts += 1
            continue
        else:
            logging.info("condition_check inside monitor passed")

        while "active" not in docker_service_status and restart_attempts < 3:
            logging.error("Docker service is not running. Attempting to restart Docker service.")
            subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"])
            subprocess.run(["sudo", "systemctl", "restart", "docker.service"], capture_output=True)
            # Wait a moment to let Docker restart
            time.sleep(15)
            subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True)
            time.sleep(35)
            restart_attempts += 1
            docker_service_status = subprocess.getoutput("sudo systemctl is-active docker.service")

        all_containers_running = True
        for container in containers_to_check:
            container_running = container in subprocess.getoutput("sudo docker ps --format '{{.Names}}'")
            if container_running:
                logging.info(f"container_running inside monitor passed for {container}")
                logs = subprocess.getoutput(f"sudo docker logs --tail 15 {container} 2>&1")
                if "ERROR:" in logs:
                    logging.error(f"{container} logs contain ERROR:. Attempting to restart fula.service")
                    container_running = False
                else:
                    logging.info(f"no ERROR found in the logs of {container}")
            else:
                all_containers_running = False
                logging.error(f"{container} is not running or logs contain ERROR:. Attempting to restart fula.service")
                subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"])
                result = subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True)
                time.sleep(5)
                if result.returncode == 0:
                    logging.info(f"fula.service restarted successfully for {container}.")
                    subprocess.run(["sudo", "python", LED_PATH, "blue", "5"])
                else:
                    logging.error(f"Failed to restart fula.service for {container}.")
                    subprocess.run(["sudo", "python", LED_PATH, "red", "5"])
                    if result.stderr:
                        logging.error(f"Restart error: {result.stderr}")
                time.sleep(60)  # Delay between restart attempts
                break  # Break to re-check all containers after an attempt
            
        if all_containers_running:
            # If all containers are running and logs are clean, reset attempts and continue monitoring
            restart_attempts = 0
            subprocess.run(["sudo", "python", LED_PATH, "green", "1"])
        else:
            restart_attempts += 1
        
        ipfs_cluster_fixed = check_and_fix_ipfs_cluster()
        ipfs_host_fixed = check_and_fix_ipfs_host()
        if ipfs_cluster_fixed or ipfs_host_fixed:
            restart_attempts += 1
            
        fula_node_fixed = check_and_fix_node()

    if restart_attempts >= 3:
        logging.error("Maximum restart attempts reached. Checking .reboot_flag status.")
        current_time = time.time()
        
        if os.path.exists(REBOOT_FLAG_PATH):
            file_mod_time = os.path.getmtime(REBOOT_FLAG_PATH)
            time_difference = current_time - file_mod_time
            
            if time_difference < 24 * 60 * 60:  # 24 hours in seconds
                # Issue persists even after reboot within 24 hours
                logging.error("Issue persists after recent reboot. Flashing red and stopping further actions.")
                while True:
                    subprocess.run(["sudo", "python", LED_PATH, "red", "10"])
                    get_wifi_info_and_ping()
                    time.sleep(5)
            else:
                # More than 24 hours have passed, update the reboot flag
                logging.warning("Previous reboot flag is older than 24 hours. Updating and initiating re-partition process.")
                subprocess.run(['sudo', 'rm', REBOOT_FLAG_PATH])
                time.sleep(2)
                subprocess.run(['sudo', 'touch', REBOOT_FLAG_PATH])
                subprocess.run(['sudo', 'touch', COMMAND_PARTITION_PATH])
                subprocess.run(["sudo", "python", LED_PATH, "purple", "5"])
        else:
            # No existing reboot flag, create it and initiate re-partition process
            logging.warning("No existing reboot flag. Creating flag and initiating re-partition process.")
            subprocess.run(['sudo', 'touch', REBOOT_FLAG_PATH])
            subprocess.run(['sudo', 'touch', COMMAND_PARTITION_PATH])
            subprocess.run(["sudo", "python", LED_PATH, "purple", "5"])

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
                subprocess.run(["sudo", "python", LED_PATH, "cyan", "5"])
            elif wifi_status == "other":
                logging.info("wifi_status other")
                subprocess.run(["sudo", "python", LED_PATH, "green", "30"])
                while True:
                    monitor_docker_logs_and_restart()
            else:
                logging.info("wifi_status not connected")
                if cycles_with_no_wifi == 6:
                    logging.info("wifi not connected, attempting to start FxBlox hotspot")
                    attempt_wifi_connection()
                    cycles_with_no_wifi = 0

                subprocess.run(["sudo", "python", LED_PATH, "red", "10"])
                cycles_with_no_wifi += 1
                time.sleep(10)
        else:
            logging.info("check_conditions failed")
            # Check if 'fula_go' exists in `docker ps -a`
            docker_ps_a_output = subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'")
            docker_ps_output = subprocess.getoutput("sudo docker ps --format '{{.Names}}'")

            if "fula_go" in docker_ps_a_output and \
                all(container in docker_ps_output for container in ["fula_fxsupport", "fula_updater"]) and \
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
            time.sleep(20)

if __name__ == "__main__":
    main()
