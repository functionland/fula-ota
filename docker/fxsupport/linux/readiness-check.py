# Watcher for Fula tower v1.2
import os
import subprocess
import time
import logging
import sys
import requests
import re
import threading
import shutil
import yaml

FULA_PATH = "/usr/bin/fula"
HOME_PATH = "/home/pi"
COMMAND_PARTITION_PATH = os.path.join(HOME_PATH, "commands/.command_partition")
REBOOT_FLAG_PATH = os.path.join(HOME_PATH, ".reboot_flag")
LED_PATH = os.path.join(FULA_PATH, "control_led.py")

RELAY_MULTIADDR = "/dns/relay.dev.fx.land/tcp/4001/p2p/12D3KooWDRrBaAfPwsGJivBoUw5fE7ZpDiyfUjqgiURq2DEcL835"
IPFS_API_URL = "http://127.0.0.1:5001"
BOOTSTRAP_PEERS = [
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
    "/ip4/172.65.0.13/tcp/4009/p2p/QmcfgsJsMtx6qJb74akCw1M24X1zFwgGo11h1cuhwQjtJP",
]

# Configure logging to write to standard output
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    stream=sys.stdout,
)

# Global variables to control LED flashing
led_flash_thread = None
led_flash_stop_event = None

# Counter for consecutive relay connection failures with broken swarm
relay_fail_count = 0

# YAML invalid control characters (all control chars except tab, newline, carriage return)
YAML_INVALID_CHARS = set(range(0x00, 0x09)) | {0x0B, 0x0C} | set(range(0x0E, 0x20))


def has_yaml_invalid_chars(content):
    """Check for control characters that YAML parsers reject.

    YAML allows: tab (0x09), newline (0x0A), carriage return (0x0D)
    YAML rejects: all other control characters (0x00-0x08, 0x0B-0x0C, 0x0E-0x1F)

    Args:
        content: bytes content to check

    Returns:
        tuple: (has_invalid, list of (byte_value, position) for invalid chars found)
    """
    invalid_found = []
    for i, byte in enumerate(content):
        if byte in YAML_INVALID_CHARS:
            invalid_found.append((byte, i))
    return (len(invalid_found) > 0, invalid_found)


def validate_yaml_syntax(file_path):
    """Validate YAML file syntax.

    Args:
        file_path: Path to the YAML file to validate

    Returns:
        tuple: (is_valid, error_message or None)
    """
    try:
        with open(file_path, 'r') as f:
            yaml.safe_load(f)
        return True, None
    except yaml.YAMLError as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


def backup_config_if_valid(config_path):
    """Create backup of config if it's valid YAML.

    Args:
        config_path: Path to the config file

    Returns:
        bool: True if backup was created successfully
    """
    backup_path = config_path + ".backup"
    try:
        is_valid, _ = validate_yaml_syntax(config_path)
        if is_valid:
            shutil.copy2(config_path, backup_path)
            logging.info(f"Created backup: {backup_path}")
            return True
        else:
            logging.debug(f"Config not valid, skipping backup: {config_path}")
            return False
    except Exception as e:
        logging.error(f"Error creating backup of {config_path}: {e}")
        return False


def restore_config_from_backup(config_path):
    """Restore config from backup if available and valid.

    Args:
        config_path: Path to the config file to restore

    Returns:
        bool: True if config was restored successfully
    """
    backup_path = config_path + ".backup"
    if os.path.exists(backup_path):
        try:
            is_valid, _ = validate_yaml_syntax(backup_path)
            if is_valid:
                shutil.copy2(backup_path, config_path)
                logging.info(f"Restored config from backup: {backup_path}")
                return True
            else:
                logging.warning(f"Backup file is not valid YAML: {backup_path}")
        except Exception as e:
            logging.error(f"Error restoring config from backup: {e}")
    return False


def check_disk_space(path="/uniondrive", min_gb=1):
    """Check if path has at least min_gb free space.

    Args:
        path: Path to check disk space for
        min_gb: Minimum free space in gigabytes

    Returns:
        tuple: (has_space, free_gb) - True if enough space, and the actual free GB
    """
    try:
        if not os.path.exists(path):
            logging.warning(f"Path does not exist for disk space check: {path}")
            return True, -1  # Don't block on missing path

        stat = os.statvfs(path)
        free_gb = (stat.f_bavail * stat.f_frsize) / (1024**3)

        if free_gb < min_gb:
            logging.warning(f"Low disk space on {path}: {free_gb:.2f}GB free (minimum: {min_gb}GB)")
            return False, free_gb

        logging.debug(f"Disk space OK on {path}: {free_gb:.2f}GB free")
        return True, free_gb
    except Exception as e:
        logging.error(f"Failed to check disk space on {path}: {e}")
        return True, -1  # Don't block on error

