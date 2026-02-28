# Diagnostic readiness-check — read-only clone of readiness-check.py
# Runs through the EXACT same control flow but replaces ALL actions with log messages.
# No LEDs, no service restarts, no docker restarts, no file deletions, no reboots.
# while-True loops execute once then exit so this script finishes quickly.
#
# Usage:  sudo python /usr/bin/fula/readiness-check-diag.py

import os
import subprocess
import time
import logging
import sys
import requests
import re
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

# YAML invalid control characters (all control chars except tab, newline, carriage return)
YAML_INVALID_CHARS = set(range(0x00, 0x09)) | {0x0B, 0x0C} | set(range(0x0E, 0x20))

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - DIAG - %(message)s',
    stream=sys.stdout,
)

# Counter for consecutive relay connection failures with broken swarm
relay_fail_count = 0


# ---------------------------------------------------------------------------
# Helper / utility functions (read-only — kept as-is)
# ---------------------------------------------------------------------------

def has_yaml_invalid_chars(content):
    invalid_found = []
    for i, byte in enumerate(content):
        if byte in YAML_INVALID_CHARS:
            invalid_found.append((byte, i))
    return (len(invalid_found) > 0, invalid_found)


def validate_yaml_syntax(file_path):
    try:
        with open(file_path, 'r') as f:
            yaml.safe_load(f)
        return True, None
    except yaml.YAMLError as e:
        return False, str(e)
    except Exception as e:
        return False, str(e)


def check_disk_space(path="/uniondrive", min_gb=1):
    try:
        if not os.path.exists(path):
            logging.warning(f"[check_disk_space] Path does not exist: {path}")
            return True, -1
        stat = os.statvfs(path)
        free_gb = (stat.f_bavail * stat.f_frsize) / (1024**3)
        if free_gb < min_gb:
            logging.warning(f"[check_disk_space] Low disk space on {path}: {free_gb:.2f}GB free (min: {min_gb}GB)")
            return False, free_gb
        logging.info(f"[check_disk_space] Disk space OK on {path}: {free_gb:.2f}GB free")
        return True, free_gb
    except Exception as e:
        logging.error(f"[check_disk_space] Failed: {e}")
        return True, -1


def check_proxy_health():
    import socket
    ports_ok = True
    for port in [4020, 4021]:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=5) as sock:
                pass
            logging.info(f"[check_proxy_health] Port {port} reachable")
        except (ConnectionRefusedError, OSError, socket.timeout):
            logging.warning(f"[check_proxy_health] Port {port} NOT reachable")
            ports_ok = False
    return ports_ok


def check_peerid_collision():
    try:
        kubo_resp = requests.post("http://127.0.0.1:5001/api/v0/id", timeout=10)
        kubo_id = kubo_resp.json().get("ID", "")
        cluster_resp = requests.get("http://127.0.0.1:9094/id", timeout=10)
        cluster_id = cluster_resp.json().get("id", "")
        if kubo_id and cluster_id and kubo_id == cluster_id:
            logging.error(f"[check_peerid_collision] COLLISION: kubo and ipfs-cluster share PeerID {kubo_id}")
            return True
        logging.info(f"[check_peerid_collision] No collision (kubo={kubo_id[:16]}… cluster={cluster_id[:16]}…)")
        return False
    except Exception as e:
        logging.info(f"[check_peerid_collision] Skipped: {e}")
        return False


def check_fs_type(mount_path, expected_type):
    if not os.path.exists(mount_path):
        logging.info(f"[check_fs_type] {mount_path} does not exist")
        return False
    try:
        result = subprocess.run(["findmnt", "-no", "FSTYPE", mount_path], capture_output=True, text=True)
        actual_type = result.stdout.strip()
        match = expected_type in actual_type.split('\n')
        logging.info(f"[check_fs_type] {mount_path} fstype={actual_type!r} expected={expected_type!r} match={match}")
        return match
    except subprocess.CalledProcessError:
        logging.info(f"[check_fs_type] findmnt failed for {mount_path}")
        return False


