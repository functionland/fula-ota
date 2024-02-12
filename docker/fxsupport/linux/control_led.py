import os
import time
import datetime
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
    'white': {'red': 100, 'green': 100, 'blue': 100},
    'orange': {'red': 100, 'green': 50, 'blue': 0},
    'cyan': {'red': 0, 'green': 100, 'blue': 100},
    'magenta': {'red': 100, 'green': 0, 'blue': 100},
    'grey': {'red': 50, 'green': 50, 'blue': 50},
    'dark_green': {'red': 0, 'green': 50, 'blue': 0}
}

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

def write_persistence_file(color, time_param, brightness, persist):
    logging.info(f"Writing to persistence file: Color={color}, Time={time_param}, Brightness={brightness}, Persist={persist}")
    if persist:
        with open('/home/pi/control_led.per', 'w') as f:
            current_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
            logging.info("write_persistence_file")
            f.write(f"{current_time}\n{color}\n{time_param}\n{brightness}")

def read_persistence_file():
    logging.info("Reading persistence file")
    try:
        with open('/home/pi/control_led.per', 'r') as f:
            saved_time_str = f.readline().strip()
            color = f.readline().strip()
            time_param_str = f.readline().strip()
            brightness_str = f.readline().strip()
            logging.info(f"Reading persistence file: Color={color}, time_param_str={time_param_str}, brightness_str={brightness_str}")
            
            time_param = int(time_param_str)
            brightness = int(brightness_str)
            saved_time = datetime.datetime.strptime(saved_time_str, "%Y-%m-%d %H:%M:%S")
            current_time = datetime.datetime.now()
            elapsed = (current_time - saved_time).total_seconds()
            logging.info(f"Reading persistence file: Color={color}, time_param={time_param}, saved_time={saved_time}")
            if time_param != 999999:
                remaining_time = max(0, time_param - int(elapsed))
                if remaining_time <= 0:
                    os.remove('/home/pi/control_led.per')
                    return None, None, None
            else:
                remaining_time = 999999
            return color, remaining_time, brightness
    except FileNotFoundError:
        pass
    except ValueError as e:
        logging.error(f"Error parsing time_param or brightness as integers: {e}")
    except Exception as e:
        logging.error(f"Unexpected error reading persistence file: {e}")
    return None, None, None


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
            logging.info(f'{proc.info["pid"]} is killed in {current_pid}.')
            proc.kill()  # kill the process

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


def execute_led_control(color, time_param, brightness):
    """Executes the LED control command and optionally checks for persisted state."""
    logging.info(f"Executing LED control: Color={color}, Time={time_param}, Brightness={brightness}")
    kill_led_processes_except_self()
    individual_led_control(color, brightness)
    if time_param == -1 or time_param == 0:
        turn_off_all_leds()
    elif time_param != 999999:
        logging.info(f'{color} LED was turned on for {time_param} seconds.')
        time.sleep(time_param)
        turn_off_all_leds()
    else:
        logging.info(f'{color} LED was turned on indefinitely.')

#setup logging
logging.basicConfig(filename='/home/pi/fula.sh.log', filemode='a', level=logging.INFO, format='%(asctime)s %(message)s')

def main():
    parser = argparse.ArgumentParser(description='Control LEDs.')
    parser.add_argument('color', choices=color_combinations.keys(), help='LED color.')
    parser.add_argument('time', type=int, help='Time to keep the LED on.')
    parser.add_argument('brightness', nargs='?', default=100, type=int, help='Brightness level (0-100).')
    parser.add_argument('--persist', action='store_true', help='Persist LED state across calls.')
    parser.add_argument('--background', action='store_true', help='Indicates background execution for persisted state')

    args = parser.parse_args()

    logging.info(f"Received command: Color={args.color}, Time={args.time}, Brightness={args.brightness}, Persist={args.persist}")
    
    if args.background:
        # If running in background mode, skip persistence logic to prevent recursion
        execute_led_control(args.color, args.time, args.brightness)
    else:
        # Normal execution flow
        if args.persist:
            write_persistence_file(args.color, args.time, args.brightness, args.persist)
        
        execute_led_control(args.color, args.time, args.brightness)

        # Check for persisted state and execute in background if needed
        persisted_color, persisted_time, persisted_brightness = read_persistence_file()
        if persisted_color and persisted_time is not None and persisted_brightness is not None:
            command = f'python {__file__} {persisted_color} {persisted_time} {persisted_brightness} --background'
            subprocess.Popen(command, shell=True)

logging.basicConfig(filename='/home/pi/fula.sh.log', filemode='a', level=logging.INFO, format='%(asctime)s %(message)s')

if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        logging.info('Script interrupted by user.')