def check_proxy_health():
    """Check if go-fula proxy ports (4020/4021) are reachable.
    These ports handle kubo->go-fula p2p stream forwarding for blockchain and ping.
    """
    import socket
    ports_ok = True
    for port in [4020, 4021]:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                pass
        except (ConnectionRefusedError, OSError, socket.timeout):
            logging.warning(f"go-fula proxy port {port} is not reachable on 127.0.0.1")
            ports_ok = False
    return ports_ok


def check_peerid_collision():
    """Detect if kubo and ipfs-cluster have the same PeerID (known failure mode)."""
    try:
        kubo_resp = requests.post("http://127.0.0.1:5001/api/v0/id", timeout=10)
        kubo_id = kubo_resp.json().get("ID", "")

        cluster_resp = requests.get("http://127.0.0.1:9094/id", timeout=10)
        cluster_id = cluster_resp.json().get("id", "")

        if kubo_id and cluster_id and kubo_id == cluster_id:
            logging.error(f"PeerID COLLISION: kubo and ipfs-cluster share PeerID {kubo_id}")
            return True
        return False
    except Exception as e:
        logging.debug(f"PeerID collision check skipped: {e}")
        return False


def start_led_flash(color, interval=1):
    """
    Start flashing the LED with the specified color at the given interval.
    Uses threading instead of temporary files.
    
    Args:
        color: The color to flash
        interval: Time in seconds between flashes
    """
    global led_flash_thread, led_flash_stop_event
    
    # Stop any existing flash thread
    stop_led_flash()
    
    # Create a new stop event
    led_flash_stop_event = threading.Event()
    
    def flash_led_worker():
        """Worker function that flashes the LED until stopped."""
        stop_event = led_flash_stop_event
        if stop_event is None:
            return
        while not stop_event.is_set():
            try:
                # Turn on LED
                subprocess.run(
                    ["sudo", "python", LED_PATH, color, str(interval)],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    check=False, timeout=30
                )

                # Wait for the interval or until stopped
                if stop_event.wait(timeout=interval):
                    break

            except subprocess.TimeoutExpired:
                logging.warning("LED flash subprocess timed out")
            except Exception as e:
                logging.error(f"Error in LED flash thread: {str(e)}")
                # Brief pause to prevent CPU spinning in case of repeated errors
                time.sleep(0.5)
                
        logging.debug("LED flash thread exiting")
    
    # Create and start the thread
    led_flash_thread = threading.Thread(target=flash_led_worker, daemon=True)
    led_flash_thread.start()
    logging.info(f"Started LED flashing with color {color}")

def stop_led_flash():
    """
    Stop the flashing LED thread if it exists.
    This only terminates our flashing thread, not other LED control processes.
    """
    global led_flash_thread, led_flash_stop_event
    
    if led_flash_thread and led_flash_thread.is_alive():
        if led_flash_stop_event:
            # Signal the thread to stop
            led_flash_stop_event.set()
            
            # Wait for the thread to exit (with timeout)
            led_flash_thread.join(timeout=2.0)
            
            if led_flash_thread.is_alive():
                logging.warning("LED flash thread did not exit cleanly")
            else:
                logging.info("Stopped LED flashing thread")
        
        # Reset the globals
        led_flash_thread = None
        led_flash_stop_event = None

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
    elif "wifi" in output or "ethernet" in output:
        return "other"
    return None

