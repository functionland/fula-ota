# Watcher for Fula tower v1.2
import os
import subprocess
import time
import logging
import sys
import json
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
IPFS_LOCAL_API_URL = "http://127.0.0.1:5002"
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

# ext4 filesystem repair state
last_fsck_time = 0   # Timestamp of last e2fsck run — 1-hour cooldown
FSCK_COOLDOWN = 3600
FSCK_LOCKFILE = "/run/fula-fsck.lock"

# YAML invalid control characters (all control chars except tab, newline, carriage return)
YAML_INVALID_CHARS = set(range(0x00, 0x09)) | {0x0B, 0x0C} | set(range(0x0E, 0x20))


def safe_restart_fula(**kwargs):
    """Restart fula.service, clearing any start-limit failures first."""
    subprocess.run(["sudo", "systemctl", "reset-failed", "fula.service"],
                   capture_output=True, timeout=20)
    return subprocess.run(["sudo", "systemctl", "restart", "fula.service"], **kwargs)

def safe_start_fula(**kwargs):
    """Start fula.service, clearing any start-limit failures first."""
    subprocess.run(["sudo", "systemctl", "reset-failed", "fula.service"],
                   capture_output=True, timeout=20)
    return subprocess.run(["sudo", "systemctl", "start", "fula.service"], **kwargs)


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


