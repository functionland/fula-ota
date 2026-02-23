import json
import subprocess


class LocalCommandServer:
    def __init__(self):
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
            subprocess.check_call(['sudo', 'rm', '-f', '/home/pi/.internal/config.yaml'])
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