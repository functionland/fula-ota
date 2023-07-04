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
    wifi_modules_output = run_command("iwconfig 2>&1 | grep -B 1 '802.11'")
    if not wifi_modules_output:
        subprocess.Popen(['python', '/usr/bin/fula/control_led.py', 'red', '3'])
        raise Exception("WiFi module not found")
    print(wifi_modules_output)
    print("Waiting for 1 second...")
    subprocess.run(["sleep", "1"])

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