def attempt_wifi_connection():
    config_yaml_path = os.path.join(HOME_PATH, ".internal", "config.yaml")
    if os.path.exists(config_yaml_path):
        logging.info("config.yaml exists, checking for non-FxBlox WiFi connections")
        # LED flashing yellow code here to indicate connection attempt
        start_led_flash("yellow")
        connections_output = subprocess.getoutput("sudo nmcli con show | grep wifi")
        wifi_connections = [line.split()[0] for line in connections_output.split('\n') if "wifi" in line and "FxBlox" not in line]
        
        wifi_connected = False
        connections_to_remove = []
        
        for wifi_con in wifi_connections:
            logging.info(f"Attempting to connect to {wifi_con}")
            
            # Try to connect to the WiFi network
            result = subprocess.run(["sudo", "nmcli", "con", "up", wifi_con], 
                                   capture_output=True, text=True, timeout=30)
            
            if result.returncode == 0:
                logging.info(f"Successfully connected to {wifi_con}")
                # stop LED flashing yellow code here
                stop_led_flash()
                # LED flashing blue code here to indicate connection successful
                start_led_flash("blue")
                
                # Verify internet connectivity by pinging a reliable server
                ping_result = subprocess.run(["ping", "-c", "3", "-W", "5", "8.8.8.8"], 
                                           capture_output=True, text=True)
                
                if ping_result.returncode == 0:
                    logging.info(f"Internet connection verified for {wifi_con}")
                    wifi_connected = True
                    # stop LED flashing blue code here
                    stop_led_flash()
                    # LED flashing green code here to indicate ping successful
                    start_led_flash("green")
                    break
                else:
                    # LED flashing yellow code here to indicate connection attempt
                    stop_led_flash()
                    start_led_flash("yellow")
                    logging.warning(f"Connected to {wifi_con} but no internet access")
                    # Disconnect from this network as it has no internet
                    subprocess.run(["sudo", "nmcli", "con", "down", wifi_con], 
                                  capture_output=True, text=True)
            else:
                # Check specific error conditions that indicate the network is unreachable
                error_output = result.stderr.lower()
                if any(err in error_output for err in [
                    "no carrier", 
                    "connection activation failed",
                    "timeout",
                    "authentication required",
                    "wrong password",
                    "not found"
                ]):
                    logging.error(f"Connection to {wifi_con} failed permanently: {error_output}")
                    connections_to_remove.append(wifi_con)
                else:
                    logging.error(f"Failed to connect to {wifi_con}: {error_output}")
        
        # Remove networks that failed with permanent errors
        for conn_name in connections_to_remove:
            try:
                logging.warning(f"Removing problematic WiFi connection: {conn_name}")
                remove_result = subprocess.run(["sudo", "nmcli", "con", "delete", conn_name], 
                                             capture_output=True, text=True, timeout=10)
                
                if remove_result.returncode == 0:
                    logging.info(f"Successfully removed WiFi connection: {conn_name}")
                else:
                    logging.error(f"Failed to remove WiFi connection {conn_name}: {remove_result.stderr}")
            except (subprocess.SubprocessError, subprocess.TimeoutExpired) as e:
                logging.error(f"Error while removing WiFi connection {conn_name}: {str(e)}")
        
        # Check if we removed any bad connections
        if len(connections_to_remove) > 0:
            logging.info(f"Removed {len(connections_to_remove)} problematic WiFi connections. Rebooting system.")
            stop_led_flash()
            # Turn LED purple for 5 seconds
            subprocess.run(["sudo", "python", LED_PATH, "purple", "5"], capture_output=True)
            time.sleep(5)  # Wait for LED to show for 5 seconds
            # Reboot the system
            subprocess.run(["sudo", "reboot"], capture_output=True)
            # Exit function as system is rebooting
            return None
            
        connections_to_remove = []
        # If no successful connection, log the result but don't start hotspot
        if not wifi_connected:
            logging.info("No successful WiFi connections, defaulting to FxBlox hotspot")
            # LED status update code here
            stop_led_flash()
            subprocess.run(["sudo", "python", LED_PATH, "red", "5"], capture_output=True)
            # stop LED flashing all codes here
            # Note: Hotspot will be started by another script

    else:
        logging.info("config.yaml does not exist, another script will handle hotspot")
        # LED status update code here
        subprocess.run(["sudo", "python", LED_PATH, "cyan", "5"], capture_output=True)

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
                subprocess.run(["sudo", "rm", "-rf", pebble_dir], capture_output=True, check=True)
                subprocess.run(["sudo", "mkdir", "-p", pebble_dir], capture_output=True, check=True)
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
            container_id = subprocess.getoutput("sudo docker inspect --format='{{.Id}}' ipfs_cluster 2>/dev/null")
            if container_id:
                try:
                    subprocess.run(["sudo", "truncate", "-s", "0", f"/var/lib/docker/containers/{container_id}/{container_id}-json.log"], check=True)
                    logging.info("fix applied and IPFS Cluster logs cleared successfully.")
                except subprocess.CalledProcessError:
                    logging.warning("Failed to truncate logs, but applied with the fix of ipfs cluster")
        
        return cluster_error_found
    except subprocess.CalledProcessError as e:
        logging.error(f"Error during IPFS cluster fix: {str(e)}")
        return False


