import time
import pexpect

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

start_time = time.time()

while True:
    try:
        child.expect('\[agent\] Confirm passkey', timeout=120)
        child.sendline('yes')
    except pexpect.TIMEOUT:
        pass
    except pexpect.EOF:
        break

    # Check if 120 seconds have passed since the script started
    current_time = time.time()
    elapsed_time = current_time - start_time

    if elapsed_time >= 120:
        print("120 seconds have passed. Turning off Bluetooth and stopping the script...")
        child.sendline('power off')
        break