def check_conditions():
    conds = {}
    conds["partition_flg"] = os.path.exists(os.path.join(FULA_PATH, ".partition_flg"))
    conds["resize_flg"] = os.path.exists(os.path.join(FULA_PATH, ".resize_flg"))
    conds["V6.info"] = os.path.exists(os.path.join(HOME_PATH, "V6.info"))
    docker_ps = subprocess.getoutput("sudo docker ps --format '{{.Names}}'")
    conds["fula_go_running"] = "fula_go" in docker_ps
    conds["uniondrive_exists"] = os.path.exists("/uniondrive")
    conds["uniondrive_fuse"] = check_fs_type("/uniondrive", "fuse.mergerfs")
    conds["docker_active"] = "active" in subprocess.getoutput("sudo systemctl is-active docker.service")
    conds["fula_active"] = "active" in subprocess.getoutput("sudo systemctl is-active fula.service")
    conds["uniondrive_active"] = "active" in subprocess.getoutput("sudo systemctl is-active uniondrive.service")
    for k, v in conds.items():
        logging.info(f"[check_conditions] {k} = {v}")
    result = all(conds.values())
    logging.info(f"[check_conditions] => {result}")
    return result


def check_wifi_connection():
    output = subprocess.getoutput("sudo nmcli con show --active")
    logging.info(f"[check_wifi_connection] Active connections:\n{output}")
    if "FxBlox" in output:
        logging.info("[check_wifi_connection] => FxBlox")
        return "FxBlox"
    elif "wifi" in output or "ethernet" in output:
        logging.info("[check_wifi_connection] => other")
        return "other"
    logging.info("[check_wifi_connection] => None")
    return None


def get_wifi_info_and_ping():
    try:
        nmcli_output = subprocess.check_output(["sudo", "nmcli", "con", "show"], universal_newlines=True)
        wifi_connection = None
        for line in nmcli_output.split('\n'):
            if 'wifi' in line.lower() and 'fxblox' not in line.lower():
                wifi_connection = line.split()[0]
                break
        if not wifi_connection:
            logging.info("[get_wifi_info_and_ping] No non-FxBlox WiFi connection found")
            return
        device_output = subprocess.check_output(["sudo", "nmcli", "con", "show", wifi_connection], universal_newlines=True)
        device_match = re.search(r'GENERAL.DEVICES:\s+(\S+)', device_output)
        if not device_match:
            logging.info(f"[get_wifi_info_and_ping] No device for {wifi_connection}")
            return
        device = device_match.group(1)
        gateway_output = subprocess.check_output(["sudo", "nmcli", "dev", "show", device], universal_newlines=True)
        gateway_match = re.search(r'IP4.GATEWAY:\s+(\S+)', gateway_output)
        if not gateway_match:
            logging.info(f"[get_wifi_info_and_ping] No gateway for {device}")
            return
        gateway_ip = gateway_match.group(1)
        logging.info(f"[get_wifi_info_and_ping] WiFi={wifi_connection} Device={device} Gateway={gateway_ip}")
        logging.info("[get_wifi_info_and_ping] DIAG: skipping actual ping")
    except subprocess.CalledProcessError as e:
        logging.info(f"[get_wifi_info_and_ping] Error: {e}")


def check_internet_connection():
    try:
        requests.head("https://www.google.com", timeout=5)
        logging.info("[check_internet_connection] Internet available")
        return True
    except requests.ConnectionError:
        logging.info("[check_internet_connection] No internet")
        return False


# ---------------------------------------------------------------------------
# DIAGNOSTIC: attempt_wifi_connection  (all actions replaced with logs)
# ---------------------------------------------------------------------------

def attempt_wifi_connection():
    logging.info("[L338] attempt_wifi_connection() called")
    config_yaml_path = os.path.join(HOME_PATH, ".internal", "config.yaml")
    if os.path.exists(config_yaml_path):
        logging.info("[L340] config.yaml EXISTS — would check non-FxBlox WiFi connections")
        logging.info("[L343] WOULD: start_led_flash('yellow')")
        connections_output = subprocess.getoutput("sudo nmcli con show | grep wifi")
        wifi_connections = [line.split()[0] for line in connections_output.split('\n') if "wifi" in line and "FxBlox" not in line]
        logging.info(f"[L345] Non-FxBlox WiFi connections found: {wifi_connections}")

        for wifi_con in wifi_connections:
            logging.info(f"[L351] WOULD: attempt nmcli con up {wifi_con}")
            logging.info(f"[L354] WOULD: check result, try ping, etc.")

        logging.info("[L428] WOULD: if no wifi connected, flash red LED 5s")
    else:
        logging.info("[L437] config.yaml does NOT exist — would flash cyan LED 5s")
    return None


# ---------------------------------------------------------------------------
# DIAGNOSTIC: check_and_fix_ipfs_cluster  (reads logs, logs what fix would run)
# ---------------------------------------------------------------------------