def check_and_fix_ipfs_host():
    ipfs_host_logs = subprocess.getoutput("sudo docker logs ipfs_host --tail 17 2>&1")
    
    # Check for "error loading plugins" and handle corrupted config files
    if "error loading plugins" in ipfs_host_logs:
        logging.warning("IPFS Host 'error loading plugins' detected. Checking for corrupted config files.")

        # Check /home/pi/.internal/ipfs_data/config for invalid control characters
        ipfs_config_path = "/home/pi/.internal/ipfs_data/config"
        if os.path.exists(ipfs_config_path):
            try:
                with open(ipfs_config_path, 'rb') as f:
                    content = f.read()
                has_invalid, invalid_chars = has_yaml_invalid_chars(content)
                if has_invalid:
                    # Log the specific corruption found
                    char_summary = ", ".join([f"0x{byte:02x} at pos {pos}" for byte, pos in invalid_chars[:5]])
                    if len(invalid_chars) > 5:
                        char_summary += f" ... and {len(invalid_chars) - 5} more"
                    logging.warning(f"Invalid control characters found in {ipfs_config_path}: {char_summary}")
                    subprocess.run(["sudo", "rm", "-f", ipfs_config_path], capture_output=True, check=True)
                    logging.info(f"Deleted corrupted IPFS config: {ipfs_config_path}")
            except Exception as e:
                logging.error(f"Error checking IPFS config file: {str(e)}")

        # Check /home/pi/.internal/config.yaml for invalid control characters
        config_yaml_path = "/home/pi/.internal/config.yaml"
        if os.path.exists(config_yaml_path):
            try:
                with open(config_yaml_path, 'rb') as f:
                    content = f.read()
                has_invalid, invalid_chars = has_yaml_invalid_chars(content)
                if has_invalid:
                    # Log the specific corruption found
                    char_summary = ", ".join([f"0x{byte:02x} at pos {pos}" for byte, pos in invalid_chars[:5]])
                    if len(invalid_chars) > 5:
                        char_summary += f" ... and {len(invalid_chars) - 5} more"
                    logging.warning(f"Invalid control characters found in {config_yaml_path}: {char_summary}")

                    # Try to restore from backup first
                    if restore_config_from_backup(config_yaml_path):
                        logging.info("Config restored from backup in check_and_fix_ipfs_host.")
                    else:
                        # No valid backup, delete corrupted config
                        subprocess.run(["sudo", "rm", "-f", config_yaml_path], capture_output=True, check=True)
                        logging.info(f"Deleted corrupted config.yaml: {config_yaml_path}")
                else:
                    # No control char issues, but check YAML syntax too
                    is_valid, yaml_error = validate_yaml_syntax(config_yaml_path)
                    if not is_valid:
                        logging.warning(f"YAML syntax error in {config_yaml_path}: {yaml_error}")
                        if restore_config_from_backup(config_yaml_path):
                            logging.info("Config restored from backup after YAML syntax error.")
                        else:
                            subprocess.run(["sudo", "rm", "-f", config_yaml_path], capture_output=True, check=True)
                            logging.info(f"Deleted config.yaml with syntax error: {config_yaml_path}")
            except Exception as e:
                logging.error(f"Error checking config.yaml file: {str(e)}")

        # Restart fula service
        logging.info("Restarting fula service after fixing error loading plugins issue.")
        subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
        time.sleep(30)
        return True
    
    # Check for migration permission error
    if "embedded migration fs-repo-16-to-17 failed: open /internal/ipfs_data/version: permission denied" in ipfs_host_logs:
        logging.warning("IPFS Host migration permission error detected. Fixing version file.")
        
        version_file_path = "/home/pi/.internal/ipfs_data/version"
        try:
            # Write "17" to the version file (no newline)
            subprocess.run(["sudo", "tee", version_file_path],
                         input=b"17", capture_output=True, check=True, timeout=20)
            logging.info(f"Successfully updated {version_file_path} with version 17")

            # Restart fula service
            logging.info("Restarting fula service after fixing migration permission issue.")
            subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
            time.sleep(30)
            return True
        except Exception as e:
            logging.error(f"Error fixing migration permission issue: {str(e)}")
    
    # Check for version mismatch errors and fix version file
    version_file_path = "/home/pi/.internal/ipfs_data/version"
    if "Error: Your programs version (17) is lower than your repos" in ipfs_host_logs:
        logging.warning("IPFS Host version mismatch detected (program version 17 lower than repo). Updating version file to 17.")
        try:
            # Write "17" to the version file (no newline)
            subprocess.run(["sudo", "tee", version_file_path],
                         input=b"17", capture_output=True, check=True, timeout=20)
            logging.info(f"Successfully updated {version_file_path} with version 17")

            # Restart fula service
            logging.info("Restarting fula service after fixing version mismatch.")
            subprocess.run(["sudo", "docker", "restart", "ipfs_host"], capture_output=True, check=True)
            time.sleep(30)
            return True
        except Exception as e:
            logging.error(f"Error fixing version mismatch (17): {str(e)}")
    
    if "Error: Your programs version (16) is lower than your repos" in ipfs_host_logs:
        logging.warning("IPFS Host version mismatch detected (program version 16 lower than repo). Updating version file to 16.")
        try:
            # Write "16" to the version file (no newline)
            subprocess.run(["sudo", "tee", version_file_path],
                         input=b"16", capture_output=True, check=True, timeout=20)
            logging.info(f"Successfully updated {version_file_path} with version 16")
            
            # Restart fula service
            logging.info("Restarting fula service after fixing version mismatch.")
            subprocess.run(["sudo", "docker", "restart", "ipfs_host"], capture_output=True, check=True)
            time.sleep(30)
            return True
        except Exception as e:
            logging.error(f"Error fixing version mismatch (16): {str(e)}")
    
    if "Error: invalid or no prefix in shard identifier:" in ipfs_host_logs or "Error: directory missing SHARDING file:" in ipfs_host_logs or "mkdir /uniondrive/ipfs_datastore/blocks/X3: no such file or directory" in ipfs_host_logs:
        logging.warning("IPFS Host issue 1 detected. Attempting to fix.")
        subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True)
        time.sleep(10)
        ipfs_dir = "/uniondrive/ipfs_datastore/blocks"
        if os.path.exists(ipfs_dir):
            subprocess.run(["sudo", "rm", "-rf", ipfs_dir], capture_output=True, check=True)
            logging.info("Ipfs Blocks directory removed.")
        else:
            logging.warning("Ipfs Blocks directory not found.")
        subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True)
        time.sleep(30)
        return True

    if "could not get pinset from IPFS: Post" in ipfs_host_logs and "context deadline exceeded" in ipfs_host_logs:
        logging.warning("IPFS Host issue 2 detected. Restarting the container.")
        subprocess.run(["sudo", "docker", "restart", "ipfs_host"], capture_output=True)
        return True

    if "failed to open pebble database: pebble: database" in ipfs_host_logs:
        logging.warning("IPFS Host issue 3 detected. Restarting the container.")
        subprocess.run(["sudo", "docker", "stop", "ipfs_host"], capture_output=True)

        time.sleep(10)
        ipfs_dir = "/uniondrive/ipfs_datastore/blocks"
        if os.path.exists(ipfs_dir):
            subprocess.run(["sudo", "rm", "-rf", ipfs_dir], capture_output=True, check=True)
            logging.info("Ipfs Blocks directory removed.")
        else:
            logging.warning("Ipfs Blocks directory not found.")

        ipfs_datastore_dir = "/uniondrive/ipfs_datastore/datastore"
        if os.path.exists(ipfs_datastore_dir):
            subprocess.run(["sudo", "rm", "-rf", ipfs_datastore_dir], capture_output=True, check=True)
            subprocess.run(["sudo", "mkdir", "-p", ipfs_datastore_dir], capture_output=True, check=True)
            logging.info("Ipfs Datastore directory contents removed.")
        else:
            logging.warning("Ipfs Datastore directory not found.")

        subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True)
        time.sleep(30)
        return True

    # Relay connection check
    global relay_fail_count

    if not check_internet_connection():
        return False

    try:
        requests.post(IPFS_API_URL + "/api/v0/id", timeout=10)
    except Exception:
        logging.info("IPFS API not responding, skipping relay check.")
        return False

    config_yaml_path = os.path.join(HOME_PATH, ".internal", "config.yaml")
    if not os.path.exists(config_yaml_path):
        logging.info("config.yaml does not exist, skipping relay check (device not configured).")
        return False

    try:
        relay_response = requests.post(
            IPFS_API_URL + "/api/v0/swarm/connect",
            params={"arg": RELAY_MULTIADDR},
            timeout=15
        )
        relay_json = relay_response.json()
        relay_strings = relay_json.get("Strings", [])

        if any("success" in s.lower() for s in relay_strings):
            logging.info("Relay connection successful.")
            relay_fail_count = 0
            return False

        logging.warning(f"Relay connection failed: {relay_strings}")
    except Exception as e:
        logging.warning(f"Relay connection attempt failed: {e}")

    # Relay failed — verify swarm health by connecting to bootstrap peers
    bootstrap_successes = 0
    for peer in BOOTSTRAP_PEERS:
        try:
            resp = requests.post(
                IPFS_API_URL + "/api/v0/swarm/connect",
                params={"arg": peer},
                timeout=10
            )
            peer_json = resp.json()
            peer_strings = peer_json.get("Strings", [])
            if any("success" in s.lower() for s in peer_strings):
                bootstrap_successes += 1
        except Exception:
            pass

    if bootstrap_successes >= 2:
        logging.info(
            f"Relay unreachable but swarm healthy ({bootstrap_successes}/{len(BOOTSTRAP_PEERS)} bootstrap peers connected). "
            "Not incrementing failure count."
        )
        relay_fail_count = 0
        return False

    # Swarm is broken — increment failure counter
    relay_fail_count += 1
    if relay_fail_count >= 5:
        logging.warning(
            f"Relay and swarm connectivity failed {relay_fail_count} consecutive times. "
            "Restarting fula.service."
        )
        relay_fail_count = 0
        subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True)
        time.sleep(30)
        return True

    logging.info(
        f"Relay and swarm connectivity failed ({relay_fail_count}/5). "
        "Will retry next cycle."
    )
    return False


