#!/usr/bin/env python3

from time import sleep
import time
import subprocess
import os

def run_command(command):
    """Runs a command and returns the output."""
    try:
        return subprocess.run(command, capture_output=True, text=True, shell=True).stdout
    except subprocess.CalledProcessError as e:
        return e.output

# Check if script is run as root
if os.getuid() != 0:
    print("This script must be run as root")
    subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '5'])
    exit(1)

if not os.path.isdir("/sys/module/rockchipdrm"):
    print("Not Running on RockChip")
    import RPi.GPIO as GPIO

    # echo python ~/hw_test.py >> ~/.bashrc

    led_r_pin = 24
    led_b_pin = 16
    led_g_pin = 12

    # setup LEDs
    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)

    GPIO.setup(led_r_pin, GPIO.OUT)
    GPIO.setup(led_b_pin, GPIO.OUT)
    GPIO.setup(led_g_pin, GPIO.OUT)

    # LEDs are active low. So, set high for turning off
    GPIO.output(led_r_pin, GPIO.HIGH)
    GPIO.output(led_g_pin, GPIO.HIGH)
    GPIO.output(led_b_pin, GPIO.HIGH)

    print("Start testing hardware")

    # testing VL805
    out = run_command("lsusb")
    if "VIA Labs" not in out:
        subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '3'])
        raise Exception("VL805 USB-to-Ethernet controller not found")

    print("Hardware OK")
    GPIO.output(led_g_pin, GPIO.LOW)
    time.sleep(5)
    GPIO.output(led_g_pin, GPIO.HIGH)

else:
    print("Running on RockChip")

    # Test General Hardware
    print("Testing General Hardware:")
    hw_output = run_command("lshw")
    if not hw_output:
        subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '3'])
        raise Exception("General hardware not found")
    print(hw_output)
    print("Waiting for 1 second...")
    subprocess.run(["sleep", "1"])

    # Test WiFi Module
    print("Testing WiFi Module:")
    # Keep checking for WiFi module every second until it's ready or until we've waited too long
    timeout = time.time() + 60*1  # Maximum of 1 minute wait time
    wifi_found = False
    
    while True:
        # Check for WiFi interfaces using multiple methods for better compatibility
        # Method 1: Check iwconfig for any wireless interface
        wifi_iwconfig = run_command("iwconfig 2>/dev/null | grep -E '(IEEE 802.11|ESSID|wireless)'")
        
        # Method 2: Check ip link for wireless interfaces
        wifi_ip_link = run_command("ip link show | grep -E '(wlan|wl[a-zA-Z0-9]+)'")
        
        # Method 3: Check /sys/class/net for wireless interfaces
        wifi_sys_net = run_command("find /sys/class/net -name 'wireless' -type d 2>/dev/null | head -1")
        
        # Method 4: Check nmcli for WiFi devices
        wifi_nmcli = run_command("nmcli device status 2>/dev/null | grep wifi")
        
        if wifi_iwconfig or wifi_ip_link or wifi_sys_net or wifi_nmcli:
            print("WiFi module detected:")
            if wifi_iwconfig:
                print(f"iwconfig output: {wifi_iwconfig[:200]}...")  # Truncate long output
            if wifi_nmcli:
                print(f"nmcli output: {wifi_nmcli}")
            wifi_found = True
            break
        elif time.time() > timeout:
            print("No WiFi Module Found. Waited for 1 minute.")
            print("Checked iwconfig, ip link, /sys/class/net, and nmcli")
            subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '5'])
            raise Exception("WiFi module not found")
        
        print("Waiting for 1 second...")
        time.sleep(1)  # Wait for a second before checking again

    # Test USB Ports
    print("Testing USB Ports:")
    lsusb_output = run_command("lsusb")
    if "Terminus" not in lsusb_output:
        subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '3'])
        raise Exception("USB ports not found")
    print(lsusb_output)
    print("Waiting for 1 seconds...")
    subprocess.run(["sleep", "1"])

    # Test Bluetooth Module
    print("Testing Bluetooth Module:")
    bluetooth_output = run_command("echo 'list' | bluetoothctl")
    if "Controller" not in bluetooth_output:
        subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '3'])
        raise Exception("Bluetooth module not found")
    print(bluetooth_output)
    print("Waiting for 1 second...")
    subprocess.run(["sleep", "1"])

    print("All tests passed")
    subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'green', '3'])
    exit(0)

