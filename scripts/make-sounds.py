#!/usr/bin/env python3
"""Generates the app's two sounds as 16-bit mono WAVs: a soft "pop" when a file lands
and a two-note bell chirp when the label has been sent."""
import math, struct, sys, wave

RATE = 44100

def write(path, samples):
    with wave.open(path, "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(RATE)
        w.writeframes(b"".join(struct.pack("<h", int(max(-1, min(1, s)) * 32767)) for s in samples))

def pop(duration=0.09):
    out, phase = [], 0.0
    for i in range(int(RATE * duration)):
        t = i / RATE
        freq = 520 + 700 * math.exp(-t * 60)          # quick downward sweep, like a bubble
        phase += 2 * math.pi * freq / RATE
        env = min(1, t / 0.004) * math.exp(-t * 45)
        out.append(0.45 * env * math.sin(phase))
    return out

def bell(freq, duration, start_gain=0.32):
    out = []
    for i in range(int(RATE * duration)):
        t = i / RATE
        env = min(1, t / 0.006) * math.exp(-t * 9)
        s = math.sin(2 * math.pi * freq * t) + 0.25 * math.sin(2 * math.pi * freq * 2.01 * t) * math.exp(-t * 20)
        out.append(start_gain * env * s)
    return out

def chirp():
    first, second = bell(1046.5, 0.5), bell(1568.0, 0.7)   # C6 then G6
    offset = int(RATE * 0.085)
    out = first + [0.0] * (offset + len(second) - len(first))
    for i, s in enumerate(second):
        out[offset + i] += s
    return out

folder = sys.argv[1] if len(sys.argv) > 1 else "Resources"
write(f"{folder}/pop.wav", pop())
write(f"{folder}/sent.wav", chirp())
print(f"sounds written to {folder}")
