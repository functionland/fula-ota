#!/usr/bin/python3

"""Copyright (c) 2019, Douglas Otwell

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

Modified By Ehsan shariati-Functionland Inc
"""

import json
import queue
import traceback
import dbus

import os
import pexpect
import psutil
import subprocess
import time
import threading
from go_server_client import GoServerClient
from local_command_server import LocalCommandServer
from dbus.exceptions import DBusException

from advertisement import Advertisement
from service import Application, Service, Characteristic, Descriptor

import signal
import sys

def signal_handler(sig, frame):
    print('Gracefully shutting down...')
    connect_ongoing.clear()
    app.quit()
    kill_bluetooth_processes()
    sys.exit(0)

# Flag to indicate whether an action is ongoing
action_ongoing = threading.Event()
connect_ongoing = threading.Event()

GATT_CHRC_IFACE = "org.bluez.GattCharacteristic1"
NOTIFY_TIMEOUT = 25000

os.environ["DBUS_TIMEOUT"] = "999"

def get_kubo_peer_id():
    """Get kubo peer ID from kubo API, falling back to config file."""
    # Method 1: query kubo API
    try:
        import urllib.request
        req = urllib.request.Request(
            'http://127.0.0.1:5001/api/v0/id',
            method='POST'
        )
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode('utf-8'))
            peer_id = data.get('ID', '')
            if peer_id:
                return peer_id
    except Exception:
        pass

    # Method 2: read from kubo config file
    try:
        output = subprocess.check_output(
            ['sudo', 'cat', '/home/pi/.internal/ipfs_data/config'],
            timeout=5
        ).decode('utf-8').strip()
        data = json.loads(output)
        peer_id = data.get('Identity', {}).get('PeerID', '')
        if peer_id:
            return peer_id
    except Exception:
        pass

    return ''

def get_bluetooth_name():
    peer_id = get_kubo_peer_id()
    if len(peer_id) >= 5:
        return f"fulatower_{peer_id[-5:]}"
    return "fulatower_NEW"

class FulatowerAdvertisement(Advertisement):
    def __init__(self, index):
        Advertisement.__init__(self, index, "peripheral")
        bt_name = get_bluetooth_name()
        self.add_local_name(bt_name)
        self.include_tx_power = True
        print(f"Bluetooth name: {bt_name}")
        print(f"Advertising service: {FulatowerService.FULATOWERSERVICE_SVC_UUID}")

class FulatowerService(Service):
    FULATOWERSERVICE_SVC_UUID = "00000001-710e-4a5b-8d75-3e5b444bc3cf"

    def __init__(self, index):
        self.lastCommand = ""

        Service.__init__(self, index, self.FULATOWERSERVICE_SVC_UUID, True)
        print(f"Initializing service with UUID: {self.FULATOWERSERVICE_SVC_UUID}")
        self.broadcast_char = BroadcastCharacteristic(self)
        self.command_char = CommandCharacteristic(self)
        self.add_characteristic(self.broadcast_char)
        self.add_characteristic(self.command_char)
        print("Characteristics added to service")

    def get_lastCommand(self):
        return self.lastCommand

    def set_lastCommand(self, command):
        self.lastCommand = command