def strip_deprecated_provider_fields(config_path):
    """Remove deprecated Provider/Reprovider fields from a kubo config JSON file.

    kubo 0.40+ emits a FATAL and refuses to start if the deprecated Provider
    field exists.  This reads the config via sudo, strips the offending keys,
    and writes it back (preserving ipfs user ownership).

    Args:
        config_path: Absolute path to the kubo config JSON file.

    Returns:
        True if fields were removed, False if nothing changed or on error.
    """
    try:
        result = subprocess.run(
            ["sudo", "cat", config_path],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return False
        config = json.loads(result.stdout)
        changed = False
        for key in ("Provider", "Reprovider"):
            if key in config:
                del config[key]
                changed = True
        if changed:
            new_content = json.dumps(config, indent=2) + "\n"
            subprocess.run(
                ["sudo", "tee", config_path],
                input=new_content.encode(), capture_output=True, timeout=10
            )
            subprocess.run(
                ["sudo", "chown", "1000:1000", config_path],
                capture_output=True, timeout=10
            )
            logging.info(f"Stripped deprecated Provider/Reprovider fields from {config_path}")
        return changed
    except Exception as e:
        logging.error(f"Error stripping Provider fields from {config_path}: {e}")
        return False


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


def _acquire_fsck_lock():
    """Acquire PID-based lockfile for fsck. Returns True if acquired."""
    if os.path.exists(FSCK_LOCKFILE):
        try:
            with open(FSCK_LOCKFILE, 'r') as f:
                old_pid = int(f.read().strip())
            os.kill(old_pid, 0)  # Check if alive
            logging.info(f"fsck lock held by PID {old_pid}, skipping")
            return False
        except (ValueError, ProcessLookupError, OSError):
            logging.info("Removing stale fsck lockfile")
            os.remove(FSCK_LOCKFILE)
    with open(FSCK_LOCKFILE, 'w') as f:
        f.write(str(os.getpid()))
    return True


def _release_fsck_lock():
    """Release fsck lockfile."""
    try:
        os.remove(FSCK_LOCKFILE)
    except OSError:
        pass


def _find_ro_ext4_partitions():
    """Find ext4 partitions under /media/pi/ that are mounted read-only or have errors.

    Returns list of (device, mountpoint) tuples needing repair.
    """
    results = []
    seen_devices = set()

    # Primary: check /proc/mounts for ext4 partitions mounted read-only
    try:
        with open('/proc/mounts', 'r') as f:
            for line in f:
                parts = line.split()
                if len(parts) < 4:
                    continue
                device, mountpoint, fstype, options = parts[0], parts[1], parts[2], parts[3]
                if fstype != 'ext4' or not mountpoint.startswith('/media/pi/'):
                    continue
                mount_opts = options.split(',')
                if 'ro' in mount_opts:
                    logging.warning(f"ext4 partition {device} at {mountpoint} is mounted read-only")
                    results.append((device, mountpoint))
                    seen_devices.add(device)
    except Exception as e:
        logging.error(f"Error reading /proc/mounts: {e}")

    # Secondary: check /sys/fs/ext4/*/errors_count for drives with errors=continue
    try:
        ext4_sys = '/sys/fs/ext4'
        if os.path.isdir(ext4_sys):
            for dev_name in os.listdir(ext4_sys):
                errors_path = os.path.join(ext4_sys, dev_name, 'errors_count')
                if not os.path.exists(errors_path):
                    continue
                try:
                    with open(errors_path, 'r') as f:
                        errors_count = int(f.read().strip())
                except (ValueError, IOError):
                    continue
                if errors_count <= 0:
                    continue
                # Resolve the device path
                device = f'/dev/{dev_name}'
                if device in seen_devices:
                    continue
                # Find its mountpoint from /proc/mounts
                try:
                    with open('/proc/mounts', 'r') as f:
                        for line in f:
                            parts = line.split()
                            if len(parts) >= 2 and parts[0] == device and parts[1].startswith('/media/pi/'):
                                logging.warning(f"ext4 partition {device} has {errors_count} errors (errors=continue)")
                                results.append((device, parts[1]))
                                seen_devices.add(device)
                                break
                except Exception:
                    pass
    except Exception as e:
        logging.error(f"Error checking ext4 errors_count: {e}")

    return results


def _detect_io_dead_drive():
    """Detect external drives stuck in I/O errors with D-state (uninterruptible sleep) processes.

    This catches drives too broken to mount — _find_ro_ext4_partitions() misses them.
    Requires BOTH D-state processes targeting /dev/sd* AND I/O errors in dmesg to avoid
    false positives (a brief D-state during normal I/O is not a problem).

    Returns (device_path, partition_name, disk_name) or (None, None, None).
    """
    try:
        # Find D-state processes targeting /dev/sd*
        ps_result = subprocess.run(
            ["ps", "-eo", "state,args", "--no-headers"],
            capture_output=True, text=True, timeout=10
        )
        d_state_devices = set()
        for line in ps_result.stdout.strip().split('\n'):
            if not line:
                continue
            parts = line.split(None, 1)
            if len(parts) < 2:
                continue
            state, args = parts[0], parts[1]
            if 'D' not in state:
                continue
            for token in args.split():
                if re.match(r'/dev/sd[a-z]+\d*$', token):
                    d_state_devices.add(token)

        if not d_state_devices:
            return None, None, None

        device = sorted(d_state_devices)[0]
        disk_match = re.match(r'/dev/(sd[a-z]+)(\d*)$', device)
        if not disk_match:
            return None, None, None
        disk_name = disk_match.group(1)
        part_num = disk_match.group(2) or '1'
        partition_name = f"{disk_name}{part_num}"

        # Require I/O errors in dmesg to avoid false positives
        try:
            dmesg_result = subprocess.run(
                ["dmesg"], capture_output=True, text=True, timeout=10
            )
            recent_lines = dmesg_result.stdout.strip().split('\n')[-200:]
            has_io_errors = any(
                f'I/O error, dev {disk_name}' in line or
                f'[{disk_name}] timing out' in line
                for line in recent_lines
            )
            if not has_io_errors:
                logging.debug(f"D-state on {device} but no I/O errors in dmesg — not I/O dead")
                return None, None, None
        except Exception:
            pass  # If dmesg fails, trust D-state alone (conservative)

        logging.warning(f"I/O dead drive detected: /dev/{partition_name} (D-state + I/O errors)")
        return f"/dev/{partition_name}", partition_name, disk_name

    except Exception as e:
        logging.error(f"Error detecting I/O dead drive: {e}")
        return None, None, None


def _reset_scsi_drive(disk_name, timeout=90):
    """Reset a SCSI/USB drive via sysfs delete + host rescan.

    Clears D-state processes by removing the block device from the kernel, then
    rescans SCSI hosts to re-detect it. Waits for spinup and partition table.

    Args:
        disk_name: Base disk name, e.g. 'sda'
        timeout: Max seconds to wait for drive to come back

    Returns True if drive came back with a partition, False otherwise.
    """
    delete_path = f'/sys/block/{disk_name}/device/delete'

    if not os.path.exists(delete_path):
        logging.error(f"SCSI delete path not found: {delete_path}")
        return False

    # Delete the device — clears D-state processes waiting on it
    logging.info(f"SCSI reset: deleting {disk_name} via sysfs")
    try:
        subprocess.run(
            ["sudo", "tee", delete_path],
            input=b"1", capture_output=True, timeout=30
        )
    except subprocess.TimeoutExpired:
        logging.error(f"SCSI delete timed out for {disk_name}")
        return False

    # Wait for D-state processes to clear
    time.sleep(10)

    # Rescan all SCSI hosts to re-detect the drive
    logging.info("SCSI reset: rescanning all SCSI hosts")
    try:
        scsi_host_dir = '/sys/class/scsi_host'
        if os.path.isdir(scsi_host_dir):
            for host in os.listdir(scsi_host_dir):
                scan_path = os.path.join(scsi_host_dir, host, 'scan')
                if os.path.exists(scan_path):
                    try:
                        subprocess.run(
                            ["sudo", "tee", scan_path],
                            input=b"- - -", capture_output=True, timeout=10
                        )
                    except Exception:
                        pass
    except Exception as e:
        logging.error(f"SCSI host rescan failed: {e}")
        return False

    # Wait for drive to spin up and partition to appear
    logging.info(f"SCSI reset: waiting up to {timeout}s for {disk_name} to come back")
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(5)

        if not os.path.exists(f'/sys/block/{disk_name}'):
            continue

        # Check size > 0 (0 means still spinning up)
        try:
            with open(f'/sys/block/{disk_name}/size', 'r') as f:
                size = int(f.read().strip())
            if size == 0:
                logging.debug(f"SCSI reset: {disk_name} back but size=0, still spinning up")
                continue
        except (ValueError, IOError):
            continue

        # Check for partition
        if os.path.exists(f'/sys/block/{disk_name}/{disk_name}1'):
            logging.info(f"SCSI reset: {disk_name}1 is back")
            return True

        # Drive back but no partition — try partprobe
        logging.info(f"SCSI reset: {disk_name} back but no partition, running partprobe")
        try:
            subprocess.run(
                ["sudo", "partprobe", f"/dev/{disk_name}"],
                capture_output=True, timeout=15
            )
        except Exception:
            pass
        time.sleep(3)

        if os.path.exists(f'/sys/block/{disk_name}/{disk_name}1'):
            logging.info(f"SCSI reset: {disk_name}1 found after partprobe")
            return True

    logging.error(f"SCSI reset: {disk_name} did not come back within {timeout}s")
    return False


def check_and_repair_ext4():
    """Detect and repair ext4 filesystem corruption (read-only remount or error count).

    Stops services, unmounts, runs e2fsck, restarts services.
    Uses lockfile and cooldown to prevent races and rapid re-runs.

    Returns True if repair was attempted, False if skipped.
    """
    global last_fsck_time

    # Check cooldown
    now = time.time()
    if now - last_fsck_time < FSCK_COOLDOWN:
        logging.info("ext4 fsck cooldown active, skipping")
        return False

    # Detect issues — RO mount first, then I/O dead drive
    ro_partitions = _find_ro_ext4_partitions()
    io_dead = False

    if ro_partitions:
        device, mountpoint = ro_partitions[0]
        partition_name = device.split('/')[-1]
    else:
        dead_device, dead_part, dead_disk = _detect_io_dead_drive()
        if dead_device is None:
            return False
        device, partition_name = dead_device, dead_part
        mountpoint = f"/media/pi/{partition_name}"
        io_dead = True

    # Extract base disk name (sda from sda1) for SCSI reset
    disk_match = re.match(r'(sd[a-z]+)', partition_name)
    disk_name = disk_match.group(1) if disk_match else None

    # Check if e2fsck is already running
    try:
        pgrep = subprocess.run(["pgrep", "-x", "e2fsck"], capture_output=True, timeout=10)
        if pgrep.returncode == 0:
            logging.info("e2fsck already running, skipping")
            return False
    except Exception:
        pass

    # Acquire lock
    if not _acquire_fsck_lock():
        return False

    logging.warning(f"Starting ext4 repair for {device} at {mountpoint}"
                    f"{' (I/O dead — SCSI reset needed)' if io_dead else ''}")

    repair_attempted = False
    try:
        # Orange LED to indicate repair in progress
        subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"], capture_output=True, timeout=20)

        # Stop fula first (explicit, even though uniondrive stop cascades via Requires)
        logging.info("Stopping fula.service for ext4 repair")
        subprocess.run(["sudo", "systemctl", "stop", "fula.service"],
                       capture_output=True, timeout=120)
        time.sleep(5)

        # Stop Docker — containers hold file handles on SSD paths through mergerfs
        logging.info("Stopping docker.service for ext4 repair")
        subprocess.run(["sudo", "systemctl", "stop", "docker.service"],
                       capture_output=True, timeout=120)
        time.sleep(5)

        # Stop uniondrive (kills union-drive.sh, cascade-stops fula via Requires)
        logging.info("Stopping uniondrive.service for ext4 repair")
        subprocess.run(["sudo", "systemctl", "stop", "uniondrive.service"],
                       capture_output=True, timeout=120)
        time.sleep(5)

        # Stop automount for this partition
        automount_unit = f"automount@{partition_name}.service"
        logging.info(f"Stopping {automount_unit} for ext4 repair")
        subprocess.run(["sudo", "systemctl", "stop", automount_unit],
                       capture_output=True, timeout=120)
        time.sleep(2)

        # --- Make the device available for fsck ---
        device_ready = False

        if io_dead and disk_name:
            # Drive is I/O dead — umount/fuser would hang. SCSI reset first.
            logging.warning(f"Drive I/O dead, performing SCSI reset on {disk_name}")
            if _reset_scsi_drive(disk_name):
                device = f"/dev/{partition_name}"
                device_ready = True
            else:
                logging.error("SCSI reset failed — drive may need physical intervention")
        else:
            # Normal path: unmount, then release block device holders
            # Verify partition is unmounted; force-unmount if needed
            mounted = subprocess.run(["mountpoint", "-q", mountpoint],
                                     capture_output=True, timeout=10).returncode == 0
            if mounted:
                logging.info(f"Unmounting {device} from {mountpoint}")
                result = subprocess.run(["sudo", "umount", device],
                                        capture_output=True, timeout=30)
                if result.returncode != 0:
                    logging.warning(f"umount failed, trying lazy unmount: {result.stderr}")
                    result = subprocess.run(["sudo", "umount", "-l", device],
                                            capture_output=True, timeout=10)
                    if result.returncode != 0:
                        logging.warning("Lazy umount failed, killing users and retrying")
                        subprocess.run(["sudo", "fuser", "-km", mountpoint],
                                       capture_output=True, timeout=30)
                        time.sleep(2)
                        subprocess.run(["sudo", "umount", device],
                                       capture_output=True, timeout=30)

                # Final mount check
                still_mounted = subprocess.run(["mountpoint", "-q", mountpoint],
                                               capture_output=True, timeout=10).returncode == 0
                if still_mounted:
                    logging.error(f"Cannot unmount {device} — trying SCSI reset as fallback")
                    if disk_name and _reset_scsi_drive(disk_name):
                        device = f"/dev/{partition_name}"
                        device_ready = True
                    # If SCSI reset also failed, fall through — device_ready stays False

            if not device_ready:
                # Kill processes holding the block device (stale blkid, etc.)
                try:
                    fuser_result = subprocess.run(
                        ["sudo", "fuser", "-v", device],
                        capture_output=True, text=True, timeout=10
                    )
                    if fuser_result.returncode == 0:
                        logging.warning(f"Processes holding {device} open:\n"
                                        f"{fuser_result.stdout}{fuser_result.stderr}")
                        subprocess.run(["sudo", "fuser", "-k", device],
                                       capture_output=True, timeout=15)
                        time.sleep(2)
                        # Verify released
                        recheck = subprocess.run(
                            ["sudo", "fuser", device],
                            capture_output=True, timeout=10
                        )
                        if recheck.returncode == 0:
                            # fuser -k failed — processes likely in D-state. Try SCSI reset.
                            logging.warning("fuser -k failed (D-state?), trying SCSI reset")
                            if disk_name and _reset_scsi_drive(disk_name):
                                device = f"/dev/{partition_name}"
                                device_ready = True
                            else:
                                logging.error(f"Cannot release {device} — all methods exhausted")
                        else:
                            logging.info(f"Released all processes holding {device}")
                            device_ready = True
                    else:
                        device_ready = True  # Nothing holding it — good to go
                except subprocess.TimeoutExpired:
                    # fuser itself hung — drive is likely I/O dead
                    logging.warning(f"fuser on {device} timed out — trying SCSI reset")
                    if disk_name and _reset_scsi_drive(disk_name):
                        device = f"/dev/{partition_name}"
                        device_ready = True
                except Exception as e:
                    logging.warning(f"Error checking device holders: {e}")
                    device_ready = True  # Optimistically try e2fsck

        if not device_ready:
            logging.error("Could not make device available for fsck")
            repair_attempted = True
            last_fsck_time = time.time()
            # fall through to finally — restart services
            return repair_attempted

        # Verify device node exists after possible SCSI reset
        if not os.path.exists(device):
            logging.error(f"Device {device} does not exist after reset")
            repair_attempted = True
            last_fsck_time = time.time()
            return repair_attempted

        # --- Run e2fsck ---
        logging.info(f"Running e2fsck -p -f {device} (timeout 1800s)")
        try:
            fsck_result = subprocess.run(
                ["sudo", "e2fsck", "-p", "-f", device],
                capture_output=True, text=True, timeout=1800
            )
            logging.info(f"e2fsck exit code: {fsck_result.returncode}")
            if fsck_result.stdout:
                for line in fsck_result.stdout.strip().split('\n')[-20:]:
                    logging.info(f"e2fsck: {line}")
            if fsck_result.stderr:
                for line in fsck_result.stderr.strip().split('\n')[-10:]:
                    logging.warning(f"e2fsck stderr: {line}")
            # Exit codes: 0=no errors, 1=errors corrected, 2=reboot needed,
            # 4=errors left uncorrected, 8=operational error
            if fsck_result.returncode in (0, 1):
                logging.info(f"e2fsck completed successfully on {device}")
            elif fsck_result.returncode & 2:
                logging.warning(f"e2fsck requests reboot for {device}")
            else:
                logging.error(f"e2fsck reported uncorrected errors on {device} (exit {fsck_result.returncode})")
        except subprocess.TimeoutExpired:
            logging.error(f"e2fsck timed out after 1800s on {device}")

        repair_attempted = True
        last_fsck_time = time.time()

    except Exception as e:
        logging.error(f"Exception during ext4 repair: {e}")
        repair_attempted = True  # Still restart services
    finally:
        # ALWAYS restart services, even on failure
        logging.info("Restarting services after ext4 repair")

        # Restart automount
        automount_unit = f"automount@{partition_name}.service"
        subprocess.run(["sudo", "systemctl", "reset-failed", automount_unit],
                       capture_output=True, timeout=20)
        subprocess.run(["sudo", "systemctl", "start", automount_unit],
                       capture_output=True, timeout=60)
        time.sleep(5)

        # Restart Docker (must be up before uniondrive/fula)
        subprocess.run(["sudo", "systemctl", "reset-failed", "docker.service"],
                       capture_output=True, timeout=20)
        subprocess.run(["sudo", "systemctl", "start", "docker.service"],
                       capture_output=True, timeout=120)
        time.sleep(5)

        # Restart uniondrive (blocks until READY/mergerfs or WatchdogSec timeout)
        subprocess.run(["sudo", "systemctl", "reset-failed", "uniondrive.service"],
                       capture_output=True, timeout=20)
        subprocess.run(["sudo", "systemctl", "start", "uniondrive.service"],
                       capture_output=True, timeout=150)

        # Start fula (has ExecStartPre=/bin/sleep 60 — don't wait for full startup)
        safe_start_fula(capture_output=True, timeout=120)

        # Clear LED
        subprocess.run(["sudo", "python", LED_PATH, "green", "1"],
                       capture_output=True, timeout=20)

        _release_fsck_lock()
        logging.info("ext4 repair sequence complete")

    return repair_attempted


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

            # Check disk space first — pebble fix is pointless if disk is full
            has_space, free_gb = check_disk_space("/uniondrive", min_gb=0.5)
            if not has_space:
                logging.warning(f"Low disk ({free_gb:.2f}GB). Running docker prune before pebble fix.")
                subprocess.run(["sudo", "docker", "system", "prune", "-f"],
                               capture_output=True, timeout=120)
                has_space, free_gb = check_disk_space("/uniondrive", min_gb=0.1)
                if not has_space:
                    logging.error("Disk still full after prune. Skipping pebble fix to avoid escalation.")
                    return False  # Don't count toward restart_attempts

            subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True, check=True)
            time.sleep(10)
            pebble_dir = "/uniondrive/ipfs-cluster/pebble"
            if os.path.exists(pebble_dir):
                subprocess.run(["sudo", "rm", "-rf", pebble_dir], capture_output=True, check=True)
                subprocess.run(["sudo", "mkdir", "-p", pebble_dir], capture_output=True, check=True)
                logging.info("Pebble directory contents removed.")
            else:
                logging.warning("Pebble directory not found.")
            safe_start_fula(capture_output=True, check=True)
            time.sleep(30)
            cluster_error_found = True
        elif "error obtaining execution lock: cannot acquire lock:" in ipfs_cluster_logs:
            logging.warning("IPFS Cluster lock issue detected. Attempting to fix.")
            subprocess.run(["sudo", "systemctl", "stop", "fula.service"], capture_output=True, check=True)
            time.sleep(10)
            subprocess.run(["sudo", "rm", "-f", "/uniondrive/ipfs-cluster/cluster.lock"], capture_output=True, check=True)
            logging.info("IPFS Cluster lock file removed.")
            safe_start_fula(capture_output=True, check=True)
            time.sleep(30)
            cluster_error_found = True
        elif "status_code=000" in ipfs_cluster_logs and "Request failed, retrying in 60 seconds" in ipfs_cluster_logs:
            logging.warning("IPFS Cluster status code issue detected. Attempting to restart fula.")
            safe_restart_fula(capture_output=True, check=True)
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
        safe_restart_fula(capture_output=True, check=True)
        time.sleep(30)
        return True
    
    # Check for deprecated Provider config field (kubo 0.40+ FATAL)
    if "Deprecated configuration detected" in ipfs_host_logs and "Provider" in ipfs_host_logs:
        logging.warning("IPFS Host: deprecated Provider config field detected. Stripping it.")
        ipfs_config_path = "/home/pi/.internal/ipfs_data/config"
        if os.path.exists(ipfs_config_path):
            strip_deprecated_provider_fields(ipfs_config_path)
        # Also fix the template so initipfs doesn't re-introduce it
        ipfs_template_path = "/home/pi/.internal/ipfs_config"
        if os.path.exists(ipfs_template_path):
            strip_deprecated_provider_fields(ipfs_template_path)
        logging.info("Restarting ipfs_host after removing deprecated Provider field.")
        subprocess.run(["sudo", "docker", "restart", "ipfs_host"],
                       capture_output=True, timeout=60)
        time.sleep(15)
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
            safe_restart_fula(capture_output=True, check=True)
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
        safe_start_fula(capture_output=True)
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

        safe_start_fula(capture_output=True)
        time.sleep(30)
        return True

    if "'path' field is missing" in ipfs_host_logs:
        logging.warning("IPFS Host 'path' field missing in datastore config. Deleting corrupted kubo config to force recreation.")
        ipfs_config_path = "/home/pi/.internal/ipfs_data/config"
        if os.path.exists(ipfs_config_path):
            subprocess.run(["sudo", "rm", "-f", ipfs_config_path], capture_output=True, check=True)
            logging.info(f"Deleted corrupted IPFS config: {ipfs_config_path}")
        safe_restart_fula(capture_output=True, timeout=120)
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
        safe_restart_fula(capture_output=True)
        time.sleep(30)
        return True

    logging.info(
        f"Relay and swarm connectivity failed ({relay_fail_count}/5). "
        "Will retry next cycle."
    )
    return False


