"""main.py
Starts the MediaPipe body tracking thread (`BodyThread`), waits for user input,
then signals all threads to shut down.
"""

# pipe server
from body import BodyThread
import time
import struct
import global_vars
from sys import exit

thread = BodyThread()
thread.start()

i = input()
print("Exiting…")        
global_vars.KILL_THREADS = True
time.sleep(0.5)
exit()