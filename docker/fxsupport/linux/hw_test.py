from time import sleep
import time
import subprocess
import os

if not os.path.isdir("/sys/module/rockchipdrm"):
  import RPi.GPIO as GPIO
  # echo python ~/hw_test.py >> ~/.bashrc


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


  print("Start testing hardware")
  #testing VL805
  out = subprocess.Popen(['lsusb'], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
  stdout,stderr = out.communicate()
  out_str = stdout.decode()
  if out_str.find('VIA Labs') != -1 :
    print("Hardware OK")
    GPIO.output(led_g_pin, GPIO.LOW)
    time.sleep(5)  
    GPIO.output(led_g_pin, GPIO.HIGH)
  else:
    print("Hardware Error")
    GPIO.output(led_r_pin, GPIO.LOW)
    time.sleep(5)  
    GPIO.output(led_r_pin, GPIO.HIGH)
else:
    print("Running on RockChip")