def check_and_fix_kubo_local():
    """Check kubo-local (ipfs_local) container for common errors and fix them.

    This is a non-disruptive check: it only restarts the ipfs_local container
    itself. It never restarts fula.service, never triggers reboots, and never
    counts toward restart_attempts. The device works fine without kubo-local,
    so issues here must not disturb other processes.

    Returns:
        bool: True if an issue was detected and a fix was attempted, False otherwise
    """
    try:
        # Skip if container doesn't exist
        all_containers = subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'")
        if "ipfs_local" not in all_containers:
            return False

        ipfs_local_logs = subprocess.getoutput("sudo docker logs ipfs_local --tail 20 2>&1")

        # 1. IPFS_PATH directory missing — kubo entrypoint chown fails
        if "chown:" in ipfs_local_logs and "ipfs_data_local" in ipfs_local_logs and "No such file or directory" in ipfs_local_logs:
            logging.warning("kubo-local: IPFS_PATH directory missing. Creating it and restarting container.")
            subprocess.run(["sudo", "mkdir", "-p", "/home/pi/.internal/ipfs_data_local"],
                           capture_output=True, timeout=20)
            subprocess.run(["sudo", "chown", "-R", "1000:1000", "/home/pi/.internal/ipfs_data_local"],
                           capture_output=True, timeout=20)
            subprocess.run(["sudo", "docker", "restart", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 2. Deprecated Provider config field (kubo 0.40+ FATAL)
        if "Deprecated configuration detected" in ipfs_local_logs and "Provider" in ipfs_local_logs:
            logging.warning("kubo-local: deprecated Provider config field detected. Stripping it.")
            config_path = "/home/pi/.internal/ipfs_data_local/config"
            if os.path.exists(config_path):
                strip_deprecated_provider_fields(config_path)
            subprocess.run(["sudo", "docker", "restart", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 3. Pebble database corruption
        if "failed to open pebble database" in ipfs_local_logs:
            logging.warning("kubo-local: Pebble database error. Clearing datastore and restarting.")
            subprocess.run(["sudo", "docker", "stop", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(5)
            datastore_dir = "/uniondrive/ipfs_datastore_local/datastore"
            if os.path.exists(datastore_dir):
                subprocess.run(["sudo", "rm", "-rf", datastore_dir], capture_output=True, timeout=30)
                subprocess.run(["sudo", "mkdir", "-p", datastore_dir], capture_output=True, timeout=10)
                subprocess.run(["sudo", "chown", "-R", "1000:1000", datastore_dir],
                               capture_output=True, timeout=20)
            blocks_dir = "/uniondrive/ipfs_datastore_local/blocks"
            if os.path.exists(blocks_dir):
                subprocess.run(["sudo", "rm", "-rf", blocks_dir], capture_output=True, timeout=30)
                subprocess.run(["sudo", "mkdir", "-p", blocks_dir], capture_output=True, timeout=10)
                subprocess.run(["sudo", "chown", "-R", "1000:1000", blocks_dir],
                               capture_output=True, timeout=20)
            subprocess.run(["sudo", "docker", "start", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 4. Flatfs shard or blocks directory issues
        if ("Error: invalid or no prefix in shard identifier:" in ipfs_local_logs or
                "Error: directory missing SHARDING file:" in ipfs_local_logs or
                "no such file or directory" in ipfs_local_logs and "ipfs_datastore_local/blocks" in ipfs_local_logs):
            logging.warning("kubo-local: Flatfs blocks issue. Clearing blocks and restarting.")
            subprocess.run(["sudo", "docker", "stop", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(5)
            blocks_dir = "/uniondrive/ipfs_datastore_local/blocks"
            if os.path.exists(blocks_dir):
                subprocess.run(["sudo", "rm", "-rf", blocks_dir], capture_output=True, timeout=30)
            subprocess.run(["sudo", "mkdir", "-p", blocks_dir], capture_output=True, timeout=10)
            subprocess.run(["sudo", "chown", "-R", "1000:1000", blocks_dir],
                           capture_output=True, timeout=20)
            subprocess.run(["sudo", "docker", "start", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 5. Version mismatch — write correct version and restart
        if "Error: Your programs version" in ipfs_local_logs and "is lower than your repos" in ipfs_local_logs:
            logging.warning("kubo-local: Version mismatch. Updating version file.")
            version_file = "/home/pi/.internal/ipfs_data_local/version"
            # Extract the expected version from the error message
            for ver in ["17", "16"]:
                if f"version ({ver})" in ipfs_local_logs:
                    subprocess.run(["sudo", "tee", version_file],
                                   input=ver.encode(), capture_output=True, timeout=10)
                    break
            subprocess.run(["sudo", "docker", "restart", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 6. Migration permission error
        if "permission denied" in ipfs_local_logs and "ipfs_data_local" in ipfs_local_logs:
            logging.warning("kubo-local: Permission error. Fixing ownership and restarting.")
            subprocess.run(["sudo", "chown", "-R", "1000:1000", "/home/pi/.internal/ipfs_data_local"],
                           capture_output=True, timeout=30)
            if os.path.exists("/uniondrive/ipfs_datastore_local"):
                subprocess.run(["sudo", "chown", "-R", "1000:1000", "/uniondrive/ipfs_datastore_local"],
                               capture_output=True, timeout=30)
            subprocess.run(["sudo", "docker", "restart", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 7. Config 'path' field missing — delete config to let init script regenerate
        if "'path' field is missing" in ipfs_local_logs:
            logging.warning("kubo-local: Config 'path' field missing. Deleting config for regeneration.")
            config_path = "/home/pi/.internal/ipfs_data_local/config"
            if os.path.exists(config_path):
                subprocess.run(["sudo", "rm", "-f", config_path], capture_output=True, timeout=10)
            subprocess.run(["sudo", "docker", "restart", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 8. Lock file stuck — remove and restart
        if "lock" in ipfs_local_logs.lower() and ("acquire" in ipfs_local_logs.lower() or "already locked" in ipfs_local_logs.lower()):
            logging.warning("kubo-local: Lock file issue. Removing locks and restarting.")
            subprocess.run(["sudo", "docker", "stop", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(5)
            subprocess.run(["sudo", "rm", "-f", "/home/pi/.internal/ipfs_data_local/repo.lock"],
                           capture_output=True, timeout=10)
            subprocess.run(["sudo", "rm", "-f", "/uniondrive/ipfs_datastore_local/datastore/LOCK"],
                           capture_output=True, timeout=10)
            subprocess.run(["sudo", "docker", "start", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        # 9. Container is not running but exists — just start it
        running_containers = subprocess.getoutput("sudo docker ps --format '{{.Names}}'")
        if "ipfs_local" not in running_containers:
            logging.warning("kubo-local: Container exists but not running. Starting it.")
            # Clean up stale locks before starting
            subprocess.run(["sudo", "rm", "-f", "/home/pi/.internal/ipfs_data_local/repo.lock"],
                           capture_output=True, timeout=10)
            subprocess.run(["sudo", "rm", "-f", "/uniondrive/ipfs_datastore_local/datastore/LOCK"],
                           capture_output=True, timeout=10)
            subprocess.run(["sudo", "docker", "start", "ipfs_local"],
                           capture_output=True, timeout=60)
            time.sleep(15)
            return True

        return False
    except Exception as e:
        logging.error(f"Error in check_and_fix_kubo_local: {e}")
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
            safe_restart_fula(capture_output=True, check=True)
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
                    safe_restart_fula(capture_output=True, check=True)
                    time.sleep(30)
                    return True

                # No valid backup, delete corrupted config
                logging.warning(f"No valid backup available. Deleting corrupted config: {config_yaml_path}")
                subprocess.run(["sudo", "rm", "-f", config_yaml_path], capture_output=True, check=True)
                logging.info(f"Deleted corrupted config.yaml: {config_yaml_path}")

                # Restart fula service
                logging.info("Restarting fula service after removing corrupted config.")
                safe_restart_fula(capture_output=True, check=True)
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
                safe_restart_fula(capture_output=True, check=True)
                time.sleep(30)
                return True

            # No valid backup, delete corrupted config
            logging.warning(f"No valid backup available. Deleting config with syntax error: {config_yaml_path}")
            subprocess.run(["sudo", "rm", "-f", config_yaml_path], capture_output=True, check=True)
            logging.info(f"Deleted config.yaml with syntax error: {config_yaml_path}")

            # Restart fula service
            logging.info("Restarting fula service after removing config with syntax error.")
            safe_restart_fula(capture_output=True, check=True)
            time.sleep(30)
            return True

        # Config appears valid but error was still detected - try restart anyway
        logging.info("Config appears valid but error was detected. Restarting fula service.")
        safe_restart_fula(capture_output=True, check=True)
        time.sleep(30)
        return True

    except subprocess.CalledProcessError as e:
        logging.error(f"Error during config.yaml fix: {str(e)}")
        return False
    except Exception as e:
        logging.error(f"Unexpected error in check_and_fix_config_yaml: {str(e)}")
        return False


ENV_FILE_PATH = os.path.join(FULA_PATH, ".env")
ENV_FILE_DEFAULT = {
    "GO_FULA": "functionland/go-fula",
    "FX_SUPPROT": "functionland/fxsupport",
    "IPFS_CLUSTER": "functionland/ipfs-cluster",
    "FULA_PINNING": "functionland/fula-pinning",
    "FULA_GATEWAY": "functionland/fula-gateway",
    "WPA_SUPLICANT_PATH": "/etc",
    "CURRENT_USER": "pi",
}


def check_and_fix_env_file():
    """Check /usr/bin/fula/.env for corruption (null bytes, binary garbage) and repair.

    The .env file can become corrupted (filled with null bytes) due to filesystem
    errors, power loss during write, or ext4 journal issues.  docker-compose and
    fula.sh both refuse to read the file, which prevents all services from starting.

    Detection:
      - File contains null bytes (0x00) or other non-text bytes
      - File fails KEY=VALUE line validation
      - fula.sh logs show "unexpected character" errors

    Repair:
      - Attempt to salvage the existing tag (release, test*, etc.) from readable lines
      - Rewrite the file with correct KEY=VALUE content using the salvaged or default tag

    Returns:
        bool: True if corruption was detected and fixed, False otherwise
    """
    try:
        if not os.path.exists(ENV_FILE_PATH):
            logging.warning(f".env file missing: {ENV_FILE_PATH}")
            # Regenerate with default tag
            _write_env_file("release")
            logging.info(f"Regenerated missing .env with tag 'release'")
            safe_restart_fula(capture_output=True, timeout=120)
            time.sleep(30)
            return True

        # Read raw bytes to detect binary corruption
        with open(ENV_FILE_PATH, 'rb') as f:
            raw = f.read()

        # Check 1: null bytes — the exact symptom reported
        if b'\x00' in raw:
            null_count = raw.count(b'\x00')
            logging.warning(f".env file corrupted: {null_count} null bytes detected in {ENV_FILE_PATH}")
            tag = _salvage_env_tag(raw)
            _write_env_file(tag)
            logging.info(f"Rewrote .env with tag '{tag}' after null-byte corruption")
            safe_restart_fula(capture_output=True, timeout=120)
            time.sleep(30)
            return True

        # Check 2: non-text bytes (binary garbage that isn't null)
        try:
            text = raw.decode('utf-8')
        except UnicodeDecodeError:
            logging.warning(f".env file corrupted: non-UTF8 content in {ENV_FILE_PATH}")
            tag = _salvage_env_tag(raw)
            _write_env_file(tag)
            logging.info(f"Rewrote .env with tag '{tag}' after encoding corruption")
            safe_restart_fula(capture_output=True, timeout=120)
            time.sleep(30)
            return True

        # Check 3: validate every non-empty, non-comment line is KEY=VALUE
        is_valid = True
        for line_num, line in enumerate(text.splitlines(), 1):
            stripped = line.strip()
            if not stripped or stripped.startswith('#'):
                continue
            if not re.match(r'^[A-Za-z_][A-Za-z0-9_]*=', stripped):
                logging.warning(f".env file has invalid line {line_num}: {stripped[:80]}")
                is_valid = False
                break

        if not is_valid:
            tag = _salvage_env_tag(raw)
            _write_env_file(tag)
            logging.info(f"Rewrote .env with tag '{tag}' after format corruption")
            safe_restart_fula(capture_output=True, timeout=120)
            time.sleep(30)
            return True

        # Check 4: ensure minimum required keys exist
        required_keys = {"GO_FULA", "FX_SUPPROT"}
        found_keys = set()
        for line in text.splitlines():
            stripped = line.strip()
            if '=' in stripped and not stripped.startswith('#'):
                key = stripped.split('=', 1)[0]
                found_keys.add(key)

        missing = required_keys - found_keys
        if missing:
            logging.warning(f".env file missing required keys: {missing}")
            tag = _salvage_env_tag(raw)
            _write_env_file(tag)
            logging.info(f"Rewrote .env with tag '{tag}' after missing keys")
            safe_restart_fula(capture_output=True, timeout=120)
            time.sleep(30)
            return True

        return False

    except Exception as e:
        logging.error(f"Error in check_and_fix_env_file: {e}")
        return False


def _salvage_env_tag(raw_bytes):
    """Try to extract the image tag from a possibly-corrupted .env file.

    Scans for 'FX_SUPPROT=' or 'GO_FULA=' lines and extracts the tag after ':'.
    Falls back to 'release' if nothing salvageable.

    Args:
        raw_bytes: raw file content (bytes)

    Returns:
        str: the salvaged tag or 'release'
    """
    try:
        # Filter out null bytes and try to decode
        cleaned = raw_bytes.replace(b'\x00', b'')
        text = cleaned.decode('utf-8', errors='ignore')
        for line in text.splitlines():
            line = line.strip()
            for prefix in ('FX_SUPPROT=', 'GO_FULA='):
                if line.startswith(prefix):
                    value = line[len(prefix):]
                    if ':' in value:
                        tag = value.rsplit(':', 1)[1]
                        if tag and re.match(r'^[A-Za-z0-9._-]+$', tag):
                            return tag
    except Exception:
        pass
    return "release"


def _write_env_file(tag):
    """Write a valid .env file with the given image tag.

    Args:
        tag: Docker image tag (e.g. 'release', 'test153')
    """
    lines = []
    for key, image in ENV_FILE_DEFAULT.items():
        if key in ("WPA_SUPLICANT_PATH", "CURRENT_USER"):
            lines.append(f"{key}={image}")
        else:
            lines.append(f"{key}={image}:{tag}")
    content = "\n".join(lines) + "\n"
    try:
        with open(ENV_FILE_PATH, 'w') as f:
            f.write(content)
        logging.info(f"Wrote .env file: {ENV_FILE_PATH}")
    except PermissionError:
        # Try with sudo
        subprocess.run(
            ["sudo", "tee", ENV_FILE_PATH],
            input=content.encode(), capture_output=True, timeout=10
        )
        logging.info(f"Wrote .env file via sudo: {ENV_FILE_PATH}")


def check_internet_connection():
    try:
        requests.head("https://www.google.com", timeout=5)
        logging.info("Internet connection is available.")
        return True
    except requests.RequestException:
        logging.error("No internet connection available. Checking NetworkManager status...")
        try:
            result = subprocess.run(
                ["sudo", "systemctl", "is-active", "NetworkManager"],
                capture_output=True, text=True, timeout=10
            )
            nm_status = result.stdout.strip()
            if nm_status != "active":
                logging.error(f"NetworkManager is not running (status: {nm_status}). Attempting to restart...")
                subprocess.run(
                    ["sudo", "systemctl", "restart", "NetworkManager"],
                    capture_output=True, timeout=30
                )
                time.sleep(10)
                # Retry internet check after restarting NetworkManager
                try:
                    requests.head("https://www.google.com", timeout=5)
                    logging.info("Internet connection restored after restarting NetworkManager.")
                    return True
                except requests.RequestException:
                    logging.error("Internet still unavailable after restarting NetworkManager.")
            else:
                logging.info("NetworkManager is active, internet issue is not due to NetworkManager.")
        except Exception as e:
            logging.error(f"Error checking/restarting NetworkManager: {e}")
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
    # Only monitor fula_pinning if its container has been created at least once.
    # Avoids restart loops on devices that got this script before the image was pulled.
    if "fula_pinning" in subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'"):
        containers_to_check.append("fula_pinning")
    # Only monitor fula_gateway if its container has been created at least once.
    if "fula_gateway" in subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'"):
        containers_to_check.append("fula_gateway")
    # kubo-local is non-critical — exclude from containers_to_check so its
    # downtime never triggers fula.service restarts or counts toward reboot.
    # It has its own self-contained check_and_fix_kubo_local() instead.
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
            if check_and_repair_ext4():
                logging.info("ext4 repair attempted inside monitor loop.")
                time.sleep(30)
                continue
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
            safe_start_fula(capture_output=True, timeout=120)
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
            safe_restart_fula(capture_output=True, timeout=120)
            time.sleep(35)
            restart_attempts += 1
            docker_service_status = subprocess.getoutput("sudo systemctl is-active docker.service")

        all_containers_running = True
        for container in containers_to_check:
            container_running = container in subprocess.getoutput("sudo docker ps --format '{{.Names}}'")
            if container_running:
                logging.info(f"container_running inside monitor passed for {container}")
                logs = subprocess.getoutput(f"sudo docker logs --tail 15 {container} 2>&1")
                if "ERROR:" in logs or "Error:" in logs:
                    logging.error(f"{container} logs contain ERROR:. Attempting to restart fula.service")
                    container_running = False
                else:
                    logging.info(f"no ERROR found in the logs of {container}")
            else:
                all_containers_running = False
                logging.error(f"{container} is not running or logs contain ERROR:. Attempting to restart fula.service")
                subprocess.run(["sudo", "python", LED_PATH, "yellow", "5"], capture_output=True, timeout=20)
                result = safe_restart_fula(capture_output=True, timeout=120)
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
            
        # Run fix checks BEFORE proxy health check so they can't be short-circuited
        env_file_fixed = check_and_fix_env_file()
        if env_file_fixed:
            restart_attempts += 1
            continue  # re-check after .env repair
        ipfs_cluster_fixed = check_and_fix_ipfs_cluster()
        ipfs_host_fixed = check_and_fix_ipfs_host()
        config_yaml_fixed = check_and_fix_config_yaml()
        if ipfs_cluster_fixed or ipfs_host_fixed or config_yaml_fixed:
            restart_attempts += 1
            continue  # re-check after fixes

        # kubo-local: non-disruptive self-heal (never affects restart_attempts)
        check_and_fix_kubo_local()

        # Auto-recover missing config.yaml from backup (e.g. after filesystem corruption)
        config_yaml_path = "/home/pi/.internal/config.yaml"
        config_yaml_backup = config_yaml_path + ".backup"
        if not os.path.exists(config_yaml_path) and os.path.exists(config_yaml_backup):
            logging.warning(f"config.yaml missing but backup exists. Attempting restore from {config_yaml_backup}")
            if restore_config_from_backup(config_yaml_path):
                logging.info("config.yaml restored from backup. Restarting fula.service.")
                safe_restart_fula(capture_output=True, timeout=120)
                time.sleep(30)
                restart_attempts += 1
                continue
            else:
                logging.error("Failed to restore config.yaml from backup.")

        if all_containers_running:
            # Check go-fula proxy health
            if not check_proxy_health():
                logging.warning("go-fula proxy ports unreachable. Restarting fula.service.")
                safe_restart_fula(capture_output=True, timeout=120)
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
                safe_restart_fula(capture_output=True, timeout=120)
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

    if restart_attempts >= 4:
        if check_and_repair_ext4():
            logging.info("ext4 repair attempted at escalation boundary.")
            restart_attempts = 0
            return  # Back to caller for fresh evaluation
        logging.error("Maximum restart attempts reached. Checking .reboot_flag status.")
        activate_wireguard_support()
        current_time = time.time()
        
        if os.path.exists(REBOOT_FLAG_PATH):
            file_mod_time = os.path.getmtime(REBOOT_FLAG_PATH)
            time_difference = current_time - file_mod_time
            
            if time_difference < 12 * 60 * 60:  # 12 hours in seconds
                # Issue persists even after reboot within 12 hours
                gave_up_path = os.path.join(HOME_PATH, ".readiness_gave_up")
                if os.path.exists(gave_up_path):
                    # Already ran red LED loop this cycle. Stay alive, keep WireGuard active.
                    logging.error("Red LED loop already completed. Sleeping 1h before re-eval.")
                    activate_wireguard_support()
                    time.sleep(3600)
                    return  # Back to main loop for fresh evaluation

                logging.error("Issue persists after recent reboot. Flashing red ~17 min.")
                red_iterations = 0
                while red_iterations < 200:
                    subprocess.run(["sudo", "python", LED_PATH, "red", "15"], capture_output=True, timeout=30)
                    activate_wireguard_support()
                    get_wifi_info_and_ping()
                    time.sleep(5)
                    red_iterations += 1

                # Mark that we completed the red loop — prevent repeat on next entry
                subprocess.run(['sudo', 'touch', gave_up_path], timeout=20)
                logging.error("Red LED loop done. Sleeping 1h to prevent restart storm.")
                activate_wireguard_support()
                time.sleep(3600)
                return  # NOT sys.exit(1) — stay alive in main loop
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
    # Clear red-LED-loop sentinel from previous run so we get a fresh start
    gave_up_path = os.path.join(HOME_PATH, ".readiness_gave_up")
    subprocess.run(['sudo', 'rm', '-f', gave_up_path], timeout=20)
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
            if check_and_repair_ext4():
                logging.info("ext4 repair attempted. Re-evaluating conditions.")
                fula_restart_attempts = 0
                time.sleep(90)  # fula.service needs 60s+ (ExecStartPre=sleep 60)
                continue
            # Check .env corruption early — a corrupt .env prevents all containers from starting
            if check_and_fix_env_file():
                logging.info(".env file repaired. Re-evaluating conditions.")
                fula_restart_attempts = 0
                time.sleep(90)
                continue
            # Check if 'fula_go' exists in `docker ps -a`
            docker_ps_a_output = subprocess.getoutput("sudo docker ps -a --format '{{.Names}}'")
            docker_ps_output = subprocess.getoutput("sudo docker ps --format '{{.Names}}'")

            if "fula_go" in docker_ps_a_output and \
                all(container in docker_ps_output for container in ["fula_fxsupport", "fula_updater"]) and \
                fula_restart_attempts < 4:
                    logging.info("fula_go container found but is not running. Attempting to restart fula.service")
                    result = safe_restart_fula(capture_output=True, timeout=120)
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
