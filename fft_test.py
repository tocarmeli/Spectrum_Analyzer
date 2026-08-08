#!/usr/bin/env python3
"""
fft_uart_plot.py

Reads FFT bin-magnitude values streamed from the Arty S7-50 over UART.
Each line is "IIMMMMMM\r\n": 2 hex digits of the true bin index (from
the FFT core's XK_INDEX output) followed by 6 hex digits of magnitude.
Tagging each value with its true index means this doesn't depend on
the FFT core's internal output ordering (natural vs. bit-reversed).

Matches the FPGA design:
    - Audio decimated to FS_DECIMATED = 44100 / DECIMATION_FACTOR
    - FFT_LEN-point FFT run on that decimated stream
    - Only bins with index < FFT_LEN/2 are transmitted (real-input
      mirror discarded), each tagged with its index, repeating forever,
      frame after frame.

Usage:
    Edit the PORT (and BAUD/USE_LOG_SCALE if needed) constants below,
    then run:
        python fft_uart_plot.py
"""

import queue
import sys
import threading

import matplotlib.pyplot as plt
from matplotlib.animation import FuncAnimation
import serial

# ---------------------------------------------------------------------
# Configuration -- edit these to match your setup
# ---------------------------------------------------------------------
PORT = "COM4"          # e.g. "COM5" on Windows, "/dev/ttyUSB1" on Linux/Mac
BAUD = 921600
USE_LOG_SCALE = False   # True for a log-scaled Y axis

# Must match the FPGA design's parameters (top.v)
DECIMATION_FACTOR = 1  # no decimation; Nyquist ~22kHz covers 0-20kHz
FS_AUDIO = 44100.0
FS_DECIMATED = FS_AUDIO / DECIMATION_FACTOR   # sample rate feeding the FFT
FFT_LEN = 256
NUM_BINS = FFT_LEN // 2                       # bins actually transmitted
X_AXIS_MAX_HZ = 20000                         # requested display range


def serial_reader(port: str, baud: int, out_q: "queue.Queue[tuple[int, int]]", stop_evt: threading.Event):
    """Background thread: read "IIMMMMMM" lines from the serial port and
    push parsed (index, magnitude) tuples onto out_q."""
    try:
        ser = serial.Serial(port, baud, timeout=1)
    except serial.SerialException as exc:
        print(f"Failed to open serial port {port}: {exc}", file=sys.stderr)
        stop_evt.set()
        return

    with ser:
        while not stop_evt.is_set():
            try:
                raw = ser.readline()
            except serial.SerialException as exc:
                print(f"Serial read error: {exc}", file=sys.stderr)
                break

            line = raw.decode("ascii", errors="ignore").strip()
            if len(line) != 8:
                # Malformed / partial line (e.g. right after opening the
                # port mid-stream) -- just skip it and resync on the next.
                continue
            try:
                idx = int(line[0:2], 16)
                mag = int(line[2:8], 16)
            except ValueError:
                continue

            if idx >= NUM_BINS:
                # Shouldn't happen (the FPGA only sends idx < NUM_BINS),
                # but guard against a torn/misaligned read just in case.
                continue

            out_q.put((idx, mag))


def main():
    freqs = [i * FS_DECIMATED / FFT_LEN for i in range(NUM_BINS)]
    magnitudes = [0] * NUM_BINS

    data_q: "queue.Queue[tuple[int, int]]" = queue.Queue()
    stop_evt = threading.Event()
    reader_thread = threading.Thread(
        target=serial_reader, args=(PORT, BAUD, data_q, stop_evt), daemon=True
    )
    reader_thread.start()

    fig, ax = plt.subplots()
    bars = ax.bar(freqs, magnitudes, width=(FS_DECIMATED / FFT_LEN) * 0.9)
    ax.set_xlabel("Frequency (Hz)")
    ax.set_ylabel("Magnitude (|re| + |im|, approx.)")
    ax.set_title("Live FFT Spectrum (Pmod I2S2 line-in)")
    ax.set_xlim(0, X_AXIS_MAX_HZ)
    if USE_LOG_SCALE:
        ax.set_yscale("log")
        ax.set_ylim(1, 3000)
    else:
        ax.set_ylim(0, 3000)  # adjust to taste based on observed levels

    def update(_frame):
        updated = False
        while True:
            try:
                idx, mag = data_q.get_nowait()
            except queue.Empty:
                break
            magnitudes[idx] = mag
            updated = True

        if updated:
            for bar, mag in zip(bars, magnitudes):
                bar.set_height(max(mag, 1) if USE_LOG_SCALE else mag)
        return bars

    ani = FuncAnimation(fig, update, interval=50, blit=False)

    try:
        plt.show()
    finally:
        stop_evt.set()
        reader_thread.join(timeout=2)


if __name__ == "__main__":
    main()