def check_and_fix_ipfs_cluster():
    logging.info("[L443] check_and_fix_ipfs_cluster() called")
    try:
        ipfs_cluster_logs = subprocess.getoutput("sudo docker logs ipfs_cluster --tail 15 2>&1")
        logging.info(f"[L445] ipfs_cluster last 15 lines:\n{ipfs_cluster_logs}")

        if "error creating datastore: failed to open pebble database" in ipfs_cluster_logs or \
           "unknown to the objstorage provider: file does not exist" in ipfs_cluster_logs:
            logging.info("[L448] DETECTED: Pebble database issue")
            logging.info("[L450] WOULD: stop fula.service, sleep 10, rm -rf pebble dir, start fula.service, sleep 30")
            pebble_dir = "/uniondrive/ipfs-cluster/pebble"
            logging.info(f"[L453] pebble_dir exists = {os.path.exists(pebble_dir)}")
            return True
        elif "error obtaining execution lock: cannot acquire lock:" in ipfs_cluster_logs:
            logging.info("[L462] DETECTED: lock issue")
            lock_path = "/uniondrive/ipfs-cluster/cluster.lock"
            logging.info(f"[L466] WOULD: stop fula, rm {lock_path} (exists={os.path.exists(lock_path)}), start fula")
            return True
        elif "status_code=000" in ipfs_cluster_logs and "Request failed, retrying in 60 seconds" in ipfs_cluster_logs:
            logging.info("[L471] DETECTED: status_code=000 issue")
            logging.info("[L473] WOULD: restart fula.service, sleep 30")
            return True
        else:
            logging.info("[L448-475] No ipfs_cluster error patterns matched")

        return False
    except subprocess.CalledProcessError as e:
        logging.error(f"[L488] Error reading ipfs_cluster logs: {e}")
        return False


# ---------------------------------------------------------------------------
# DIAGNOSTIC: check_and_fix_ipfs_host  (reads logs, logs what fix would run)
# ---------------------------------------------------------------------------

