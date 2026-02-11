#!/usr/bin/env python3
"""
Selective Kubo Config Merge

Merges managed fields from the template kubo config into the deployed config
while preserving device-specific settings (Identity, Datastore, API/Gateway addresses).

Also updates the template copy (ipfs_config) so that initipfs uses the latest
template on next go-fula container restart.

Usage:
    python3 update_kubo_config.py [--dry-run]

Environment (or defaults):
    FULA_PATH       /usr/bin/fula
    HOME_DIR        /home/pi
"""

import json
import os
import sys
import shutil
import logging
from datetime import datetime
from copy import deepcopy

FULA_PATH = os.environ.get("FULA_PATH", "/usr/bin/fula")
HOME_DIR = os.environ.get("HOME_DIR", "/home/pi")

TEMPLATE_CONFIG = os.path.join(FULA_PATH, "kubo", "config")
DEPLOYED_CONFIG = os.path.join(HOME_DIR, ".internal", "ipfs_data", "config")
TEMPLATE_COPY = os.path.join(HOME_DIR, ".internal", "ipfs_config")

LOG_PATH = os.path.join(HOME_DIR, "fula.sh.log")

# Fields that should be merged from template -> deployed.
# Dot-separated paths into the JSON object.
MANAGED_FIELDS = [
    "Bootstrap",
    "Peering.Peers",
    "Swarm.RelayClient.StaticRelays",
    "Swarm.RelayClient.Enabled",
    "Swarm.ConnMgr",
    "Experimental",
    "Addresses.Swarm",
    "Discovery",
]

# Fields that must NEVER be touched (even if present in template).
# These are device-specific or set by initipfs.
PRESERVED_FIELDS = [
    "Identity",
    "Datastore",
    "Addresses.API",
    "Addresses.Gateway",
]


def setup_logging(log_path):
    logger = logging.getLogger("kubo_config_merge")
    logger.setLevel(logging.INFO)
    fmt = logging.Formatter("%(asctime)s: kubo_config_merge: %(message)s",
                            datefmt="%a %b %d %H:%M:%S %Z %Y")

    sh = logging.StreamHandler(sys.stdout)
    sh.setFormatter(fmt)
    logger.addHandler(sh)

    try:
        fh = logging.FileHandler(log_path, mode="a")
        fh.setFormatter(fmt)
        logger.addHandler(fh)
    except (IOError, OSError):
        pass  # log file may not be writable in test environments

    return logger


def load_json(path):
    with open(path, "r") as f:
        return json.load(f)


def save_json(path, data):
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    shutil.move(tmp, path)


def get_nested(obj, dotpath):
    """Retrieve a value from a nested dict using a dot-separated path.
    Returns (value, True) if found, (None, False) if any key is missing."""
    keys = dotpath.split(".")
    cur = obj
    for k in keys:
        if not isinstance(cur, dict) or k not in cur:
            return None, False
        cur = cur[k]
    return cur, True


def set_nested(obj, dotpath, value):
    """Set a value in a nested dict using a dot-separated path.
    Creates intermediate dicts as needed."""
    keys = dotpath.split(".")
    cur = obj
    for k in keys[:-1]:
        if k not in cur or not isinstance(cur[k], dict):
            cur[k] = {}
        cur = cur[k]
    cur[keys[-1]] = value


def is_preserved(field):
    """Check if a field path falls under a preserved field."""
    for pf in PRESERVED_FIELDS:
        if field == pf or field.startswith(pf + "."):
            return True
    return False


def merge_configs(template, deployed, logger):
    """Merge managed fields from template into deployed config.
    Returns (updated_config, list_of_changes)."""
    result = deepcopy(deployed)
    changes = []

    for field in MANAGED_FIELDS:
        if is_preserved(field):
            logger.warning("Skipping preserved field %s in managed list", field)
            continue

        tmpl_val, tmpl_found = get_nested(template, field)
        if not tmpl_found:
            # Template doesn't define this field — skip
            continue

        deployed_val, deployed_found = get_nested(result, field)

        if deployed_found and deployed_val == tmpl_val:
            # Already up to date
            continue

        if not deployed_found:
            action = "added"
        else:
            action = "updated"

        set_nested(result, field, deepcopy(tmpl_val))
        changes.append((field, action))
        logger.info("  %s: %s", field, action)

    return result, changes


