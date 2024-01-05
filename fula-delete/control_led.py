import os
import time
import argparse
import logging
import psutil
import subprocess

def kill_led_processes_except_self():
    current_pid = os.getpid()
    for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
        # Exclude current process from being killed
        if proc.info['pid'] != current_pid and proc.info['cmdline'] and 'control_led.py' in ' '.join(proc.info['cmdline']):
            proc.kill()  # kill the process

if os.path.exists("/sys/module/rockchipdrm"):
    led_r_pin="red"
    led_b_pin="blue"
    led_g_pin="green"
else:
    import RPi.GPIO as GPIO
    led_r_pin=24
    led_b_pin=16
    led_g_pin=12
    GPIO.setmode(GPIO.BCM)
    GPIO.setwarnings(False)
    GPIO.setup(led_r_pin, GPIO.OUT)
    GPIO.setup(led_b_pin, GPIO.OUT)
    GPIO.setup(led_g_pin, GPIO.OUT)

# function to control individual LED
def individual_led_control(color, state):
    if os.path.exists("/sys/module/rockchipdrm"):
        subprocess.call([f'echo {state} | sudo tee /sys/class/leds/led_{color}/brightness'], shell=True)
    else:
        GPIO.output({"red": led_r_pin, "green": led_g_pin, "blue": led_b_pin}.get(color), GPIO.HIGH if state else GPIO.LOW)

#setup logging
logging.basicConfig(filename='/home/pi/fula.sh.log', filemode='a', level=logging.INFO, format='%(asctime)s %(message)s')

# Create a parser for command line arguments
parser = argparse.ArgumentParser(description='Control LEDs.')
parser.add_argument('color', type=str, help='LED color (red, green, or blue).')
parser.add_argument('time', type=int, help='Time to flash the LED.')

args = parser.parse_args()
logging.info(f'{args.color} and {args.time} was received.')

led_pin = {"red": led_r_pin, "green": led_g_pin, "blue": led_b_pin}.get(args.color)

try:
    # if time is -1, stop all flashing by setting all to 1
    if args.time == -1:
        individual_led_control('red', 1)
        individual_led_control('green', 1)
        individual_led_control('blue', 1)
        logging.info('All LEDs were turned off by -1.')
        kill_led_processes_except_self()
    else:
        # flash the LED
        individual_led_control(args.color, 0)
        logging.info(f'{args.color} LED was turned on.')
        time.sleep(args.time)
        individual_led_control(args.color, 1)
        logging.info(f'{args.color} LED was turned off.')

except KeyboardInterrupt:
    # Handle the Ctrl-C case to ensure we cleanup GPIO settings
    logging.info('Interrupted by user.')
    
finally:
    # This block will run no matter how the try block was exited.
    individual_led_control('red', 1)
    individual_led_control('green', 1)
    individual_led_control('blue', 1)
    logging.info('All LEDs were turned off in finally.')
    if not os.path.exists("/sys/module/rockchipdrm"):
        GPIO.cleanup()
    kill_led_processes_except_self()