def check_and_fix_ipfs_host():
    logging.info("[L493] check_and_fix_ipfs_host() called")
    ipfs_host_logs = subprocess.getoutput("sudo docker logs ipfs_host --tail 17 2>&1")
    logging.info(f"[L494] ipfs_host last 17 lines:\n{ipfs_host_logs}")

    # Check for "error loading plugins"
    if "error loading plugins" in ipfs_host_logs:
        logging.info("[L497] DETECTED: 'error loading plugins'")
        ipfs_config_path = "/home/pi/.internal/ipfs_data/config"
        if os.path.exists(ipfs_config_path):
            try:
                with open(ipfs_config_path, 'rb') as f:
                    content = f.read()
                has_invalid, invalid_chars = has_yaml_invalid_chars(content)
                if has_invalid:
                    char_summary = ", ".join([f"0x{byte:02x} at pos {pos}" for byte, pos in invalid_chars[:5]])
                    logging.info(f"[L512] Invalid chars in ipfs config: {char_summary}")
                    logging.info(f"[L513] WOULD: rm -f {ipfs_config_path}")
                else:
                    logging.info(f"[L502] ipfs config has no invalid chars")
            except Exception as e:
                logging.error(f"[L516] Error reading ipfs config: {e}")

        config_yaml_path = "/home/pi/.internal/config.yaml"
        if os.path.exists(config_yaml_path):
            try:
                with open(config_yaml_path, 'rb') as f:
                    content = f.read()
                has_invalid, invalid_chars = has_yaml_invalid_chars(content)
                if has_invalid:
                    char_summary = ", ".join([f"0x{byte:02x} at pos {pos}" for byte, pos in invalid_chars[:5]])
                    logging.info(f"[L530] Invalid chars in config.yaml: {char_summary}")
                    backup_path = config_yaml_path + ".backup"
                    logging.info(f"[L533] WOULD: try restore from backup (backup exists={os.path.exists(backup_path)})")
                else:
                    is_valid, yaml_error = validate_yaml_syntax(config_yaml_path)
                    if not is_valid:
                        logging.info(f"[L542] YAML syntax error: {yaml_error}")
                        logging.info("[L544] WOULD: try restore from backup or delete")
                    else:
                        logging.info("[L539] config.yaml is valid YAML, no corruption")
            except Exception as e:
                logging.error(f"[L550] Error checking config.yaml: {e}")

        logging.info("[L553] WOULD: restart fula.service, sleep 30")
        return True

    # Check for migration permission error
    if "embedded migration fs-repo-16-to-17 failed: open /internal/ipfs_data/version: permission denied" in ipfs_host_logs:
        logging.info("[L559] DETECTED: migration permission error")
        version_file = "/home/pi/.internal/ipfs_data/version"
        logging.info(f"[L562] WOULD: write '17' to {version_file} (exists={os.path.exists(version_file)})")
        logging.info("[L573] WOULD: restart fula.service, sleep 30")
        return True

    # Check for version mismatch
    version_file_path = "/home/pi/.internal/ipfs_data/version"
    if "Error: Your programs version (17) is lower than your repos" in ipfs_host_logs:
        logging.info("[L581] DETECTED: version mismatch (17 lower)")
        logging.info(f"[L584] WOULD: write '17' to {version_file_path}, restart ipfs_host")
        return True

    if "Error: Your programs version (16) is lower than your repos" in ipfs_host_logs:
        logging.info("[L599] DETECTED: version mismatch (16 lower)")
        logging.info(f"[L602] WOULD: write '16' to {version_file_path}, restart ipfs_host")
        return True

    if "Error: invalid or no prefix in shard identifier:" in ipfs_host_logs or \
       "Error: directory missing SHARDING file:" in ipfs_host_logs or \
       "mkdir /uniondrive/ipfs_datastore/blocks/X3: no such file or directory" in ipfs_host_logs:
        logging.info("[L617] DETECTED: shard/blocks issue")
        ipfs_dir = "/uniondrive/ipfs_datastore/blocks"
        logging.info(f"[L621] WOULD: stop fula, rm -rf {ipfs_dir} (exists={os.path.exists(ipfs_dir)}), start fula")
        return True

    if "could not get pinset from IPFS: Post" in ipfs_host_logs and "context deadline exceeded" in ipfs_host_logs:
        logging.info("[L631] DETECTED: pinset context deadline exceeded")
        logging.info("[L633] WOULD: docker restart ipfs_host")
        return True

    if "failed to open pebble database: pebble: database" in ipfs_host_logs:
        logging.info("[L636] DETECTED: pebble database error")
        ipfs_dir = "/uniondrive/ipfs_datastore/blocks"
        ipfs_ds_dir = "/uniondrive/ipfs_datastore/datastore"
        logging.info(f"[L641] WOULD: stop ipfs_host, rm -rf blocks (exists={os.path.exists(ipfs_dir)}), rm -rf datastore (exists={os.path.exists(ipfs_ds_dir)}), start fula")
        return True

    logging.info("[L660] No ipfs_host error patterns matched — checking relay connectivity")

    # Relay connection check (read-only network probes kept)
    global relay_fail_count

    if not check_internet_connection():
        logging.info("[L663] No internet — skipping relay check")
        return False

    try:
        requests.post(IPFS_API_URL + "/api/v0/id", timeout=10)
    except Exception:
        logging.info("[L669] IPFS API not responding — skipping relay check")
        return False

    config_yaml_path = os.path.join(HOME_PATH, ".internal", "config.yaml")
    if not os.path.exists(config_yaml_path):
        logging.info("[L674] config.yaml missing — skipping relay check (device not configured)")
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
            logging.info("[L686] Relay connection successful")
            relay_fail_count = 0
            return False

        logging.warning(f"[L691] Relay connection failed: {relay_strings}")
    except Exception as e:
        logging.warning(f"[L693] Relay connection attempt failed: {e}")

    # Check bootstrap peers (read-only)
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
        logging.info(f"[L711] Relay unreachable but swarm healthy ({bootstrap_successes}/{len(BOOTSTRAP_PEERS)} bootstrap OK)")
        relay_fail_count = 0
        return False

    relay_fail_count += 1
    if relay_fail_count >= 5:
        logging.info(f"[L721] Relay+swarm failed {relay_fail_count}x => WOULD restart fula.service")
        relay_fail_count = 0
        return True

    logging.info(f"[L731] Relay+swarm failed ({relay_fail_count}/5) — would retry next cycle")
    return False


# ---------------------------------------------------------------------------
# DIAGNOSTIC: check_and_fix_config_yaml  (reads logs, logs what fix would run)
# ---------------------------------------------------------------------------

