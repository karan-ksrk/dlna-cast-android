"""Synthesises the launch sound, timed to the intro animation in lib/ui/intro.dart.

Pure Python (no dependencies) so it can be regenerated anywhere:
    python design/brand/launch_sound.py out.wav
    ffmpeg -i out.wav -c:a libvorbis -q:a 5 android/app/src/main/res/raw/launch_sound.ogg

Beats (ms), shared with IntroTimeline in lib/ui/intro.dart: wind-up 0-650, impact 650, arc pings 1000/1200/1400,
name reveal and shimmer 1500-2650, exit whoosh 2400-2950.
"""
import math
import random
import struct
import sys
import wave

RATE = 48000
LENGTH = 3.25
random.seed(7)  # The same sound every time it's regenerated.

n = int(RATE * LENGTH)
left = [0.0] * n
right = [0.0] * n
send_l = [0.0] * n  # Bus into the ping-pong delay.
send_r = [0.0] * n


def add(i, value, pan=0.0, send=0.0):
    """Equal-power pan: -1 left, 1 right."""
    if 0 <= i < n:
        angle = (pan + 1) * math.pi / 4
        gl, gr = math.cos(angle), math.sin(angle)
        left[i] += value * gl
        right[i] += value * gr
        send_l[i] += value * gl * send
        send_r[i] += value * gr * send


def at(ms):
    return int(ms * RATE / 1000)


class Svf:
    """Chamberlin state-variable filter; returns (low, band, high)."""

    def __init__(self, q=0.7):
        self.low = self.band = 0.0
        self.damp = 1 / q

    def run(self, x, cutoff):
        f = 2 * math.sin(math.pi * min(cutoff, RATE / 6) / RATE)
        high = x - self.low - self.damp * self.band
        self.band += f * high
        self.low += f * self.band
        return self.low, self.band, high


# 1. Wind-up riser, 0-650 ms: band-passed noise sweeping up, and a sine climbing under it.
start, end = at(0), at(650)
filters = (Svf(2.5), Svf(2.5))
phase = 0.0
for i in range(start, end):
    p = (i - start) / (end - start)
    cutoff = 300 * (10 ** p)  # 300 Hz -> 3 kHz
    fade = min(1.0, (end - i) / at(15))
    amp = (p ** 2) * 0.35 * fade
    bl = filters[0].run(random.uniform(-1, 1), cutoff)[1]
    br = filters[1].run(random.uniform(-1, 1), cutoff * 1.03)[1]
    left[i] += bl * amp
    right[i] += br * amp
    phase += 2 * math.pi * (70 + 90 * p) / RATE
    add(i, math.sin(phase) * 0.3 * p * fade)

# 2. Impact at 650 ms: a pitch-dropping thump, a click and a bright downward zap. Phone speakers roll off below
# ~150 Hz, so the thump sits at 70 Hz and is saturated: its harmonics are what a phone actually plays.
hit = at(650)
phase = 0.0
for k in range(at(600)):
    t = k / RATE
    phase += 2 * math.pi * (70 + 120 * math.exp(-t / 0.04)) / RATE
    add(hit + k, math.tanh(3 * math.sin(phase)) * 0.45 * math.exp(-t / 0.22))
hp = Svf(0.7)
for k in range(at(10)):
    add(hit + k, hp.run(random.uniform(-1, 1), 4000)[2] * 0.5 * (1 - k / at(10)))
phase = 0.0
for k in range(at(160)):
    t = k / RATE
    phase += 2 * math.pi * (600 + 1200 * math.exp(-t / 0.05)) / RATE
    add(hit + k, math.sin(phase) * 0.18 * math.exp(-t / 0.06), send=0.4)


# 3. One bell ping per arc, rising and moving left to right.
def bell(start_ms, freq, pan, amp):
    partials = ((1.0, 1.0, 0.9), (2.0, 0.35, 0.5), (2.76, 0.2, 0.35), (5.4, 0.08, 0.2))
    s = at(start_ms)
    for k in range(at(1400)):
        t = k / RATE
        attack = min(1.0, t / 0.003)
        v = sum(a * math.exp(-t / d) * math.sin(2 * math.pi * freq * r * t) for r, a, d in partials)
        add(s + k, v * amp * attack, pan, send=0.5)


for ms, freq, pan in ((1000, 659.26, -0.45), (1200, 987.77, 0.0), (1400, 1318.51, 0.45)):
    bell(ms, freq, pan, 0.42)

# 4. Shimmer under the name reveal, 1500-2650 ms: a soft E-major pad and sparkles.
s, e = at(1500), at(2650)
for i in range(s, e):
    t = (i - s) / RATE
    env = min(1.0, t / 0.3) * min(1.0, (e - i) / at(350))
    tremolo = 0.75 + 0.25 * math.sin(2 * math.pi * 7 * t)
    v = sum(math.sin(2 * math.pi * f * t) for f in (1318.51, 1661.22, 1975.53)) * 0.075 * env * tremolo
    add(i, v, math.sin(2 * math.pi * 0.8 * t) * 0.5, send=0.6)
for _ in range(22):
    start_ms = random.uniform(1520, 2550)
    freq = random.uniform(2500, 5000)
    pan = random.uniform(-0.8, 0.8)
    k0 = at(start_ms)
    for k in range(at(90)):
        t = k / RATE
        add(k0 + k, math.sin(2 * math.pi * freq * t) * 0.05 * math.exp(-t / 0.025), pan, send=0.7)

# 5. Exit whoosh, 2350-2950 ms: low-passed noise closing down and sweeping across.
s, e = at(2350), at(2950)
filters = (Svf(1.2), Svf(1.2))
for i in range(s, e):
    p = (i - s) / (e - s)
    cutoff = 6000 * (400 / 6000) ** p
    amp = 0.28 * (p / 0.4 if p < 0.4 else (1 - p) / 0.6)
    pan = -0.7 + 1.4 * p
    angle = (pan + 1) * math.pi / 4
    left[i] += filters[0].run(random.uniform(-1, 1), cutoff)[0] * amp * math.cos(angle) * 1.6
    right[i] += filters[1].run(random.uniform(-1, 1), cutoff)[0] * amp * math.sin(angle) * 1.6

# Ping-pong delay on the send bus: 180 ms, feeding across channels.
delay = at(180)
buf_l = [0.0] * n
buf_r = [0.0] * n
for i in range(n):
    dl = buf_r[i - delay] if i >= delay else 0.0
    dr = buf_l[i - delay] if i >= delay else 0.0
    buf_l[i] = send_l[i] + dl * 0.38
    buf_r[i] = send_r[i] + dr * 0.38
    left[i] += dl * 0.5
    right[i] += dr * 0.5

# Master: soft clip, normalise, fade the tail.
mixed = [(math.tanh(l * 1.1), math.tanh(r * 1.1)) for l, r in zip(left, right)]
peak = max(max(abs(l), abs(r)) for l, r in mixed) or 1.0
gain = 0.89 / peak
fade = at(60)
frames = bytearray()
for i, (l, r) in enumerate(mixed):
    g = gain * min(1.0, (n - i) / fade)
    frames += struct.pack("<hh", int(l * g * 32767), int(r * g * 32767))

with wave.open(sys.argv[1] if len(sys.argv) > 1 else "launch_sound.wav", "wb") as out:
    out.setnchannels(2)
    out.setsampwidth(2)
    out.setframerate(RATE)
    out.writeframes(bytes(frames))