class BLEResponseHandler:
    def __init__(self, mtu_size=512):
        self.mtu_size = mtu_size - 3  # Account for BLE overhead
        self.chunks = []
        self.current_chunk_index = 0

    def prepare_response(self, response):
        """Prepare response by splitting into chunks"""
        json_str = json.dumps(response)
        self.chunks = []

        total_length = len(json_str)

        # Build data chunks with actual size verification.
        # JSON escaping of data content (quotes, backslashes, newlines) makes
        # the serialized chunk larger than the raw substring, so we verify the
        # real encoded size and shrink per-chunk if needed.
        # Use 2x safety margin to account for worst-case double-escaping.
        base_overhead = len(json.dumps({"type": "ble_chunk", "index": 999, "data": ""}))
        initial_data_size = (self.mtu_size - base_overhead) // 2

        pos = 0
        data_chunks = []
        while pos < total_length:
            size = min(initial_data_size, total_length - pos)
            while size > 0:
                chunk_data = json_str[pos:pos + size]
                chunk = {
                    "type": "ble_chunk",
                    "index": len(data_chunks) + 1,
                    "data": chunk_data
                }
                chunk_json = json.dumps(chunk)
                if len(chunk_json) <= self.mtu_size:
                    data_chunks.append(chunk)
                    pos += size
                    break
                # JSON escaping made it too big; shrink and retry
                overage = len(chunk_json) - self.mtu_size
                size = max(1, size - max(1, overage))
            else:
                raise ValueError(f"Cannot fit data into MTU {self.mtu_size}")

        # Add header
        header = {
            "type": "ble_header",
            "total_length": total_length,
            "chunks": len(data_chunks)
        }
        header_json = json.dumps(header)
        if len(header_json) > self.mtu_size:
            raise ValueError(f"Header size {len(header_json)} exceeds MTU {self.mtu_size}")

        self.chunks = [header] + data_chunks
        self.current_chunk_index = 0
        return len(self.chunks)

    def get_next_chunk(self):
        """Get next chunk of data"""
        if self.current_chunk_index < len(self.chunks):
            chunk = self.chunks[self.current_chunk_index]
            self.current_chunk_index += 1
            return chunk
        return None

class BroadcastCharacteristic(Characteristic):
    BROADCAST_CHARACTERISTIC_UUID = "00000002-710e-4a5b-8d75-3e5b444bc3cf"

    def __init__(self, service):
        self.notifying = False

        Characteristic.__init__(
                self, self.BROADCAST_CHARACTERISTIC_UUID,
                ["notify", "read"], service)
        self.add_descriptor(BroadcastDescriptor(self))

    def get_information(self):
        value = []
        strtemp = "placeholder"
        for c in strtemp:
            value.append(dbus.Byte(c.encode()))

        return value

    def set_information_callback(self):
        if self.notifying:
            value = self.get_information()
            self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": value}, [])

        return self.notifying

    def StartNotify(self):
        if self.notifying:
            return

        self.notifying = True

        value = self.get_temperature()
        self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": value}, [])
        self.add_timeout(NOTIFY_TIMEOUT, self.set_information_callback)

    def StopNotify(self):
        self.notifying = False

    def ReadValue(self, options):
        value = self.get_information()

        return value

class BroadcastDescriptor(Descriptor):
    TEMP_DESCRIPTOR_UUID = "00000003-710e-4a5b-8d75-3e5b444bc3cf"
    TEMP_DESCRIPTOR_VALUE = "Broadcast Information"

    def __init__(self, characteristic):
        Descriptor.__init__(
                self, self.TEMP_DESCRIPTOR_UUID,
                ["read"],
                characteristic)

    def ReadValue(self, options):
        value = []
        desc = self.TEMP_DESCRIPTOR_VALUE

        for c in desc:
            value.append(dbus.Byte(c.encode()))

        return value
    
