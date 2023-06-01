# control_led.py
import RPi.GPIO as GPIO
import time
import argparse

led_r_pin=24
led_b_pin=16
led_g_pin=12

#setup LEDs
GPIO.setmode(GPIO.BCM)
GPIO.setwarnings(False)
 
GPIO.setup(led_r_pin, GPIO.OUT)
GPIO.setup(led_b_pin, GPIO.OUT)
GPIO.setup(led_g_pin, GPIO.OUT)

# LEDs are active low. So, set high for turning off
GPIO.output(led_r_pin, GPIO.HIGH)
GPIO.output(led_g_pin, GPIO.HIGH)
GPIO.output(led_b_pin, GPIO.HIGH)

# Create a parser for command line arguments
parser = argparse.ArgumentParser(description='Control LEDs.')
parser.add_argument('color', type=str, help='LED color (red, green, or blue).')
parser.add_argument('time', type=int, help='Time to flash the LED.')

args = parser.parse_args()

led_pin = {"red": led_r_pin, "green": led_g_pin, "blue": led_b_pin}.get(args.color)

# if time is -1, stop all flashing by setting all to 1
if args.time == -1:
    GPIO.output(led_r_pin, GPIO.HIGH)
    GPIO.output(led_g_pin, GPIO.HIGH)
    GPIO.output(led_b_pin, GPIO.HIGH)
else:
    # flash the LED
    while True:
        GPIO.output(led_pin, GPIO.LOW)
        time.sleep(1)
        GPIO.output(led_pin, GPIO.HIGH)
        time.sleep(1)
        
        if args.time > 0:
            args.time -= 1
        elif args.time == 0:
            continue
        else:
            break
