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
            'partition': 'sudo touch ~/commands/.command_partition',
            'node_delete': 'sudo rm -rf /uniondrive/chain/chains/functionyard/db/full/*',
            'ipfs_delete': 'sudo rm -rf /uniondrive/ipfs_datastore/blocks/*',
            'restart_fula': 'sudo systemctl restart fula',
            'restart_uniondrive': self._restart_services,
            'hotspot': 'sudo nmcli con up FxBlox',
            'reset': self._reset_system
        }

    def _combine_ls_outputs(self):
        commands = [
            'ls ~/ -al',
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
            ps_output = subprocess.check_output('sudo docker ps -a', shell=True).decode('utf-8')
            images_output = subprocess.check_output('sudo docker images', shell=True).decode('utf-8')
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
            subprocess.check_call('sudo rm ~/.internal/config.yaml', shell=True)
            subprocess.check_call('sudo reboot', shell=True)
            return "System reset initiated"
        except subprocess.CalledProcessError as e:
            return f"Error: {str(e)}"

    def get_logs(self, params):
        try:
            result = {}
            data = json.loads(params)
            
            # Handle docker logs
            docker_logs = {}
            for container in data.get('docker', []):
                if container:
                    cmd = f"sudo docker logs {container} --tail 5"
                    try:
                        output = subprocess.check_output(cmd, shell=True).decode('utf-8')
                        docker_logs[container] = output
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
                    except subprocess.CalledProcessError as e:
                        system_logs[cmd] = f"Error: {str(e)}"
            result['system'] = system_logs

            # Handle exec commands
            exec_logs = {}
            for cmd in data.get('exec', []):
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
                    except subprocess.CalledProcessError as e:
                        exec_logs[cmd] = f"Error: {str(e)}"
            result['exec'] = exec_logs

            return result
            
        except Exception as e:
            return {"error": f"Failed to get logs: {str(e)}"}