def check_and_fix_config_yaml():
    logging.info("[L738] check_and_fix_config_yaml() called")
    try:
        fula_go_logs = subprocess.getoutput("sudo docker logs fula_go --tail 50 2>&1")
        logging.info(f"[L755] fula_go last 50 lines:\n{fula_go_logs}")

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
            logging.info("[L778] No config YAML error patterns matched in fula_go logs")
            return False

        logging.info(f"[L781] DETECTED config error: '{matched_pattern}'")

        config_yaml_path = "/home/pi/.internal/config.yaml"
        if not os.path.exists(config_yaml_path):
            logging.info(f"[L785] Config file does not exist: {config_yaml_path}")
            logging.info("[L789] WOULD: restart fula.service to regenerate config")
            return True

        # Check for invalid control characters (read-only)
        try:
            with open(config_yaml_path, 'rb') as f:
                content = f.read()
            has_invalid, invalid_chars = has_yaml_invalid_chars(content)
            if has_invalid:
                char_summary = ", ".join([f"0x{byte:02x} at pos {pos}" for byte, pos in invalid_chars[:5]])
                if len(invalid_chars) > 5:
                    char_summary += f" ... and {len(invalid_chars) - 5} more"
                logging.info(f"[L805] Invalid control chars in config.yaml: {char_summary}")
                backup_path = config_yaml_path + ".backup"
                backup_exists = os.path.exists(backup_path)
                backup_valid = False
                if backup_exists:
                    backup_valid, _ = validate_yaml_syntax(backup_path)
                logging.info(f"[L808] WOULD: restore from backup (exists={backup_exists}, valid={backup_valid}) or delete, then restart fula")
                return True
        except Exception as e:
            logging.error(f"[L826] Error checking config.yaml: {e}")

        is_valid, yaml_error = validate_yaml_syntax(config_yaml_path)
        if not is_valid:
            logging.info(f"[L831] YAML syntax error: {yaml_error}")
            backup_path = config_yaml_path + ".backup"
            backup_exists = os.path.exists(backup_path)
            backup_valid = False
            if backup_exists:
                backup_valid, _ = validate_yaml_syntax(backup_path)
            logging.info(f"[L834] WOULD: restore from backup (exists={backup_exists}, valid={backup_valid}) or delete, then restart fula")
            return True

        logging.info("[L852] Config appears valid but error was detected — WOULD restart fula.service")
        return True

    except subprocess.CalledProcessError as e:
        logging.error(f"[L857] CalledProcessError: {e}")
        return False
    except Exception as e:
        logging.error(f"[L861] Unexpected error: {e}")
        return False


# ---------------------------------------------------------------------------
# DIAGNOSTIC: check_external_drive  (read-only — checks blkid/lsblk, logs actions)
# ---------------------------------------------------------------------------

def check_external_drive():
    logging.info("[L900] check_external_drive() called")
    try:
        blkid_output = subprocess.check_output(["sudo", "blkid"], universal_newlines=True)
        drives = [line.split(':') for line in blkid_output.splitlines() if line.startswith('/dev/sd') or line.startswith('/dev/nvme')]
        logging.info(f"[L904] Found drives: {[d[0] for d in drives]}")

        for drive_info in drives:
            drive = drive_info[0]
            fstype = next((item.split('=')[1].strip('"') for item in drive_info[1].split() if item.startswith('TYPE=')), None)
            size_output = subprocess.check_output(["sudo", "lsblk", "-b", "-n", "-o", "SIZE", drive], universal_newlines=True)
            disk_size = int(size_output.split()[0])
            disk_size_gb = disk_size / (1024 ** 3)
            logging.info(f"[L908] Drive {drive}: fstype={fstype} size={disk_size_gb:.1f}GB")

            if fstype and (fstype.lower() != 'ext4') and (disk_size_gb > 500):
                logging.info(f"[L915] DETECTED: {drive} is {fstype} > 500GB — WOULD format to ext4")
                logging.info("[L919] WOULD: stop fula, stop uniondrive, stop automount, umount, rm -rf, format, reboot")
                return True

        logging.info("[L948] No drives needing format correction")
        return False
    except subprocess.CalledProcessError as e:
        logging.error(f"[L952] Error: {e}")
        return False
    except Exception as e:
        logging.error(f"[L955] Unexpected error: {e}")
        return False


# ---------------------------------------------------------------------------
# DIAGNOSTIC: activate_wireguard_support  (read-only check, log action)
# ---------------------------------------------------------------------------

