import glob
import json
import logging
import os
import subprocess
from urllib.parse import urlparse

import requests


PLUGIN_MANIFEST_GLOB = "/home/pi/.internal/plugins/*/ble_commands.json"
PLUGIN_PROXY_DEFAULT_TIMEOUT_S = 10
_VALID_PLUGIN_COMMAND_TYPES = {"read", "exec"}
_LOCALHOST_HOSTNAMES = {"127.0.0.1", "localhost", "::1"}


class LocalCommandServer:
    def __init__(self, plugin_manifest_glob=None):
        self.commands = {
            'ls': self._combine_ls_outputs,
            'df': self._combine_disk_info,
            'fula': 'systemctl status fula',
            'docker': 'systemctl status docker',
            'docker_ps': self._combine_docker_info,
            'uniondrive': 'systemctl status uniondrive'
        }

        self.exec_commands = {
            'partition': 'sudo touch /home/pi/commands/.command_partition',
            'node_delete': 'sudo rm -rf /uniondrive/chain/chains/functionyard/db/full/*',
            'ipfs_delete': 'sudo rm -rf /uniondrive/ipfs_datastore/blocks/*',
            'restart_fula': 'sudo systemctl restart fula',
            'restart_uniondrive': self._restart_services,
            'hotspot': 'sudo nmcli con up FxBlox',
            'reset': self._reset_system,
            'wireguard/start': self._wireguard_start,
            'wireguard/stop': self._wireguard_stop,
            'wireguard/status': self._wireguard_status,
            'force_update': self._force_update
        }

        # Plugin extension hook: discover ble_commands.json manifests under
        # /home/pi/.internal/plugins/*/ and merge their declared commands into
        # the dispatch dicts. Plugins POST to a local HTTP endpoint they own;
        # this server is the BLE-side proxy. Read-only commands go into
        # self.commands; mutating commands go into self.exec_commands. Plugins
        # are expected to namespace their commands (e.g. "ai/*", "blox-ai/*")
        # to avoid colliding with built-ins.
        self.plugin_manifest_glob = plugin_manifest_glob or PLUGIN_MANIFEST_GLOB
        self.plugin_commands = {}  # name -> {type, proxy_url, timeout_s, plugin_id}
        self.reload_plugins()

    def _combine_ls_outputs(self):
        commands = [
            'ls /home/pi -al',
            'ls / -al',
            'ls /usr/bin/fula',
            'ls /media/pi -al',
            'ls /sys/module/rockchipdrm'
        ]
        output = {}
        for cmd in commands:
            try:
                result = subprocess.check_output(cmd, shell=True).decode('utf-8')
                output[cmd] = result
            except subprocess.CalledProcessError as e:
                output[cmd] = f"Error: {str(e)}"
        return output

    def _combine_disk_info(self):
        try:
            df_output = subprocess.check_output('df -hT', shell=True).decode('utf-8')
            lsblk_output = subprocess.check_output('lsblk', shell=True).decode('utf-8')
            return {
                'df': df_output,
                'lsblk': lsblk_output
            }
        except subprocess.CalledProcessError as e:
            return f"Error: {str(e)}"

    def _combine_docker_info(self):
        try:
            ps_output = subprocess.check_output(
                'sudo docker ps -a --format "table {{.ID}}\t{{.Image}}\t{{.Command}}\t{{.CreatedAt}}\t{{.Status}}\t{{.Ports}}\t{{.Names}}"',
                shell=True, stderr=subprocess.DEVNULL
            ).decode('utf-8')
            images_output = subprocess.check_output(
                'sudo docker images --format "table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}"',
                shell=True, stderr=subprocess.DEVNULL
            ).decode('utf-8')
            return {
                'containers': ps_output,
                'images': images_output
            }
        except subprocess.CalledProcessError as e:
            return f"Error: {str(e)}"

    def _restart_services(self):
        try:
            subprocess.check_call('sudo systemctl restart uniondrive', shell=True)
            subprocess.check_call('sudo systemctl restart fula', shell=True)
            return "Services restarted successfully"
        except subprocess.CalledProcessError as e:
            return f"Error: {str(e)}"

    def _reset_system(self):
        try:
            subprocess.check_call(['sudo', 'rm', '-f', '/home/pi/.internal/config.yaml', '/home/pi/.internal/config.yaml.backup'])
            subprocess.check_call('sudo reboot', shell=True)
            return "System reset initiated"
        except subprocess.CalledProcessError as e:
            return f"Error: {str(e)}"

    def _wireguard_start(self):
        try:
            result = subprocess.run(
                ['sudo', 'systemctl', 'start', 'wireguard-support.service'],
                capture_output=True, text=True, timeout=60
            )
            status = self._wireguard_status()
            if isinstance(status, dict):
                return status
            return {"status": "started", "returncode": result.returncode}
        except Exception as e:
            return f"Error: {str(e)}"

    def _wireguard_stop(self):
        try:
            subprocess.run(
                ['sudo', 'systemctl', 'stop', 'wireguard-support.service'],
                capture_output=True, text=True, timeout=30
            )
            return {"status": "stopped"}
        except Exception as e:
            return f"Error: {str(e)}"

    def _wireguard_status(self):
        try:
            result = subprocess.run(
                ['bash', '/usr/bin/fula/wireguard/status.sh'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                return json.loads(result.stdout)
            return {"status": "unknown", "error": result.stderr}
        except Exception as e:
            return f"Error: {str(e)}"

    def _force_update(self):
        try:
            # Purple LED during update
            subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                           capture_output=True, timeout=5)
            subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'light_purple', '999999'])

            # Pull latest Docker images
            result = subprocess.run(
                ['sudo', 'bash', '/usr/bin/fula/fula.sh', 'update'],
                capture_output=True, text=True, timeout=600
            )

            # Yellow LED for 10 seconds after completion
            subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                           capture_output=True, timeout=5)
            subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'yellow', '10'])

            if result.returncode == 0:
                return {"status": "updated", "msg": "Docker images pulled successfully"}
            else:
                return {"status": "error", "msg": result.stderr[-500:] if result.stderr else "Update failed"}
        except subprocess.TimeoutExpired:
            subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                           capture_output=True, timeout=5)
            subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'yellow', '10'])
            return {"status": "timeout", "msg": "Update timed out after 10 minutes"}
        except Exception as e:
            subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                           capture_output=True, timeout=5)
            return f"Error: {str(e)}"

    def reload_plugins(self):
        """Re-scan plugin manifests and re-register their commands.

        Idempotent: removes previously-registered plugin commands from
        self.commands / self.exec_commands before re-adding from disk.
        Built-in commands are never removed. Called once at startup and
        again whenever commands.sh signals a plugin install/uninstall via
        the .command_plugin_reload flag (wired in a later phase).
        """
        for name in list(self.plugin_commands.keys()):
            cmd_meta = self.plugin_commands.pop(name)
            target = self.commands if cmd_meta["type"] == "read" else self.exec_commands
            if target.get(name) is cmd_meta.get("_handler"):
                target.pop(name, None)

        for manifest_path in sorted(glob.glob(self.plugin_manifest_glob)):
            try:
                with open(manifest_path, "r") as f:
                    manifest = json.load(f)
            except (OSError, json.JSONDecodeError) as e:
                logging.warning("plugin manifest %s unreadable: %s", manifest_path, e)
                continue

            plugin_id = manifest.get("plugin_id")
            commands = manifest.get("commands")
            if not isinstance(plugin_id, str) or not isinstance(commands, list):
                logging.warning(
                    "plugin manifest %s missing/invalid plugin_id or commands; skipped",
                    manifest_path,
                )
                continue

            for cmd in commands:
                if not isinstance(cmd, dict):
                    logging.warning("plugin %s: non-object command entry; skipped", plugin_id)
                    continue
                name = cmd.get("name")
                cmd_type = cmd.get("type")
                proxy_url = cmd.get("proxy_url")
                timeout_s = cmd.get("timeout_s", PLUGIN_PROXY_DEFAULT_TIMEOUT_S)

                if not isinstance(name, str) or not name:
                    logging.warning("plugin %s: command missing name; skipped", plugin_id)
                    continue
                if cmd_type not in _VALID_PLUGIN_COMMAND_TYPES:
                    logging.warning(
                        "plugin %s: command %s has unsupported type %r; skipped",
                        plugin_id, name, cmd_type,
                    )
                    continue
                if not isinstance(proxy_url, str):
                    logging.warning(
                        "plugin %s: command %s proxy_url must be a string; skipped",
                        plugin_id, name,
                    )
                    continue
                try:
                    parsed_url = urlparse(proxy_url)
                except ValueError:
                    parsed_url = None
                # Hostname must be an exact localhost form — startswith() on the raw
                # URL would accept "http://127.0.0.1.attacker.com/x" (subdomain
                # confusion), letting a malicious plugin manifest route BLE proxy
                # traffic to arbitrary external hosts. urlparse().hostname is
                # parsed per RFC 3986 and prevents that.
                if (
                    parsed_url is None
                    or parsed_url.scheme != "http"
                    or parsed_url.hostname not in _LOCALHOST_HOSTNAMES
                ):
                    logging.warning(
                        "plugin %s: command %s proxy_url must be http://{127.0.0.1|localhost|::1}/...; skipped",
                        plugin_id, name,
                    )
                    continue
                try:
                    timeout_s = float(timeout_s)
                except (TypeError, ValueError):
                    logging.warning(
                        "plugin %s: command %s timeout_s not numeric; using default", plugin_id, name,
                    )
                    timeout_s = PLUGIN_PROXY_DEFAULT_TIMEOUT_S

                # Fail-closed on collisions: a plugin must not shadow a built-in
                # or an earlier-loaded plugin's command, regardless of which
                # dispatch dict (read vs exec) the colliding entry lives in.
                # Codex's review caught that the previous "warn and override"
                # behavior let a malicious manifest replace built-ins like
                # restart_fula. We also reject cross-dispatch collisions so a
                # plugin can't register read "x" while another plugin holds exec "x".
                if name in self.commands or name in self.exec_commands:
                    logging.error(
                        "plugin %s: command %s collides with existing built-in or plugin command; REJECTED",
                        plugin_id, name,
                    )
                    continue

                target = self.commands if cmd_type == "read" else self.exec_commands
                handler = self._make_plugin_proxy_handler(name, proxy_url, timeout_s, plugin_id)
                target[name] = handler
                self.plugin_commands[name] = {
                    "name": name,
                    "type": cmd_type,
                    "proxy_url": proxy_url,
                    "timeout_s": timeout_s,
                    "plugin_id": plugin_id,
                    "_handler": handler,
                }

        return len(self.plugin_commands)

    def _make_plugin_proxy_handler(self, name, proxy_url, timeout_s, plugin_id):
        """Return a zero-arg callable that POSTs to the plugin's HTTP endpoint
        and returns the parsed JSON response (or an error dict on failure).

        The dispatch in get_logs() invokes callables with no arguments, so the
        request body is an empty JSON object. Plugins that need parameters
        from the caller will read them from a separate channel in a later
        phase (the streaming variant is a future addition; this phase is
        single-response only).
        """
        def _handler():
            try:
                # allow_redirects=False: per advisor consensus (Gemini + Codex
                # high-confidence), the localhost URL-allowlist is bypassable at
                # runtime if requests follows 30x to an external host. A plugin's
                # endpoint could legitimately resolve, then redirect us to
                # 192.168.1.1/admin or attacker.com. Disabling redirects keeps the
                # boundary the URL-string check declared.
                resp = requests.post(
                    proxy_url,
                    json={},
                    timeout=timeout_s,
                    headers={"User-Agent": f"fula-ble-proxy/{plugin_id}"},
                    allow_redirects=False,
                )
            except requests.Timeout:
                return {"error": "plugin_timeout", "plugin": plugin_id, "command": name}
            except requests.ConnectionError:
                return {"error": "plugin_unreachable", "plugin": plugin_id, "command": name}
            except requests.RequestException as e:
                return {"error": "plugin_request_failed", "plugin": plugin_id, "command": name, "detail": str(e)}

            if not (200 <= resp.status_code < 300):
                return {
                    "error": "plugin_http_error",
                    "plugin": plugin_id,
                    "command": name,
                    "status_code": resp.status_code,
                }
            try:
                return resp.json()
            except ValueError:
                return {
                    "error": "plugin_invalid_json",
                    "plugin": plugin_id,
                    "command": name,
                    "body_preview": resp.text[:200],
                }

        return _handler

    def get_logs(self, params):
        try:
            result = {}
            data = json.loads(params)
            
            # Handle docker logs
            docker_logs = {}
            for container in data.get('docker', []):
                if container:
                    cmd = f"sudo docker logs {container} --tail 6"
                    try:
                        # Capture both stdout and stderr
                        output = subprocess.check_output(
                            cmd,
                            shell=True,
                            stderr=subprocess.STDOUT,  # Redirect stderr to stdout
                            universal_newlines=True    # Handle text output properly
                        )
                        docker_logs[container] = output if output else "No logs available"
                    except subprocess.CalledProcessError as e:
                        docker_logs[container] = f"Error: {str(e)}"
            result['docker'] = docker_logs

            # Handle system commands
            system_logs = {}
            for cmd in data.get('system', []):
                if cmd in self.commands:
                    try:
                        if callable(self.commands[cmd]):
                            output = self.commands[cmd]()
                        else:
                            output = subprocess.check_output(
                                self.commands[cmd],
                                shell=True
                            ).decode('utf-8')
                        system_logs[cmd] = output
                    except Exception as e:
                        system_logs[cmd] = f"Error: {str(e)}"
            result['system'] = system_logs

            # Handle exec commands
            exec_logs = {}
            for cmd in data.get('exec', []):
                print(f"[get_logs] exec cmd='{cmd}', known={cmd in self.exec_commands}, available={list(self.exec_commands.keys())}")
                if cmd in self.exec_commands:
                    try:
                        if callable(self.exec_commands[cmd]):
                            output = self.exec_commands[cmd]()
                        else:
                            output = subprocess.check_output(
                                self.exec_commands[cmd],
                                shell=True
                            ).decode('utf-8')
                        exec_logs[cmd] = output
                    except Exception as e:
                        exec_logs[cmd] = f"Error: {str(e)}"
            result['exec'] = exec_logs

            return result
            
        except Exception as e:
            return {"error": f"Failed to get logs: {str(e)}"}