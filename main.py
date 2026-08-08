# import serial

# PORT = "COM4"
# BAUD = 9600

# ser = serial.Serial(
#     PORT,
#     BAUD,
#     timeout=1
# )

# print("Listening...")

# while True:

#     data = ser.read(1)

#     if len(data):
#         print(hex(data[0]))

import serial
import matplotlib.pyplot as plt
from collections import deque

# --- Configuration ---
PORT = 'COM4'         # Change to your COM port (e.g., '/dev/ttyUSB0' on Linux)
BAUD = 921600
BUFFER_SIZE = 1000    # Number of samples to display on screen

ser = serial.Serial(PORT, BAUD, timeout=1)

# Buffer for holding signed 24-bit converted audio values
data_buffer = deque([0] * BUFFER_SIZE, maxlen=BUFFER_SIZE)

plt.ion()
fig, ax = plt.subplots()
line, = ax.plot(data_buffer)
ax.set_ylim(-8388608, 8388607) # Signed 24-bit audio range
ax.set_title("Live FPGA I2S Audio Signal")
ax.set_xlabel("Samples")
ax.set_ylabel("Amplitude")

try:
    frame_count = 0
    while True:
        raw_line = ser.readline().decode('utf-8', errors='ignore').strip()
        if len(raw_line) == 6:
            try:
                # Convert 6-character Hex to unsigned 24-bit int
                val_unsigned = int(raw_line, 16)
                
                # Convert 24-bit unsigned to signed integer (Two's Complement)
                if val_unsigned & 0x800000:
                    val_signed = val_unsigned - 0x1000000
                else:
                    val_signed = val_unsigned
                
                data_buffer.append(val_signed)
                frame_count += 1
                
                # Update line plot every 100 samples to keep UI smooth
                if frame_count % 100 == 0:
                    line.set_ydata(data_buffer)
                    plt.pause(0.001)
                    
            except ValueError:
                pass
except KeyboardInterrupt:
    ser.close()
    print("Serial port closed.")