def activate_wireguard_support():
    logging.info("[L958] activate_wireguard_support() called")
    service_file = "/etc/systemd/system/wireguard-support.service"
    if not os.path.exists(service_file):
        logging.info(f"[L962] wireguard-support.service not installed (file missing)")
        return
    try:
        result = subprocess.run(
            ["systemctl", "is-active", "wireguard-support.service"],
            capture_output=True, text=True, timeout=10
        )
        if result.stdout.strip() == "active":
            logging.info("[L970] WireGuard support tunnel already active")
            return
        logging.info("[L974] WOULD: systemctl start wireguard-support.service")
    except Exception as e:
        logging.error(f"[L981] Error: {e}")


# ---------------------------------------------------------------------------
# DIAGNOSTIC: check_wireguard_health  (read-only check, log action)
# ---------------------------------------------------------------------------

def check_wireguard_health():
    logging.info("[L984] check_wireguard_health() called")
    install_script = "/usr/bin/fula/wireguard/install.sh"
    if not os.path.exists(install_script):
        logging.info("[L988] wireguard install.sh not found — skipping")
        return
    wg_exists = subprocess.run(["which", "wg"], capture_output=True, timeout=5).returncode == 0
    keys_exist = os.path.exists("/etc/wireguard/support_private.key")
    service_exists = os.path.exists("/etc/systemd/system/wireguard-support.service")
    logging.info(f"[L992] wg_exists={wg_exists} keys_exist={keys_exist} service_exists={service_exists}")
    if wg_exists and keys_exist and service_exists:
        logging.info("[L998] WireGuard installation complete — no action needed")
        return
    logging.info("[L1001] WOULD: run install.sh to complete WireGuard installation")


# ---------------------------------------------------------------------------
# DIAGNOSTIC: backup_config_if_valid  (read-only validation, log action)
# ---------------------------------------------------------------------------

def backup_config_if_valid(config_path):
    backup_path = config_path + ".backup"
    try:
        is_valid, err = validate_yaml_syntax(config_path)
        if is_valid:
            logging.info(f"[L97] WOULD: create backup {backup_path}")
            return True
        else:
            logging.info(f"[L101] Config not valid, would skip backup: {err}")
            return False
    except Exception as e:
        logging.error(f"[L104] Error: {e}")
        return False


# ---------------------------------------------------------------------------
# DIAGNOSTIC: monitor_docker_logs_and_restart  (main monitoring loop)
# ---------------------------------------------------------------------------