def check_and_fix_config_yaml():
    """Check fula_go container logs for config.yaml errors and fix them.

    This function monitors fula_go logs for YAML parsing errors that indicate
    config.yaml corruption, including:
    - "yaml: control characters are not allowed"
    - "Failed to unmarshal YAML config"
    - "Failed to read YAML config"
    - "parsing config.yaml:"
    - "Unable to load Yaml file '/internal/config.yaml'"
    - initipfs/initipfscluster exit code errors

    Returns:
        bool: True if an issue was detected and fixed, False otherwise
    """
    try:
        # Check fula_go container logs for config errors
        fula_go_logs = subprocess.getoutput("sudo docker logs fula_go --tail 50 2>&1")

        # Error patterns from go-fula source code
        config_error_patterns = [
            "yaml: control characters are not allowed",
            "Failed to unmarshal YAML config",
            "Failed to read YAML config",
            "parsing config.yaml:",
            "Unable to load Yaml file '/internal/config.yaml'",
            "Unable to load Yaml file",
            "Unmarshal failed",
            "The initipfs exited with an error: Exit code",
            "The initipfscluster exited with an error: Exit code",
        ]

        config_error_found = False
        matched_pattern = None
        for pattern in config_error_patterns:
            if pattern in fula_go_logs:
                config_error_found = True
                matched_pattern = pattern
                break

        if not config_error_found:
            return False

        logging.warning(f"Config YAML error detected in fula_go logs: '{matched_pattern}'")

        config_yaml_path = "/home/pi/.internal/config.yaml"

        if not os.path.exists(config_yaml_path):
            logging.info(f"Config file does not exist: {config_yaml_path}")
            # Restart fula service to regenerate config
            logging.info("Restarting fula service to regenerate config.")
            subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
            time.sleep(30)
            return True

        # Check for invalid control characters
        try:
            with open(config_yaml_path, 'rb') as f:
                content = f.read()

            has_invalid, invalid_chars = has_yaml_invalid_chars(content)

            if has_invalid:
                # Log the specific corruption found
                char_summary = ", ".join([f"0x{byte:02x} at pos {pos}" for byte, pos in invalid_chars[:5]])
                if len(invalid_chars) > 5:
                    char_summary += f" ... and {len(invalid_chars) - 5} more"
                logging.warning(f"Invalid control characters found in {config_yaml_path}: {char_summary}")

                # Try to restore from backup first
                if restore_config_from_backup(config_yaml_path):
                    logging.info("Config restored from backup. Restarting fula service.")
                    subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
                    time.sleep(30)
                    return True

                # No valid backup, delete corrupted config
                logging.warning(f"No valid backup available. Deleting corrupted config: {config_yaml_path}")
                subprocess.run(["sudo", "rm", "-f", config_yaml_path], capture_output=True, check=True)
                logging.info(f"Deleted corrupted config.yaml: {config_yaml_path}")

                # Restart fula service
                logging.info("Restarting fula service after removing corrupted config.")
                subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
                time.sleep(30)
                return True

        except Exception as e:
            logging.error(f"Error checking config.yaml for invalid chars: {e}")

        # Also validate YAML syntax
        is_valid, yaml_error = validate_yaml_syntax(config_yaml_path)
        if not is_valid:
            logging.warning(f"YAML syntax error in {config_yaml_path}: {yaml_error}")

            # Try to restore from backup first
            if restore_config_from_backup(config_yaml_path):
                logging.info("Config restored from backup after YAML syntax error. Restarting fula service.")
                subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
                time.sleep(30)
                return True

            # No valid backup, delete corrupted config
            logging.warning(f"No valid backup available. Deleting config with syntax error: {config_yaml_path}")
            subprocess.run(["sudo", "rm", "-f", config_yaml_path], capture_output=True, check=True)
            logging.info(f"Deleted config.yaml with syntax error: {config_yaml_path}")

            # Restart fula service
            logging.info("Restarting fula service after removing config with syntax error.")
            subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
            time.sleep(30)
            return True

        # Config appears valid but error was still detected - try restart anyway
        logging.info("Config appears valid but error was detected. Restarting fula service.")
        subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, check=True)
        time.sleep(30)
        return True

    except subprocess.CalledProcessError as e:
        logging.error(f"Error during config.yaml fix: {str(e)}")
        return False
    except Exception as e:
        logging.error(f"Unexpected error in check_and_fix_config_yaml: {str(e)}")
        return False