class CommandCharacteristic(Characteristic):
    COMMAND_CHARACTERISTIC_UUID = "00000003-710e-4a5b-8d75-3e5b444bc3cf"

    def __init__(self, service):
        self.response_handler = BLEResponseHandler()
        self.go_client = GoServerClient()
        self.local_server = LocalCommandServer()
        self.notifying = False
        self.indicating = False
        self.response_queue = queue.Queue()
        Characteristic.__init__(
                self, self.COMMAND_CHARACTERISTIC_UUID,
                ["read", "write", "notify", "indicate"], service)
        self.add_descriptor(CommandDescriptor(self))
        self._start_response_handler()
    
    def _start_response_handler(self):
        def handle_responses():
            while True:
                try:
                    response = self.response_queue.get()
                    if self.notifying:
                        self.notify_response(response)
                    if self.indicating:
                        self.indicate_response(response)
                except Exception as e:
                    print(f"Error handling response: {e}")
                    traceback.print_exc()

        thread = threading.Thread(target=handle_responses, daemon=True)
        thread.start()

    def send_chunked_response(self, response, is_notification=True):
        """Send response in chunks"""
        try:
            chunks_count = self.response_handler.prepare_response(response)
            print(f"Info: chunks_count: {chunks_count}")
            def send_chunks():
                for i in range(chunks_count):
                    chunk = self.response_handler.get_next_chunk()
                    if chunk is None:
                        print(f"Warning: Expected chunk {i} of {chunks_count} but got None")
                        break
                    
                    value = []
                    chunk_str = json.dumps(chunk)
                    for c in chunk_str:
                        value.append(dbus.Byte(c.encode()))
                    
                    value = dbus.Array(value, signature='y')
                    print(f"Sending chunk {i+1} of {chunks_count}: {chunk_str}")
                    
                    self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": value}, [])
                    time.sleep(0.1)  # Small delay between chunks
                    
            # Start sending chunks in a separate thread
            thread = threading.Thread(target=send_chunks)
            thread.daemon = True
            thread.start()
            
        except Exception as e:
            print(f"Error sending chunked response: {str(e)}")
            traceback.print_exc()

    def handle_connection(self):
        """Handle device connection"""
        try:
            print("Device connected to BLE")
            led_path = "/usr/bin/fula/control_led.py"
            if os.path.exists(led_path):
                subprocess.run(["sudo", "python", led_path, "yellow", "5"])
            else:
                print(f"LED control script not found at {led_path}")
        except Exception as e:
            print(f"Error handling connection: {str(e)}")
            traceback.print_exc()

    def notify_response(self, response):
        """Send response back to client via notification"""
        try:
            if not self.notifying:
                self.StartNotify()
            
            # Handle both success and error responses
            response_str = json.dumps(response) if isinstance(response, (dict, list)) else str(response)
            
            if len(response_str) > 512:  # MTU threshold
                self.send_chunked_response(response, is_notification=True)
            else:
                value = []
                for c in response_str:
                    value.append(dbus.Byte(c.encode()))
                value = dbus.Array(value, signature='y')
                self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": value}, [])
                print(f"Notification sent: {response_str}")
                
            self.service.set_lastCommand(response_str)
            
        except Exception as e:
            print(f"Error sending notification: {str(e)}")
            traceback.print_exc()
            # Send error response without breaking the connection
            error_response = {"error": str(e), "status": "error"}
            try:
                error_str = json.dumps(error_response)
                value = dbus.Array([dbus.Byte(c.encode()) for c in error_str], signature='y')
                self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": value}, [])
                self.service.set_lastCommand(error_str)
            except:
                print("Failed to send error notification")

    def indicate_response(self, response):
        """Send response back to client via indication"""
        try:
            if not self.indicating:
                return
            
            # Check if response needs chunking
            response_str = json.dumps(response) if isinstance(response, (dict, list)) else str(response)
            if len(response_str) > 512:  # MTU threshold
                self.send_chunked_response(response, is_notification=False)
            else:
                # Original single-chunk indication logic
                value = []
                for c in response_str:
                    value.append(dbus.Byte(c.encode()))
                value = dbus.Array(value, signature='y')
                print(f"Sending indication: {response_str}")
                self.PropertiesChanged(GATT_CHRC_IFACE, {"Value": value}, [])
                
        except Exception as e:
            print(f"Error sending indication: {str(e)}")
            traceback.print_exc()

    def StartIndicate(self):
        print("Starting indications")
        self.indicating = True

    def StopIndicate(self):
        print("Stopping indications")
        self.indicating = False

    def WriteValue(self, value, options):
        try:
            print(f"Received raw value: {value}")
            command = "".join([chr(b) for b in value])
            val = str(command).strip()
            print(f"Decoded command: {command}")
            print(f"Processed value: {val}")
            self.service.set_lastCommand("Processing " + val)
            print(f"command received {val}")

            # Handle long-running commands in a separate thread
            if any(val.startswith(cmd) for cmd in ["wifi/list", "peer/exchange", "peer/generate-identity", "wifi/connect", "log", "wireguard/start", "forceupdate"]):
                print("command is long-processing")
                thread = threading.Thread(target=self._handle_long_command, args=(val,))
                thread.daemon = True
                thread.start()
            else:
                # Handle quick commands directly
                self._handle_command(val)
                
        except Exception as e:
            print(f"Error in WriteValue: {str(e)}")
            import traceback
            traceback.print_exc()

    def _handle_long_command(self, val):
        """Handle long-running commands and send periodic updates"""
        try:
            # Send updates every 2 seconds to keep connection alive
            def send_progress():
                while not command_complete.is_set():
                    self.service.set_lastCommand("Processing " + val)
                    time.sleep(2)

            command_complete = threading.Event()
            progress_thread = threading.Thread(target=send_progress)
            progress_thread.daemon = True
            progress_thread.start()

            # Execute the actual command
            response = self._handle_command(val)

            # Signal completion and update final result
            command_complete.set()
            if response:
                self.service.set_lastCommand(json.dumps(response))

        except Exception as e:
            print(f"Error in long command: {str(e)}")
            self.service.set_lastCommand("Error: " + str(e))
            
    def _handle_command(self, val):
        response = None
        """Handle long-running commands and send periodic updates"""
        try:
            if val == "reset":
                print(f"reset is received: {val}")
                with open('/home/pi/reset.txt', 'w') as f:
                    # This file is being created so that the existence of it can be checked later.
                    pass
                subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '20'])
                # Create a thread to handle reset after 20 seconds
                self.reset_timer = threading.Timer(20.0, self.reset_procedure)
                self.reset_timer.start()
            elif val == "cancel":
                print(f"cancel is received: {val}")
                if os.path.exists('/home/pi/reset.txt'):
                    os.remove('/home/pi/reset.txt')
                subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '-1'])
                self.kill_led_processes()
                # Cancel the reset timer if it's running
                if self.reset_timer is not None:
                    self.reset_timer.cancel()
            elif val == "removedockercpblock":
                print(f"removedockercpblock is received: {val}")
                if os.path.exists('/home/pi/stop_docker_copy.txt'):
                    os.remove('/home/pi/stop_docker_copy.txt')
            elif val == "stopleds":
                print(f"stopleds is received: {val}")
                subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '-1'])
                self.kill_led_processes()
                    
            elif val == "wifi/list":
                response = self.go_client.list_wifi()
                print(f"WiFi list: {response}")
                
            elif val == "wifi/status":
                response = self.go_client.wifi_status()
                print(f"WiFi status: {response}")
            
            elif val == "properties":
                response = self.go_client.properties()
                print(f"Properties: {response}")
                
            elif val.startswith("wifi/connect "):
                parts = val.split(" ")
                if len(parts) == 4:  # Check for all parameters including country code
                    ssid = parts[1]
                    password = parts[2]
                    country_code = parts[3]
                    response = self.go_client.connect_wifi(ssid, password, country_code)
                    print(f"WiFi connection response: {response}")
                elif len(parts) == 3:  # Backward compatibility without country code
                    ssid = parts[1]
                    password = parts[2]
                    response = self.go_client.connect_wifi(ssid, password)
                    print(f"WiFi connection response: {response}")
                    
            elif val.startswith("peer/exchange "):
                parts = val.split(" ")
                if len(parts) == 3:
                    peer_id = parts[1]
                    seed = parts[2]
                    response = self.go_client.exchange_peers(peer_id, seed)
                    print(f"Peer exchange response: {response}")
                    
            elif val.startswith("peer/generate-identity "):
                parts = val.split(" ")
                if len(parts) == 2:
                    seed = parts[1]
                    response = self.go_client.generate_identity(seed)
                    print(f"Identity generation response: {response}")
                    
            elif val == "ap/enable":
                response = self.go_client.enable_access_point()
                print(f"AP enable response: {response}")
                    
            elif val == "partition":
                response = self.go_client.partition()
                print(f"Partition response: {response}")
                    
            elif val == "readiness":
                response = self.go_client.readiness()
                print(f"Readiness response: {response}")
            elif val.startswith("logs "):
                # Extract the JSON parameters after "logs "
                params = val[5:]  # Skip "logs " prefix
                response = self.local_server.get_logs(params)
                print(f"Logs response: {response}")

            elif val == "wireguard/start":
                try:
                    result = subprocess.run(
                        ["sudo", "systemctl", "start", "wireguard-support.service"],
                        capture_output=True, text=True, timeout=60
                    )
                    status_result = subprocess.run(
                        ["bash", "/usr/bin/fula/wireguard/status.sh"],
                        capture_output=True, text=True, timeout=10
                    )
                    response = json.loads(status_result.stdout) if status_result.returncode == 0 else {"status": "started", "returncode": result.returncode}
                except Exception as e:
                    response = {"error": str(e)}
                print(f"WireGuard start response: {response}")

            elif val == "wireguard/stop":
                try:
                    subprocess.run(
                        ["sudo", "systemctl", "stop", "wireguard-support.service"],
                        capture_output=True, text=True, timeout=30
                    )
                    response = {"status": "stopped"}
                except Exception as e:
                    response = {"error": str(e)}
                print(f"WireGuard stop response: {response}")

            elif val == "wireguard/status":
                try:
                    result = subprocess.run(
                        ["bash", "/usr/bin/fula/wireguard/status.sh"],
                        capture_output=True, text=True, timeout=10
                    )
                    response = json.loads(result.stdout) if result.returncode == 0 else {"error": "status check failed"}
                except Exception as e:
                    response = {"error": str(e)}
                print(f"WireGuard status response: {response}")

            elif val == "forceupdate":
                try:
                    # Kill any existing LED processes and set purple during update
                    subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                                   capture_output=True, timeout=5)
                    subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'light_purple', '999999'])

                    # Run fula.sh update (pulls latest Docker images)
                    result = subprocess.run(
                        ['sudo', 'bash', '/usr/bin/fula/fula.sh', 'update'],
                        capture_output=True, text=True, timeout=600
                    )

                    # Kill purple LED, show yellow for 10 seconds
                    subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                                   capture_output=True, timeout=5)
                    subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'yellow', '10'])

                    if result.returncode == 0:
                        response = {"status": "updated", "msg": "Docker images pulled successfully"}
                    else:
                        response = {"status": "error", "msg": result.stderr[-500:] if result.stderr else "Update failed"}
                except subprocess.TimeoutExpired:
                    subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                                   capture_output=True, timeout=5)
                    subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'yellow', '10'])
                    response = {"status": "timeout", "msg": "Update timed out after 10 minutes"}
                except Exception as e:
                    subprocess.run(['sudo', 'pkill', '-f', 'control_led.py'],
                                   capture_output=True, timeout=5)
                    response = {"error": str(e)}
                print(f"Force update response: {response}")

            if response:
                # Try both notification and indication
                if self.notifying:
                    self.notify_response(response)
                if self.indicating:
                    self.indicate_response(response)
                
                # Always update the value for read operations
                self.service.set_lastCommand(json.dumps(response))
                
            return response

        except Exception as e:
            error_response = {"error": str(e)}
            if self.notifying:
                self.notify_response(error_response)
            if self.indicating:
                self.indicate_response(error_response)
            raise

    def StartNotify(self):
        if self.notifying:
            return
        self.notifying = True

    def StopNotify(self):
        self.notifying = False

    def reset_procedure(self):
        print("reset_precedure started")
        # Indicate that an action is ongoing
        action_ongoing.set()
        if os.path.exists('/home/pi/reset.txt'):
            os.remove('/home/pi/reset.txt')
            self.remove_wifi_connections()
            subprocess.call(['sudo', 'rm', '-f', '/home/pi/.internal/config.yaml', '/home/pi/.internal/config.yaml.backup'])
            subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '-1'])
            self.kill_led_processes()
            subprocess.call(['sudo', 'reboot'])
        # Indicate that the action has finished
        action_ongoing.clear()
        print("reset_precedure finished")

    def ReadValue(self, options):
        value = []
        val = self.service.get_lastCommand()
        value.append(dbus.Byte(val.encode()))

        return value

    def remove_wifi_connections(self):
        print("remove_wifi_connections started")
        wifi_connections = subprocess.check_output(['nmcli', 'con', 'show']).decode().split('\n')
        wifi_connections = [conn.split()[0] for conn in wifi_connections if 'wifi' in conn]

        for conn in wifi_connections:
            print(f"Removing Wi-Fi connection: {conn}")
            subprocess.call(['sudo', 'nmcli', 'con', 'delete', conn])
        print("remove_wifi_connections finished")