def monitor_docker_logs_and_restart():
    logging.info("[L1010] monitor_docker_logs_and_restart() called")

    if not check_internet_connection():
        logging.info("[L1012] No internet — WOULD flash yellow LED 5s, sleep 120s")
        logging.info("[L1014] [sleep 120s skipped]")
        return

    containers_to_check = ["fula_go", "ipfs_host", "ipfs_cluster"]
    # Only monitor fula_pinning if its container has been created at least once.
    # Avoids restart loops on devices that got this script before the image was pulled.
    if "fula_pinning" in subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'"):
        containers_to_check.append("fula_pinning")
    # Only monitor fula_gateway if its container has been created at least once.
    if "fula_gateway" in subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'"):
        containers_to_check.append("fula_gateway")
    restart_attempts = 0
    if check_external_drive():
        logging.info("[L1020] External drive needs reformatting — skip to partition section (restart_attempts=4)")
        restart_attempts = 4

    # DIAG: cap at 1 iteration to avoid long waits
    diag_iteration = 0
    while restart_attempts < 4:
        diag_iteration += 1
        if diag_iteration > 1:
            logging.info(f"[L1023] DIAG: capping monitor loop at 1 iteration (would continue, restart_attempts={restart_attempts})")
            break

        logging.info(f"[L1023] monitor loop iteration {diag_iteration}, restart_attempts={restart_attempts}")
        logging.info("[L1025] [sleep 450s skipped]")
        get_wifi_info_and_ping()

        docker_service_status = subprocess.getoutput("sudo systemctl is-active docker.service")
        logging.info(f"[L1028] docker.service status: {docker_service_status}")

        if not check_conditions():
            logging.info("[L1029] check_conditions FAILED inside monitor")
            logging.info("[L1031] WOULD: flash yellow, stop fula, stop docker, sleep 15, restart uniondrive, sleep 15, start docker, sleep 20, start fula, sleep 35")
            restart_attempts += 1
            logging.info(f"[L1043] restart_attempts now {restart_attempts}")
            continue
        else:
            logging.info("[L1046] check_conditions passed inside monitor")

        if "active" not in docker_service_status:
            logging.info("[L1048] Docker NOT active — WOULD: restart docker + fula (loop until active or attempts exhausted)")
            restart_attempts += 1
            logging.info(f"[L1056] restart_attempts now {restart_attempts}")
        else:
            logging.info("[L1048] Docker is active")

        all_containers_running = True
        for container in containers_to_check:
            docker_ps = subprocess.getoutput("sudo docker ps --format '{{.Names}}'")
            container_running = container in docker_ps
            if container_running:
                logging.info(f"[L1062] {container} is running")
                logs = subprocess.getoutput(f"sudo docker logs --tail 15 {container} 2>&1")
                if "ERROR:" in logs:
                    logging.info(f"[L1065] {container} logs contain ERROR:")
                    container_running = False
                else:
                    logging.info(f"[L1069] {container} logs clean")
            if not container_running:
                all_containers_running = False
                logging.info(f"[L1072] {container} NOT running or has errors — WOULD restart fula.service")
                break

        if all_containers_running:
            logging.info("[L1087] All containers running — checking proxy health")
            if not check_proxy_health():
                logging.info("[L1090] Proxy unhealthy — WOULD restart fula.service")
                restart_attempts += 1
                continue

            if check_peerid_collision():
                service_json = "/uniondrive/ipfs-cluster/service.json"
                logging.info(f"[L1099] PeerID collision — WOULD: rm {service_json} (exists={os.path.exists(service_json)}), restart fula")
                restart_attempts += 1
                continue

            logging.info("[L1109] All healthy — WOULD: flash green LED, restart_attempts=0")
            logging.info("[L1113] WOULD: check_wireguard_health()")
            check_wireguard_health()

            config_yaml_path = "/home/pi/.internal/config.yaml"
            if os.path.exists(config_yaml_path):
                backup_config_if_valid(config_yaml_path)
        else:
            restart_attempts += 1
            logging.info(f"[L1120] restart_attempts now {restart_attempts}")

        has_space, free_gb = check_disk_space("/uniondrive", min_gb=1)
        if not has_space:
            logging.info(f"[L1125] Low disk ({free_gb:.2f}GB) — WOULD: docker system prune -f")

        ipfs_cluster_fixed = check_and_fix_ipfs_cluster()
        ipfs_host_fixed = check_and_fix_ipfs_host()
        config_yaml_fixed = check_and_fix_config_yaml()
        logging.info(f"[L1133] Fix results: cluster={ipfs_cluster_fixed} host={ipfs_host_fixed} config={config_yaml_fixed}")
        if ipfs_cluster_fixed or ipfs_host_fixed or config_yaml_fixed:
            restart_attempts += 1
            logging.info(f"[L1134] restart_attempts now {restart_attempts}")

    # --- After the while loop (restart_attempts >= 4 path) ---
    if restart_attempts >= 4:
        logging.info(f"[L1136] *** MAX RESTART ATTEMPTS REACHED (restart_attempts={restart_attempts}) ***")
        logging.info("[L1138] WOULD: activate_wireguard_support()")
        activate_wireguard_support()
        current_time = time.time()

        if os.path.exists(REBOOT_FLAG_PATH):
            file_mod_time = os.path.getmtime(REBOOT_FLAG_PATH)
            time_difference = current_time - file_mod_time
            hours_ago = time_difference / 3600
            logging.info(f"[L1141] .reboot_flag EXISTS, age = {hours_ago:.2f} hours ({time_difference:.0f}s)")

            if time_difference < 12 * 60 * 60:
                logging.info("=" * 70)
                logging.info("[L1148] *** REBOOT_FLAG < 12h: THIS IS THE INFINITE RED LED LOOP ***")
                logging.info("[L1148] while True: flash red 15s, activate_wireguard, wifi_ping, sleep 5")
                logging.info("[L1148] DIAG: executing ONCE then exiting (normally this loops forever)")
                logging.info("=" * 70)
                logging.info("[L1149] WOULD: flash red LED 15s")
                activate_wireguard_support()
                get_wifi_info_and_ping()
                logging.info("[L1152] [sleep 5s skipped]")
                logging.info("[L1148] DIAG: breaking out of infinite loop after 1 pass")
            else:
                logging.info(f"[L1153] .reboot_flag > 12h — WOULD: rm + touch reboot_flag, touch command_partition, flash purple 5s")
                logging.info(f"[L1156] WOULD: rm {REBOOT_FLAG_PATH}")
                logging.info(f"[L1158] WOULD: touch {REBOOT_FLAG_PATH}")
                logging.info(f"[L1159] WOULD: touch {COMMAND_PARTITION_PATH}")
        else:
            logging.info("[L1161] .reboot_flag does NOT exist")
            logging.info(f"[L1164] WOULD: touch {REBOOT_FLAG_PATH}")
            logging.info(f"[L1165] WOULD: touch {COMMAND_PARTITION_PATH}")
            logging.info("[L1166] WOULD: flash purple LED 5s")
    else:
        logging.info(f"[L1136] Monitor loop exited with restart_attempts={restart_attempts} (< 4)")