def check_internet_connection():
    try:
        requests.head("https://www.google.com", timeout=5)
        logging.info("Internet connection is available.")
        return True
    except requests.RequestException:
        logging.error("No internet connection available.")
        return False


def safe_run(command):
    try:
        subprocess.run(command, check=True, timeout=120)
    except subprocess.TimeoutExpired:
        logging.error(f'Command timed out after 120s: {command}')
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

def activate_wireguard_support():
    """Start WireGuard support tunnel if installed and not already active."""
    try:
        service_file = "/etc/systemd/system/wireguard-support.service"
        if not os.path.exists(service_file):
            logging.debug("wireguard-support.service not installed, skipping activation")
            return

        result = subprocess.run(
            ["systemctl", "is-active", "wireguard-support.service"],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip() == "active":
            logging.debug("WireGuard support tunnel already active")
            return

        logging.info("Activating WireGuard support tunnel...")
        subprocess.Popen(
            ["sudo", "systemctl", "start", "wireguard-support.service"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL
        )
    except Exception as e:
        logging.error(f"Error activating WireGuard support: {e}")


def check_wireguard_health():
    """Verify WireGuard installation integrity when system is healthy."""
    try:
        install_script = "/usr/bin/fula/wireguard/install.sh"
        if not os.path.exists(install_script):
            return

        # Check if all components are present
        wg_exists = subprocess.run(
            ["which", "wg"], capture_output=True, timeout=5
        ).returncode == 0
        keys_exist = os.path.exists("/etc/wireguard/support_private.key")
        service_exists = os.path.exists("/etc/systemd/system/wireguard-support.service")

        if wg_exists and keys_exist and service_exists:
            return

        logging.info("WireGuard installation incomplete, running install.sh...")
        subprocess.run(
            ["sudo", "bash", install_script],
            capture_output=True, timeout=120
        )
    except Exception as e:
        logging.error(f"Error checking WireGuard health: {e}")


def monitor_docker_logs_and_restart():
    if not check_internet_connection():
        logging.error("No internet connection. Skipping Docker log monitoring and restart.")
        subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"], capture_output=True, timeout=20)
        time.sleep(120)
        return
    
    containers_to_check = ["fula_go", "ipfs_host", "ipfs_cluster"]
    restart_attempts = 0
    if check_external_drive():
        # a partition needs reformatting, skip the loop and go to partition section
        restart_attempts = 4

    while restart_attempts < 4:
        logging.info("Entered into monitor while loop")
        time.sleep(450)
        get_wifi_info_and_ping()
        # Check if Docker service is running
        docker_service_status = subprocess.getoutput("sudo systemctl is-active docker.service")
        if not check_conditions():
            logging.error("conditions not pass")
            subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"], capture_output=True, timeout=20)
            subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True, timeout=120)
            subprocess.run(["sudo", "systemctl", "stop", "docker.service"], capture_output=True, timeout=120)
            time.sleep(15)
            subprocess.run(["sudo", "systemctl", "restart", "uniondrive.service"], capture_output=True, timeout=120)
            # Wait a moment to let Docker restart
            time.sleep(15)
            subprocess.run(["sudo", "systemctl", "start", "docker.service"], capture_output=True, timeout=120)
            # Wait a moment to let Docker restart
            time.sleep(20)
            subprocess.run(["sudo", "systemctl", "start", "fula.service"], capture_output=True, timeout=120)
            time.sleep(35)
            restart_attempts += 1
            continue
        else:
            logging.info("condition_check inside monitor passed")

        while "active" not in docker_service_status and restart_attempts < 4:
            logging.error("Docker service is not running. Attempting to restart Docker service.")
            subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"], capture_output=True, timeout=20)
            subprocess.run(["sudo", "systemctl", "restart", "docker.service"], capture_output=True, timeout=120)
            # Wait a moment to let Docker restart
            time.sleep(15)
            subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, timeout=120)
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
                subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"], capture_output=True, timeout=20)
                result = subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, timeout=120)
                time.sleep(5)
                if result.returncode == 0:
                    logging.info(f"fula.service restarted successfully for {container}.")
                    subprocess.run(["sudo", "python", LED_PATH, "blue", "5"], capture_output=True, timeout=20)
                else:
                    logging.error(f"Failed to restart fula.service for {container}.")
                    subprocess.run(["sudo", "python", LED_PATH, "red", "5"], capture_output=True, timeout=20)
                    if result.stderr:
                        logging.error(f"Restart error: {result.stderr}")
                time.sleep(60)  # Delay between restart attempts
                break  # Break to re-check all containers after an attempt
            
        if all_containers_running:
            # Check go-fula proxy health
            if not check_proxy_health():
                logging.warning("go-fula proxy ports unreachable. Restarting fula.service.")
                subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, timeout=120)
                time.sleep(30)
                restart_attempts += 1
                continue

            # Check for PeerID collision between kubo and ipfs-cluster
            if check_peerid_collision():
                logging.warning("PeerID collision detected. Removing ipfs-cluster identity to regenerate.")
                service_json = "/uniondrive/ipfs-cluster/service.json"
                if os.path.exists(service_json):
                    subprocess.run(["sudo", "rm", "-f", service_json], capture_output=True, check=True, timeout=20)
                    logging.info(f"Deleted {service_json} to force PeerID regeneration.")
                subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, timeout=120)
                time.sleep(30)
                restart_attempts += 1
                continue

            # If all containers are running and logs are clean, reset attempts and continue monitoring
            restart_attempts = 0
            subprocess.run(["sudo", "python", LED_PATH, "green", "1"], capture_output=True, timeout=20)

            # Verify WireGuard installation integrity while healthy
            check_wireguard_health()

            # Create backup of valid config.yaml when system is healthy
            config_yaml_path = "/home/pi/.internal/config.yaml"
            if os.path.exists(config_yaml_path):
                backup_config_if_valid(config_yaml_path)
        else:
            restart_attempts += 1

        # Check disk space before running fixes (low disk can cause corruption)
        has_space, free_gb = check_disk_space("/uniondrive", min_gb=1)
        if not has_space:
            logging.warning(f"Low disk space detected ({free_gb:.2f}GB). Running docker prune.")
            subprocess.run(["sudo", "docker", "system", "prune", "-f"],
                           capture_output=True, timeout=120)

        # Run all fix checks
        ipfs_cluster_fixed = check_and_fix_ipfs_cluster()
        ipfs_host_fixed = check_and_fix_ipfs_host()
        config_yaml_fixed = check_and_fix_config_yaml()
        if ipfs_cluster_fixed or ipfs_host_fixed or config_yaml_fixed:
            restart_attempts += 1

    if restart_attempts >= 4:
        logging.error("Maximum restart attempts reached. Checking .reboot_flag status.")
        activate_wireguard_support()
        current_time = time.time()
        
        if os.path.exists(REBOOT_FLAG_PATH):
            file_mod_time = os.path.getmtime(REBOOT_FLAG_PATH)
            time_difference = current_time - file_mod_time
            
            if time_difference < 12 * 60 * 60:  # 12 hours in seconds
                # Issue persists even after reboot within 24 hours
                logging.error("Issue persists after recent reboot. Flashing red for up to ~1 hour then exiting.")
                red_iterations = 0
                while red_iterations < 200:
                    subprocess.run(["sudo", "python", LED_PATH, "red", "15"], capture_output=True, timeout=30)
                    activate_wireguard_support()
                    get_wifi_info_and_ping()
                    time.sleep(5)
                    red_iterations += 1
                logging.error("Red LED loop completed 200 iterations. Exiting to let systemd restart.")
                sys.exit(1)
            else:
                # More than 24 hours have passed, update the reboot flag
                logging.warning("Previous reboot flag is older than 24 hours. Updating and initiating re-partition process.")
                subprocess.run(['sudo', 'rm', REBOOT_FLAG_PATH], timeout=20)
                time.sleep(2)
                subprocess.run(['sudo', 'touch', REBOOT_FLAG_PATH], timeout=20)
                subprocess.run(['sudo', 'touch', COMMAND_PARTITION_PATH], timeout=20)
                subprocess.run(["sudo", "python", LED_PATH, "purple", "5"], capture_output=True, timeout=20)
        else:
            # No existing reboot flag, create it and initiate re-partition process
            logging.warning("No existing reboot flag. Creating flag and initiating re-partition process.")
            subprocess.run(['sudo', 'touch', REBOOT_FLAG_PATH], timeout=20)
            subprocess.run(['sudo', 'touch', COMMAND_PARTITION_PATH], timeout=20)
            subprocess.run(["sudo", "python", LED_PATH, "purple", "5"], capture_output=True, timeout=20)