class CommandDescriptor(Descriptor):
    CCCD_UUID = "2902"

    def __init__(self, characteristic):
        Descriptor.__init__(
                self, self.CCCD_UUID,
                ["read", "write"],
                characteristic)
        self.value = [0, 0]

    def WriteValue(self, value, options):
        print("CommandDescriptor")
        if value:
            self.value = value
            if self.value[0] & 0x01:  # Notifications
                self.characteristic.StartNotify()
            else:
                self.characteristic.StopNotify()
            if self.value[0] & 0x02:  # Indications
                self.characteristic.StartIndicate()
            else:
                self.characteristic.StopIndicate()

    def ReadValue(self, options):
        return self.value


def register_bluetooth_service(max_retries=10, initial_delay=5):
    """
    Register the Bluetooth service with exponential backoff retry logic
    """
    for attempt in range(max_retries):
        try:
            app = Application()
            service = FulatowerService(0)
            app.add_service(service)
            print(f"Attempt {attempt + 1}/{max_retries}: Registering service...")
            app.register()
            print("Service registered successfully")
            return app, service
        except DBusException as e:
            delay = initial_delay * (2 ** attempt)  # Exponential backoff
            print(f"DBus error during registration: {e}")
            if attempt < max_retries - 1:
                print(f"Retrying in {delay} seconds... (Attempt {attempt + 1}/{max_retries})")
                time.sleep(delay)
            else:
                print("Failed to register service after all attempts")
                sys.exit(1)
        except Exception as e:
            print(f"Fatal error during registration: {e}")
            sys.exit(1)