def main():
    dry_run = "--dry-run" in sys.argv

    logger = setup_logging(LOG_PATH)
    logger.info("Starting kubo config merge%s", " (dry-run)" if dry_run else "")

    # Check required files exist
    if not os.path.isfile(TEMPLATE_CONFIG):
        logger.error("Template config not found: %s", TEMPLATE_CONFIG)
        return 1

    if not os.path.isfile(DEPLOYED_CONFIG):
        logger.info("Deployed config not found: %s — skipping merge (fresh install?)",
                     DEPLOYED_CONFIG)
        return 0

    try:
        template = load_json(TEMPLATE_CONFIG)
    except (json.JSONDecodeError, IOError) as e:
        logger.error("Failed to read template config: %s", e)
        return 1

    try:
        deployed = load_json(DEPLOYED_CONFIG)
    except (json.JSONDecodeError, IOError) as e:
        logger.error("Failed to read deployed config: %s", e)
        return 1

    # Merge
    updated, changes = merge_configs(template, deployed, logger)

    if not changes:
        logger.info("No config changes needed — deployed config is up to date")
    else:
        logger.info("Config changes detected: %d field(s) to update", len(changes))
        for field, action in changes:
            logger.info("  %s: %s", field, action)

        if not dry_run:
            # Backup deployed config before writing
            backup_path = DEPLOYED_CONFIG + ".bak"
            try:
                shutil.copy2(DEPLOYED_CONFIG, backup_path)
                logger.info("Backed up deployed config to %s", backup_path)
            except (IOError, OSError) as e:
                logger.warning("Could not create backup: %s", e)

            # Write updated deployed config
            try:
                save_json(DEPLOYED_CONFIG, updated)
                logger.info("Updated deployed config: %s", DEPLOYED_CONFIG)
            except (IOError, OSError) as e:
                logger.error("Failed to write deployed config: %s", e)
                return 1

    # Update the template copy (ipfs_config) so initipfs uses latest template.
    # This is best-effort — failure here should not crash the script since the
    # critical deployed config update above already succeeded.
    try:
        if os.path.isfile(TEMPLATE_COPY):
            try:
                existing_template_copy = load_json(TEMPLATE_COPY)
            except (json.JSONDecodeError, IOError):
                existing_template_copy = None

            # Only update if the template copy differs from current template
            # Compare managed fields only (template copy may have Identity set by initipfs)
            needs_update = False
            if existing_template_copy is None:
                needs_update = True
            else:
                for field in MANAGED_FIELDS:
                    tmpl_val, tmpl_found = get_nested(template, field)
                    copy_val, copy_found = get_nested(existing_template_copy, field)
                    if tmpl_found and (not copy_found or copy_val != tmpl_val):
                        needs_update = True
                        break

            if needs_update and not dry_run:
                # Merge managed fields from template into the template copy too,
                # preserving any Identity/Datastore that initipfs may have set
                if existing_template_copy is not None:
                    updated_copy, copy_changes = merge_configs(template, existing_template_copy, logger)
                    if copy_changes:
                        save_json(TEMPLATE_COPY, updated_copy)
                        logger.info("Updated template copy: %s (%d fields)",
                                    TEMPLATE_COPY, len(copy_changes))
                else:
                    # No existing template copy — just copy the template
                    shutil.copy2(TEMPLATE_CONFIG, TEMPLATE_COPY)
                    logger.info("Created template copy: %s", TEMPLATE_COPY)
        elif not dry_run:
            # Template copy doesn't exist — create it
            shutil.copy2(TEMPLATE_CONFIG, TEMPLATE_COPY)
            logger.info("Created template copy: %s", TEMPLATE_COPY)
    except (IOError, OSError, PermissionError) as e:
        logger.warning("Could not update template copy: %s", e)

    logger.info("Kubo config merge complete")
    return 0


if __name__ == "__main__":
    sys.exit(main())