# ---------------------------------------------------------------------------
# DIAGNOSTIC: main  (main loop runs ONCE then exits)
# ---------------------------------------------------------------------------

def main():
    logging.info("=" * 70)
    logging.info("DIAGNOSTIC readiness-check — read-only, single-pass")
    logging.info("=" * 70)

    logging.info("[L1169] readiness check started")
    logging.info("[L1170] WOULD: LED yellow -1 (off)")
    logging.info("[L1171] WOULD: LED cyan -1 (off)")
    logging.info("[L1172] WOULD: LED blue -1 (off)")
    logging.info("[L1173] WOULD: LED green 2s")

    fula_restart_attempts = 0
    cycles_with_no_wifi = 0

    # DIAG: main while-True runs ONCE
    logging.info("[L1176] Entering main while-True loop (DIAG: single pass)")

    if check_conditions():
        logging.info("[L1177] check_conditions PASSED")
        wifi_status = check_wifi_connection()
        if wifi_status == "FxBlox":
            logging.info("[L1180] wifi_status = FxBlox")
            logging.info("[L1182] WOULD: LED cyan 2s")
        elif wifi_status == "other":
            logging.info("[L1183] wifi_status = other")
            logging.info("[L1185] WOULD: LED green 30s")
            logging.info("[L1186] Calling monitor_docker_logs_and_restart()")
            monitor_docker_logs_and_restart()
        else:
            logging.info("[L1187] wifi_status = None (not connected)")
            logging.info(f"[L1189] cycles_with_no_wifi = {cycles_with_no_wifi}")
            if cycles_with_no_wifi == 6:
                logging.info("[L1190] cycles_with_no_wifi == 6 — would call attempt_wifi_connection()")
                attempt_wifi_connection()
                cycles_with_no_wifi = 0
            logging.info("[L1194] WOULD: LED red 10s")
            cycles_with_no_wifi += 1
            if cycles_with_no_wifi >= 12:
                logging.info("[L1197] cycles_with_no_wifi >= 12 — would activate_wireguard_support()")
                activate_wireguard_support()
            logging.info("[L1199] [sleep 10s skipped]")
    else:
        logging.info("[L1200] check_conditions FAILED")
        docker_ps_a_output = subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'")
        docker_ps_output = subprocess.getoutput("sudo docker ps --format '{{.Names}}'")
        logging.info(f"[L1203] docker ps -a names: {docker_ps_a_output}")
        logging.info(f"[L1204] docker ps names: {docker_ps_output}")

        fula_go_in_ps_a = "fula_go" in docker_ps_a_output
        support_running = all(c in docker_ps_output for c in ["fula_fxsupport", "fula_updater"])
        logging.info(f"[L1206] fula_go in ps -a = {fula_go_in_ps_a}, fxsupport+updater running = {support_running}, fula_restart_attempts = {fula_restart_attempts}")

        if fula_go_in_ps_a and support_running and fula_restart_attempts < 4:
            logging.info("[L1209] WOULD: restart fula.service")
            fula_restart_attempts += 1
            logging.info(f"[L1220] fula_restart_attempts now {fula_restart_attempts}")
        elif fula_restart_attempts >= 4:
            logging.info("[L1221] fula_restart_attempts >= 4 — WOULD: activate WireGuard support")
            activate_wireguard_support()
        else:
            logging.info("[L1206] Conditions not met for fula restart (fula_go missing or support containers not running)")
        logging.info("[L1224] [sleep 20s skipped]")

    logging.info("=" * 70)
    logging.info("DIAGNOSTIC complete — single pass finished")
    logging.info("=" * 70)


if __name__ == "__main__":
    main()
