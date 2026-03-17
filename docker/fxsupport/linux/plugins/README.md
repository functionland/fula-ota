## Plugins

Plugins are separate services that can be added to a Fula device (Armbian/RK3588) or PC (Windows/Ubuntu). Users opt-in to run them via the mobile app or desktop installer. Each plugin runs in its own Docker container and has access to the device seed for token/key derivation.

## Plugin Lifecycle

```
User taps Install          User taps Uninstall
       |                          |
       v                          v
  [Installing]               [Uninstalling]
       |                          |
   install.sh                  stop.sh
       |                     uninstall.sh
       v                          |
  [Downloading]  (optional)       v
       |                     (removed from
   download...               active-plugins.txt)
       |
       v
  [Installed]
       |
   start.sh
       |
       v
   (running)                  [Failed]
                              (any step fails)
```

### Status Values

| Status | Meaning |
|--------|---------|
| `Installing` | `install.sh` is running |
| `Downloading` | Long download in progress (written by plugin scripts) |
| `Installed` | Install + start succeeded, service is running |
| `Uninstalling` | `stop.sh` + `uninstall.sh` are running |
| `Failed` | Any lifecycle script failed; check logs and `error.txt` |

Status is stored in `/home/pi/.internal/plugins/<name>/status.txt` and polled by the mobile app every 5 seconds.

## Required Files

Each plugin must be a directory under `/usr/bin/fula/plugins/<name>/` containing:

| File | Required | Description |
|------|----------|-------------|
| `install.sh` | Yes | Installs dependencies, copies service files, enables systemd unit |
| `start.sh` | Yes | Starts the service (called after install and on manual start) |
| `stop.sh` | Yes | Stops the service gracefully |
| `uninstall.sh` | Yes | Removes service, containers, and data |
| `update.sh` | Yes | Stops, pulls new image, restarts. Uses relative paths (`./stop.sh`) |
| `<name>.service` | Yes | Systemd unit file for the plugin |
| `docker-compose.yml` | Yes | Docker Compose config for the plugin container |
| `info.json` | Yes | Plugin metadata shown to users (see schema below) |
| `custom/` | No | Directory for additional scripts, configs, models |
| `install-pc.sh` | No | PC-specific install script (no systemd calls, runs on Windows/Ubuntu) |

## `info.json` Schema

```json
{
    "name": "my-plugin",
    "description": "Human-readable description shown in the app",
    "version": "101",
    "usage": {
        "storage": "none|low|medium|high",
        "compute": "none|low|medium|high",
        "bandwidth": "none|low|medium|high",
        "ram": "none|low|medium|high",
        "gpu": "none|low|medium|high"
    },
    "rewards": [
        {
            "type": "none|token",
            "currency": "$TOKEN",
            "link": "https://..."
        }
    ],
    "socials": [
        {
            "telegram": "",
            "twitter": "",
            "email": "",
            "website": "",
            "discord": ""
        }
    ],
    "instructions": [
        {
            "order": 1,
            "description": "Step description shown to user",
            "url": "https://optional-link",
            "paramId": 1
        }
    ],
    "requiredInputs": [
        {
            "name": "input-name",
            "instructions": "Explain what user should enter",
            "type": "string",
            "default": "default-value"
        }
    ],
    "outputs": [
        {
            "name": "output-name",
            "id": 1
        }
    ],
    "installTimeout": 300,
    "dockerImage": "org/image:tag",
    "modelSha256": "",
    "platformSupport": ["armbian", "pc"],
    "approved": true
}
```

### Field Reference

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `name` | string | (required) | Must match directory name and systemd service name. Only `[a-zA-Z0-9_-]` allowed. |
| `version` | string | (required) | Plugin version. Used by `plugins.sh` to skip redundant updates. |
| `installTimeout` | integer | 300 | Max seconds for install/start/update scripts. Set higher for large downloads (e.g., 3600 for loyal-agent). |
| `dockerImage` | string | "" | Pinned Docker image reference. Used for version tracking. |
| `modelSha256` | string | "" | SHA256 hash of model file. If set, integrity is verified after download. |
| `platformSupport` | array | ["armbian"] | Platforms this plugin supports. `"pc"` enables it in the desktop installer. |
| `approved` | boolean | false | Must be `true` for the plugin to appear in the app. |

## Platform Differences: Armbian vs PC

| Feature | Armbian (Fula device) | PC (Windows/Ubuntu) |
|---------|----------------------|---------------------|
| Service management | systemd (`<name>.service`) | Docker Compose only |
| Install script | `install.sh` (runs as root) | `install-pc.sh` (no systemd) |
| Plugin daemon | `plugins.sh` watches `active-plugins.txt` | `plugin-manager.js` in Electron |
| Hardware plugins | All available | Hardware-specific excluded (e.g., loyal-agent) |
| File paths | `/usr/bin/fula/plugins/`, `/home/pi/.internal/plugins/` | `<dataDir>/internal/plugins/` |

## Security Requirements

- **Plugin names** are validated against `^[a-zA-Z0-9_-]+$` to prevent path traversal.
- **Private keys** and config files containing secrets must be `chmod 600` after creation.
- **Never** store plaintext secrets with default (644) permissions.
- Plugin scripts run as root on Armbian; minimize privileged operations.
- Docker containers should use `no-new-privileges:true` in security_opt.

## Writing a New Plugin

1. Create a directory: `plugins/my-plugin/`
2. Copy the required files from an existing plugin as a template
3. Write `info.json` with all required fields (see schema above)
4. Implement all lifecycle scripts (`install.sh`, `start.sh`, `stop.sh`, `uninstall.sh`, `update.sh`)
5. Create a systemd service file (`my-plugin.service`)
6. Create a `docker-compose.yml` for your container
7. If the plugin needs PC support, add `install-pc.sh` (avoid systemd calls)
8. Add the plugin to the top-level `info.json` array (icon-path entry)
9. Test on device: add plugin name to `active-plugins.txt` and watch logs

## Current Plugins

- **streamr-node**: Runs a Streamr network node, earns $DATA tokens. Cross-platform (Armbian + PC).
- **loyal-agent**: Local AI agent using RK3588 NPU. Armbian only (requires 32GB RAM + NPU hardware).
