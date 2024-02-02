import os
import time
import argparse
import logging
import psutil
import subprocess
import threading

color_combinations = {
    'light_blue': {'red': 0, 'green': 50, 'blue': 100},
    'yellow': {'red': 100, 'green': 100, 'blue': 0},
    'light_green': {'red': 0, 'green': 100, 'blue': 50},
    'light_purple': {'red': 50, 'green': 0, 'blue': 100},
    'red': {'red': 100, 'green': 0, 'blue': 0}, 
    'green': {'red': 0, 'green': 100, 'blue': 0}, 
    'blue': {'red': 0, 'green': 0, 'blue': 100},
    'white': {'red': 100, 'green': 100, 'blue': 100}
}

def turn_off_all_leds():
    for color in ['red', 'green', 'blue']:
        set_led_brightness(color, 0)
    if not os.path.exists("/sys/module/rockchipdrm"):
        GPIO.cleanup()
    logging.info('All LEDs were turned off.')

def turn_off_led(color, brightness):
    individual_led_control(color, 0)  # Turn off the LED
    logging.info(f'{color} LED was turned off.')

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
def individual_led_control(color, brightness=100):
    if color in color_combinations:
        for led_color, led_brightness in color_combinations[color].items():
            adjusted_brightness = int(brightness * (led_brightness / 100.0))
            set_led_brightness(led_color, adjusted_brightness)

def set_led_brightness(color, brightness):
    if os.path.exists("/sys/module/rockchipdrm"):
        brightness_value = int(1 - (brightness / 100.0))
        subprocess.call([f'echo {brightness_value} | sudo tee /sys/class/leds/led_{color}/brightness'], shell=True)
    else:
        # For Raspberry Pi, set the duty cycle for PWM
        # This part assumes that you have already set up PWM channels for each LED pin
        # GPIO.PWM(channel, frequency) to create a PWM instance, then pwm.start(duty_cycle)
        # For simplicity, we're using direct GPIO output here, as RPi.GPIO does not support PWM on all pins without additional setup
        if brightness == 0:
            GPIO.output({"red": led_r_pin, "green": led_g_pin, "blue": led_b_pin}.get(color), GPIO.HIGH)
        else:
            # Assuming GPIO.LOW simulates full brightness without actual PWM support
            GPIO.output({"red": led_r_pin, "green": led_g_pin, "blue": led_b_pin}.get(color), GPIO.LOW)

#setup logging
logging.basicConfig(filename='/home/pi/fula.sh.log', filemode='a', level=logging.INFO, format='%(asctime)s %(message)s')

# Create a parser for command line arguments
parser = argparse.ArgumentParser(description='Control LEDs.')
parser.add_argument('color', type=str, choices=['red', 'green', 'blue', 'light_blue', 'yellow', 'light_green', 'light_purple', 'white'], help='LED color.')
parser.add_argument('time', type=int, default=3, help='Time to flash the LED.')
parser.add_argument('brightness', nargs='?', default=100, type=int, help='Brightness level (0-100). Default is 100.')


args = parser.parse_args()
logging.info(f'{args.color} and {args.time} was received.')

led_pin = {"red": led_r_pin, "green": led_g_pin, "blue": led_b_pin}.get(args.color)

try:
    if args.time == -1 or args.time == 0:
        turn_off_all_leds()
        kill_led_processes_except_self()
    elif args.time != 999999:  # Check if the time is not 999999
        individual_led_control(args.color, args.brightness)
        logging.info(f'{args.color} LED was turned on.')
        # Only start the timer if the time is not 999999
        timer = threading.Timer(args.time, turn_off_all_leds)
        timer.start()
    else:
        # If the time is 999999, turn on the LED without setting a timer to turn it off
        individual_led_control(args.color, args.brightness)
        logging.info(f'{args.color} LED was turned on and will stay on indefinitely.')

except KeyboardInterrupt:
    logging.info('Interrupted by user.')
    if 'timer' in locals():
        timer.cancel()
    