def main():
    logging.info("readiness check started")
    subprocess.run(["sudo", "python", LED_PATH, "yellow", "-1"], timeout=20)
    subprocess.run(["sudo", "python", LED_PATH, "cyan", "-1"], timeout=20)
    subprocess.run(["sudo", "python", LED_PATH, "blue", "-1"], timeout=20)
    subprocess.run(["sudo", "python", LED_PATH, "green", "2"], capture_output=True, timeout=20)
    fula_restart_attempts = 0
    cycles_with_no_wifi = 0
    while True:
        if check_conditions():
            logging.info("check_conditions passed")
            wifi_status = check_wifi_connection()
            if wifi_status == "FxBlox":
                logging.info("wifi_status FxBlox")
                subprocess.run(["sudo", "python", LED_PATH, "cyan", "2"], capture_output=True, timeout=20)
            elif wifi_status == "other":
                logging.info("wifi_status other")
                subprocess.run(["sudo", "python", LED_PATH, "green", "30"], capture_output=True, timeout=45)
                monitor_docker_logs_and_restart()
            else:
                logging.info("wifi_status not connected")
                if cycles_with_no_wifi == 6:
                    logging.info("wifi not connected, attempting to start FxBlox hotspot")
                    attempt_wifi_connection()
                    cycles_with_no_wifi = 0

                subprocess.run(["sudo", "python", LED_PATH, "red", "10"], capture_output=True, timeout=25)
                cycles_with_no_wifi += 1
                # Activate WireGuard after persistent WiFi failure (12+ cycles = ~2 min)
                if cycles_with_no_wifi >= 12:
                    activate_wireguard_support()
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
                    result = subprocess.run(["sudo", "systemctl", "restart", "fula.service"], capture_output=True, timeout=120)
                    if result.returncode == 0:
                        logging.info("fula.service restarted successfully.")
                        if result.stdout:
                            logging.info(f"Restart output: {result.stdout}")
                    else:
                        logging.error("Failed to restart fula.service.")
                        if result.stderr:
                            logging.error(f"Restart error: {result.stderr}")

                    fula_restart_attempts += 1
            elif fula_restart_attempts >= 4:
                logging.warning("check_conditions failed and max restart attempts reached. Activating WireGuard support.")
                activate_wireguard_support()
            time.sleep(20)

if __name__ == "__main__":
    main()
