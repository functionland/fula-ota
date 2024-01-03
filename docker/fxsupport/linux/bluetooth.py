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

import dbus

import os
import pexpect
import psutil
import subprocess
import time
import threading

from advertisement import Advertisement
from service import Application, Service, Characteristic, Descriptor

# Flag to indicate whether an action is ongoing
action_ongoing = threading.Event()
connect_ongoing = threading.Event()

GATT_CHRC_IFACE = "org.bluez.GattCharacteristic1"
NOTIFY_TIMEOUT = 5000

os.environ["DBUS_TIMEOUT"] = "999"
class FulatowerAdvertisement(Advertisement):
    def __init__(self, index):
        Advertisement.__init__(self, index, "peripheral")
        self.add_local_name("fulatower")
        self.include_tx_power = True

class FulatowerService(Service):
    FULATOWERSERVICE_SVC_UUID = "00000001-710e-4a5b-8d75-3e5b444bc3cf"

    def __init__(self, index):
        self.lastCommand = ""

        Service.__init__(self, index, self.FULATOWERSERVICE_SVC_UUID, True)
        self.add_characteristic(BroadcastCharacteristic(self))
        self.add_characteristic(CommandCharacteristic(self))

    def get_lastCommand(self):
        return self.lastCommand

    def set_lastCommand(self, command):
        self.lastCommand = command

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
    TEMP_DESCRIPTOR_UUID = "2901"
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
        Characteristic.__init__(
                self, self.COMMAND_CHARACTERISTIC_UUID,
                ["read", "write"], service)
        self.add_descriptor(CommandDescriptor(self))
        self.reset_timer = None

    def kill_led_processes(self):
        for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
            # check whether the process command line matches
            if proc.info['cmdline'] and 'control_led.py' in ' '.join(proc.info['cmdline']):
                proc.kill()  # kill the process

    def WriteValue(self, value, options):
        command = "".join([chr(b) for b in value])
        val = str(command).lower().strip()
        self.service.set_lastCommand(val)
        print(f"command received {val}")
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
        elif val.startswith("connect "):
            parts = val.split(" ")
            if len(parts) == 3:
                ssid = parts[1]
                password = parts[2]
                print(f"Connect command received with SSID: {ssid} and PASSWORD: {password}")
                self.create_and_connect_wifi(ssid, password)

    def reset_procedure(self):
        print("reset_precedure started")
        # Indicate that an action is ongoing
        action_ongoing.set()
        if os.path.exists('/home/pi/reset.txt'):
            os.remove('/home/pi/reset.txt')
            self.remove_wifi_connections()
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

    def create_and_connect_wifi(self, ssid, password):
        print("create_and_connect_wifi started")
        action_ongoing.set()
        subprocess.call(['sudo', 'nmcli', 'con', 'add', 'type', 'wifi', 'ifname', '*', 'con-name', ssid, 'ssid', ssid])
        subprocess.call(['sudo', 'nmcli', 'con', 'modify', ssid, 'wifi-sec.key-mgmt', 'wpa-psk', 'wifi-sec.psk', password])
        subprocess.call(['sudo', 'nmcli', 'con', 'up', ssid])
        action_ongoing.clear()
        print("create_and_connect_wifi finished")

    def remove_wifi_connections(self):
        print("remove_wifi_connections started")
        wifi_connections = subprocess.check_output(['nmcli', 'con', 'show']).decode().split('\n')
        wifi_connections = [conn.split()[0] for conn in wifi_connections if 'wifi' in conn]

        for conn in wifi_connections:
            print(f"Removing Wi-Fi connection: {conn}")
            subprocess.call(['sudo', 'nmcli', 'con', 'delete', conn])
        print("remove_wifi_connections finished")

class CommandDescriptor(Descriptor):
    COMMAND_DESCRIPTOR_UUID = "2901"
    COMMAND_DESCRIPTOR_VALUE = "Command from client"

    def __init__(self, characteristic):
        Descriptor.__init__(
                self, self.COMMAND_DESCRIPTOR_UUID,
                ["read"],
                characteristic)

    def ReadValue(self, options):
        value = []
        desc = self.COMMAND_DESCRIPTOR_VALUE

        for c in desc:
            value.append(dbus.Byte(c.encode()))

        return value

app = Application()
app.add_service(FulatowerService(0))
app.register()

adv = FulatowerAdvertisement(0)
adv.register()

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
            child.expect('\[agent\] Confirm passkey', timeout=240)
            child.sendline('yes')
        except pexpect.TIMEOUT:
            pass
        except pexpect.EOF:
            break

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

# Main thread sleeps for 900 seconds then stops server
time.sleep(900)
# If an action is ongoing, wait until it is finished
action_ongoing.wait()

connect_ongoing.clear()

print("900 seconds have passed. Turning off Bluetooth GATT server and stopping the script...")
app.stop()
server_thread.join()
kill_bluetooth_processes()