# Usage
app = None
service = None
try:
    app, service = register_bluetooth_service()
    print("Bluetooth service started successfully")
except SystemExit:
    sys.exit(1)


print("Registering advertisement...")
adv = FulatowerAdvertisement(0)
adv.register()
print("Advertisement registered successfully")

def kill_bluetooth_processes():
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            # check whether the process command line matches
            if proc.info['cmdline'] and 'bluetooth.py' in ' '.join(proc.info['cmdline']):
                proc.kill()  # kill the process

def setup_bluetooth():
    print("bluetooth setup started")
    child = pexpect.spawn('bluetoothctl')
    child.sendline('power on')
    time.sleep(1)
    child.sendline('discoverable on')
    time.sleep(1)
    child.sendline('pairable on')
    time.sleep(1)
    child.sendline('agent NoInputNoOutput')
    time.sleep(1)
    child.sendline('default-agent')
    time.sleep(1)
    print("Bluetooth setup finished")

    while connect_ongoing.is_set():
        try:
            child.expect(r'\[agent\] Confirm passkey', timeout=240)
            child.sendline('yes')
        except pexpect.TIMEOUT:
            pass
        except pexpect.EOF:
            break

# Create a new thread for setup_bluetooth()
signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

# Create a new thread for setup_bluetooth()
connect_ongoing.set()
setup_thread = threading.Thread(target=setup_bluetooth)
setup_thread.start()

# Start server in a new thread
def start_server():
    try:
        app.run()
    except KeyboardInterrupt:
        app.quit()

server_thread = threading.Thread(target=start_server)
server_thread.start()

# Instead of sleep, use infinite loop
print("Server running. Press Ctrl+C to exit.")
try:
    while True:
        time.sleep(1)
except KeyboardInterrupt:
    signal_handler(signal.SIGINT, None)