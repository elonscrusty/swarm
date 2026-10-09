"""Synthesize SWARM's original sound effects (numpy only) into art/audio/<Name>.ogg.

    python3 tools/synth_sfx.py [--only A,B | --new] [--wav]

Everything here is generated from sine/noise oscillators, filters and a small
algorithmic reverb, so the files are original and free to upload. Deterministic (seeded).
Upload with tools/upload_audio.py; the slot -> file mapping is in docs/AUDIO.md.

Style: warm fantasy, not chiptune. Frequent sounds (Hit, EnemyDeath, GemPickup, Coin,
Click) are short, low-passed and soft-edged; rare rewards (LevelUp, Chest, Evolve,
PortalAppear, BossRoar) are longer, richer and carry a reverb tail.

Second batch (stream G, 2026-10-09): the class signature cues (scrap clatter, toast pop,
bubble, yarn pop, dodgeball thump / whistle, mop swoosh / squeak, confetti rattle / honk,
gym scrape, puck clack / skate roll, glove thud / bell, shoe boing, seed sprout), the run
stage cues (beacon, boss spawn, victory / defeat stingers, downed, revive beat, chest
purchase) and the crit tick. Each of these is reseeded from its own name (reseed()), so
`--only Name` renders the same file as a full run. Nothing is sampled from anywhere: every
sound is oscillators + filtered noise, like the first batch. Docs: docs/AUDIO.md.
"""

import argparse
import math
import os
import subprocess
import wave
import zlib

import numpy as np

SR = 44100
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "art", "audio")
rng = np.random.default_rng(7)


# ---------------------------------------------------------------- building blocks

def t_axis(dur):
    return np.arange(int(dur * SR)) / SR


def silence(dur):
    return np.zeros(int(dur * SR))


def env_ad(n, attack, decay, curve=1.0):
    """Linear attack, exponential decay (decay = time constant in seconds)."""
    t = np.arange(n) / SR
    a = np.clip(t / max(attack, 1e-4), 0, 1)
    d = np.exp(-np.maximum(t - attack, 0) / max(decay, 1e-4)) ** curve
    return a * d


def fade(x, fin=0.002, fout=0.02):
    x = x.copy()
    i, o = int(fin * SR), int(fout * SR)
    if i:
        x[:i] *= np.linspace(0, 1, i)
    if o:
        x[-o:] *= np.linspace(1, 0, o)
    return x


def sweep_phase(f0, f1, n, shape=1.0):
    """Phase of a sine gliding from f0 to f1 (exponential glide)."""
    k = (np.arange(n) / max(n - 1, 1)) ** shape
    f = f0 * (f1 / f0) ** k
    return 2 * np.pi * np.cumsum(f) / SR


def sine_sweep(f0, f1, dur, shape=1.0):
    n = int(dur * SR)
    return np.sin(sweep_phase(f0, f1, n, shape))


def noise(dur):
    return rng.standard_normal(int(dur * SR))


def svf(x, cutoff, q=0.7, mode="lp"):
    """Chamberlin state-variable filter; cutoff may be a per-sample array."""
    n = len(x)
    fc = np.broadcast_to(np.asarray(cutoff, dtype=float), (n,))
    f = 2 * np.sin(np.pi * np.clip(fc, 20, SR / 6) / SR)
    damp = 1.0 / q
    low = band = 0.0
    out = np.empty(n)
    for i in range(n):
        low += f[i] * band
        high = x[i] - low - damp * band
        band += f[i] * high
        out[i] = low if mode == "lp" else band if mode == "bp" else high
    return out


def lp(x, cutoff, q=0.7):
    return svf(x, cutoff, q, "lp")


def bp(x, cutoff, q=2.0):
    return svf(x, cutoff, q, "bp")


def hp(x, cutoff, q=0.7):
    return svf(x, cutoff, q, "hp")


def bell(freq, dur, decay=0.4, bright=0.5, ratios=(1, 2.0, 2.76, 4.07, 5.4), attack=0.002):
    """Soft additive bell: higher partials quieter and shorter."""
    t = t_axis(dur)
    out = np.zeros_like(t)
    for k, r in enumerate(ratios):
        amp = (bright ** k) / (1 + k)
        out += amp * np.sin(2 * np.pi * freq * r * t + k) * np.exp(-t / (decay / (1 + 0.8 * k)))
    a = np.clip(t / attack, 0, 1)
    return out * a


def pad(freqs, dur, attack=0.2, release=0.6, detune=0.004, bright=1400):
    """Warm chord: detuned triangle-ish voices, low-passed."""
    t = t_axis(dur)
    out = np.zeros_like(t)
    for f in freqs:
        for d in (-detune, 0, detune):
            ph = 2 * np.pi * f * (1 + d) * t
            out += np.sin(ph) + 0.18 * np.sin(3 * ph) + 0.08 * np.sin(5 * ph)
    env = np.clip(t / attack, 0, 1) * np.clip((dur - t) / release, 0, 1)
    return lp(out * env, bright) / (len(freqs) * 3)


def place(dst, src, at):
    i = int(at * SR)
    j = min(len(dst), i + len(src))
    dst[i:j] += src[: j - i]
    return dst


def mix(dur, *parts):
    out = silence(dur)
    for at, sig, gain in parts:
        place(out, sig * gain, at)
    return out


def reverb(x, seconds=1.2, wet=0.25, tone=4000, predelay=0.012):
    """Convolution with a decaying, low-passed noise tail (stereo-free hall)."""
    n = int(seconds * SR)
    ir = rng.standard_normal(n) * np.exp(-np.arange(n) / SR / (seconds / 6.9))
    ir = lp(ir, tone)
    ir /= np.sqrt(np.sum(ir ** 2)) + 1e-9
    ir = np.concatenate([np.zeros(int(predelay * SR)), ir])
    size = 1 << int(math.ceil(math.log2(len(x) + len(ir))))
    y = np.fft.irfft(np.fft.rfft(x, size) * np.fft.rfft(ir, size), size)[: len(x) + len(ir)]
    dry = np.concatenate([x, np.zeros(len(ir))])
    return dry + wet * y


def soft_clip(x, drive=1.5):
    return np.tanh(x * drive) / np.tanh(drive)


def trim_tail(x, db=-60):
    thr = np.max(np.abs(x)) * 10 ** (db / 20)
    idx = np.nonzero(np.abs(x) > thr)[0]
    end = idx[-1] + int(0.01 * SR) if len(idx) else len(x)
    return x[:end]


def note(n):
    """MIDI note -> Hz."""
    return 440.0 * 2 ** ((n - 69) / 12)


# ---------------------------------------------------------------- the sounds

def s_hit():
    # soft fleshy thump: pitched body + a short muted knock, no bright click
    # (phone speakers drop everything under ~250 Hz, so the body sits at 340 -> 150 Hz
    # and is gently saturated for audible harmonics)
    n = int(0.14 * SR)
    body = soft_clip(sine_sweep(340, 150, 0.14, 0.6) * env_ad(n, 0.002, 0.03), 2.0)
    knock = lp(bp(noise(0.14), 1100, 1.5), 2800) * env_ad(n, 0.001, 0.012)
    return fade(body * 0.8 + knock * 0.6, 0.001, 0.03)


def s_enemy_death():
    # muffled "poof": noise through a closing low-pass + a small low pop
    n = int(0.32 * SR)
    cut = 2600 * (380 / 2600) ** (np.arange(n) / n)
    puff = lp(noise(0.32), cut, 0.9) * env_ad(n, 0.004, 0.07)
    pop = soft_clip(sine_sweep(300, 110, 0.32, 0.5) * env_ad(n, 0.002, 0.045), 1.8)
    return fade(puff * 0.8 + pop * 0.7, 0.001, 0.05)


def s_big_kill():
    n = int(0.9 * SR)
    sub = sine_sweep(160, 50, 0.9, 0.5) * env_ad(n, 0.003, 0.16)
    cut = 2200 * (220 / 2200) ** (np.arange(n) / n)
    rumble = lp(noise(0.9), cut, 0.8) * env_ad(n, 0.004, 0.16)
    x = soft_clip(sub * 1.0 + rumble * 0.8, 2.2)
    return trim_tail(reverb(x, 0.8, 0.18, 1500))


def s_explosion():
    n = int(1.1 * SR)
    cut = 3200 * (160 / 3200) ** ((np.arange(n) / n) ** 0.6)
    blast = lp(noise(1.1), cut, 0.8) * env_ad(n, 0.003, 0.22)
    sub = sine_sweep(130, 40, 1.1, 0.5) * env_ad(n, 0.002, 0.2)
    x = soft_clip(blast * 0.9 + sub * 0.9, 2.0)
    return trim_tail(reverb(x, 1.0, 0.2, 1800))


def s_lightning():
    # crackle: sparse filtered noise bursts over a quick downward zap, mellowed
    dur = 0.45
    n = int(dur * SR)
    cr = noise(dur) * (rng.random(n) < 0.08)
    cr = bp(cr, 2400, 1.2) * env_ad(n, 0.001, 0.09) * 3
    zap = sine_sweep(1100, 160, dur, 0.4) * env_ad(n, 0.001, 0.05) * 0.4
    body = lp(noise(dur), 900) * env_ad(n, 0.002, 0.08) * 0.8
    return trim_tail(reverb(fade(lp(cr + zap + body, 4500), 0.001, 0.05), 0.6, 0.15, 3000))


def s_swing():
    # airy whoosh: band-pass sweep up then down, bell-shaped envelope
    dur = 0.26
    n = int(dur * SR)
    k = np.arange(n) / n
    cut = 500 + 1600 * np.sin(np.pi * k) ** 1.5
    w = lp(bp(noise(dur), cut, 1.4), 3000) * np.sin(np.pi * k) ** 2
    return fade(w, 0.002, 0.02)


def s_hurt():
    n = int(0.32 * SR)
    punch = sine_sweep(280, 100, 0.32, 0.5) * env_ad(n, 0.002, 0.06)
    crunch = lp(bp(noise(0.32), 850, 1.2), 2500) * env_ad(n, 0.001, 0.035) * 1.6
    grunt = lp(np.sign(np.sin(sweep_phase(190, 130, n))), 900) * env_ad(n, 0.01, 0.07) * 0.45
    return fade(soft_clip(punch + crunch * 0.7 + grunt, 1.3), 0.001, 0.05)


def s_heartbeat():
    def thump():
        n = int(0.16 * SR)
        return lp(soft_clip(sine_sweep(120, 65, 0.16, 0.5) * env_ad(n, 0.006, 0.045), 2.5), 700)
    return fade(mix(0.5, (0, thump(), 1.0), (0.17, thump(), 0.7)), 0.001, 0.05)


def s_death():
    # slow falling minor chord, warm and low
    dur = 2.0
    t = t_axis(dur)
    out = np.zeros_like(t)
    for f in (note(57), note(60), note(64)):  # A3 C4 E4
        glide = f * (0.8 ** (t / dur))
        out += np.sin(2 * np.pi * np.cumsum(glide) / SR)
    out = lp(out, 1200) * np.clip(t / 0.03, 0, 1) * np.exp(-t / 0.7) / 3
    thud = soft_clip(sine_sweep(150, 55, dur, 0.3) * env_ad(len(t), 0.002, 0.12), 2.0)
    return trim_tail(reverb(out + thud * 0.5, 1.6, 0.3, 2500))


def s_gem():
    # soft crystal tink; Config pitch variation spreads repeats over a few notes
    x = bell(note(88), 0.45, decay=0.12, bright=0.3, ratios=(1, 2.0, 3.01))
    x = lp(x, 6000)
    return trim_tail(reverb(fade(x, 0.001, 0.05), 0.5, 0.12, 5000))


def s_coin():
    a = bell(note(83), 0.5, decay=0.10, bright=0.45, ratios=(1, 2.42, 4.1))
    b = bell(note(88), 0.5, decay=0.16, bright=0.45, ratios=(1, 2.42, 4.1))
    x = lp(mix(0.55, (0, a, 0.7), (0.06, b, 0.8)), 7000)
    return trim_tail(reverb(fade(x, 0.001, 0.05), 0.5, 0.12, 5000))


def arp(notes, step, dur, decay=0.5, bright=0.45, gain=1.0):
    out = silence(dur)
    for i, m in enumerate(notes):
        place(out, bell(note(m), dur - i * step, decay=decay, bright=bright) * gain, i * step)
    return out


def s_level_up():
    # rising C-major arpeggio over a warm pad, sparkle on top, hall tail
    dur = 1.6
    a = arp([72, 76, 79, 84], 0.075, dur, decay=0.45, bright=0.35)
    top = arp([88, 91, 96], 0.05, dur, decay=0.3, bright=0.25, gain=0.35)
    p = pad([note(48), note(55), note(64)], dur, attack=0.05, release=0.9, bright=1600)
    x = mix(dur, (0, a, 0.55), (0.3, top, 1.0), (0, p, 0.8))
    return trim_tail(reverb(fade(lp(x, 7000), 0.001, 0.1), 1.6, 0.3, 4500))


def s_revive():
    dur = 1.6
    a = arp([69, 73, 76, 81], 0.1, dur, decay=0.5, bright=0.3)
    p = pad([note(57), note(64), note(69)], dur, attack=0.25, release=0.8, bright=1300)
    x = mix(dur, (0, a, 0.5), (0, p, 1.0))
    return trim_tail(reverb(fade(lp(x, 6000), 0.005, 0.1), 1.6, 0.35, 4000))


def s_chest():
    # wooden lid thump + latch, then a quick sparkle cascade of treasure
    dur = 1.6
    n = int(0.3 * SR)
    wood = sine_sweep(140, 70, 0.3, 0.5) * env_ad(n, 0.002, 0.05)
    knock = bp(noise(0.3), 420, 3.0) * env_ad(n, 0.001, 0.04) * 1.5
    latch = bp(noise(0.05), 2200, 4.0) * env_ad(int(0.05 * SR), 0.0005, 0.006) * 0.6
    sparkle = arp([79, 84, 88, 91, 96], 0.055, 1.3, decay=0.4, bright=0.3)
    swell = pad([note(60), note(67), note(76)], 1.3, attack=0.15, release=0.7, bright=1800)
    x = mix(dur, (0, wood + knock, 0.9), (0.02, latch, 1.0), (0.12, sparkle, 0.45), (0.1, swell, 0.7))
    return trim_tail(reverb(fade(lp(x, 7500), 0.001, 0.1), 1.5, 0.28, 4500))


def s_item():
    dur = 0.9
    a = arp([76, 83], 0.07, dur, decay=0.35, bright=0.35)
    x = mix(dur, (0, a, 0.6), (0.12, arp([88], 0, 0.6, 0.25, 0.25), 0.25))
    return trim_tail(reverb(fade(lp(x, 7000), 0.001, 0.08), 1.0, 0.25, 4500))


def s_shrine():
    # mystic: slow-blooming suspended chord and a low bell
    dur = 2.0
    p = pad([note(50), note(57), note(62), note(64)], dur, attack=0.35, release=1.2, bright=1500)
    b = bell(note(74), dur, decay=0.7, bright=0.35)
    x = mix(dur, (0, p, 1.2), (0.05, b, 0.35))
    return trim_tail(reverb(fade(x, 0.005, 0.15), 2.0, 0.4, 3500))


def s_portal():
    # rising whoosh + deep drone swelling, landing on an open fifth chime
    dur = 2.6
    n = int(dur * SR)
    k = np.arange(n) / n
    cut = 180 * (3200 / 180) ** (k ** 1.4)
    swell = np.clip(k / 0.75, 0, 1) ** 2 * np.clip((1 - k) / 0.25, 0, 1)
    whoosh = bp(noise(dur), cut, 1.8) * swell
    t = t_axis(dur)
    drone = (np.sin(2 * np.pi * 55 * t) + 0.6 * np.sin(2 * np.pi * 82.5 * t)
             + 0.25 * np.sin(2 * np.pi * 110.3 * t)) * np.clip(t / 1.0, 0, 1) * np.clip((dur - t) / 0.9, 0, 1)
    chime = arp([64, 71, 76], 0.06, 1.0, decay=0.5, bright=0.35)
    x = mix(dur, (0, whoosh, 0.8), (0, lp(drone, 400), 0.45), (1.6, chime, 0.45))
    return trim_tail(reverb(fade(x, 0.01, 0.1), 2.2, 0.35, 3500))


def s_boss_roar():
    # growl: detuned low saws with a rough AM and pitch rise/fall, breath noise, distortion
    dur = 2.0
    n = int(dur * SR)
    t = t_axis(dur)
    k = t / dur
    pitch = 62 * (1 + 0.35 * np.sin(np.pi * np.clip(k * 1.4, 0, 1)) ** 1.5) * (1 + 0.02 * np.sin(2 * np.pi * 6 * t))
    out = np.zeros(n)
    for d in (0.0, 0.013, -0.011, 0.5):  # last voice an octave-ish lower growl
        f = pitch * (1 + d) if d < 0.4 else pitch * 0.5
        ph = np.cumsum(f) / SR
        out += 2 * (ph % 1.0) - 1
    rough = 0.6 + 0.4 * np.sin(2 * np.pi * 27 * t + 3 * np.sin(2 * np.pi * 3.1 * t))
    env = np.clip(t / 0.12, 0, 1) * np.clip((dur - t) / 0.7, 0, 1)
    growl = lp(out * rough * env, 700 + 500 * np.sin(np.pi * np.clip(k * 1.3, 0, 1)), 1.2)
    breath = bp(noise(dur), 650, 1.0) * env * 0.5
    hit = sine_sweep(70, 30, dur, 0.4) * env_ad(n, 0.003, 0.18)
    x = soft_clip(growl * 0.6 + breath + hit * 0.9, 2.2)
    return trim_tail(reverb(fade(x, 0.003, 0.2), 2.0, 0.3, 2000))


def s_boss_slam():
    # heavy ground pound for boss telegraphs (BossPound)
    n = int(1.2 * SR)
    sub = sine_sweep(120, 38, 1.2, 0.4) * env_ad(n, 0.002, 0.25)
    cut = 2400 * (150 / 2400) ** ((np.arange(n) / n) ** 0.5)
    crack = lp(noise(1.2), cut) * env_ad(n, 0.002, 0.12)
    x = soft_clip(sub + crack * 0.9, 2.4)
    return trim_tail(reverb(x, 1.3, 0.22, 1500))


def s_evolve():
    # transformation: swelling shimmer + upward two-octave run + a bright chord
    dur = 2.0
    run = arp([60, 64, 67, 72, 76, 79, 84], 0.06, dur, decay=0.35, bright=0.3)
    p = pad([note(48), note(60), note(64), note(67)], dur, attack=0.5, release=1.0, bright=2200)
    n = int(dur * SR)
    k = np.arange(n) / n
    shimmer = lp(bp(noise(dur), 2200 + 1800 * k, 6.0), 5000) * np.clip(k / 0.4, 0, 1) * np.clip((1 - k) / 0.5, 0, 1) * 0.5
    x = mix(dur, (0, run, 0.45), (0, p, 0.9), (0, shimmer, 0.3))
    return trim_tail(reverb(fade(lp(x, 6500), 0.005, 0.15), 2.0, 0.35, 5000))


def s_victory():
    # short brass-like fanfare: G C E G(held), soft-saw voices through a low-pass
    def horn(m, dur, gain=1.0):
        t = t_axis(dur)
        f = note(m) * (1 + 0.004 * np.sin(2 * np.pi * 5.5 * t) * np.clip(t / 0.3, 0, 1))
        ph = np.cumsum(f) / SR
        saw = (2 * (ph % 1.0) - 1) + 0.5 * (2 * ((ph * 1.003) % 1.0) - 1)
        env = np.clip(t / 0.03, 0, 1) * np.clip((dur - t) / 0.15, 0, 1)
        cut = 900 + 1800 * np.exp(-t / 0.25)
        return lp(saw * env, cut, 1.0) * gain
    dur = 2.6
    x = mix(dur,
            (0.0, horn(67, 0.18), 0.8), (0.2, horn(72, 0.18), 0.8), (0.4, horn(76, 0.18), 0.8),
            (0.6, horn(79, 1.7), 0.9), (0.6, horn(72, 1.7), 0.6), (0.6, horn(64, 1.7), 0.6),
            (0.6, horn(48, 1.7), 0.5))
    return trim_tail(reverb(fade(x, 0.002, 0.2), 1.8, 0.3, 4000))


def s_click():
    # soft wooden tick (UI)
    n = int(0.07 * SR)
    tick = bp(noise(0.07), 1700, 3.0) * env_ad(n, 0.0005, 0.006)
    tone = np.sin(2 * np.pi * 820 * t_axis(0.07)) * env_ad(n, 0.0008, 0.012) * 0.6
    return fade(lp(tick + tone, 5000), 0.0005, 0.02)


def s_toggle():
    n = int(0.11 * SR)
    a = np.sin(2 * np.pi * 660 * t_axis(0.11)) * env_ad(n, 0.0008, 0.014)
    b = np.sin(2 * np.pi * 990 * t_axis(0.11)) * env_ad(n, 0.0008, 0.016)
    tick = bp(noise(0.11), 1900, 3.0) * env_ad(n, 0.0005, 0.005) * 0.6
    return fade(lp(mix(0.11, (0, a, 0.6), (0.04, b, 0.5), (0, tick, 1.0)), 5000), 0.0005, 0.02)


def s_tip():
    x = mix(0.8, (0, bell(note(79), 0.6, decay=0.25, bright=0.25), 0.6),
            (0.09, bell(note(84), 0.6, decay=0.3, bright=0.25), 0.6))
    return trim_tail(reverb(fade(x, 0.001, 0.05), 0.8, 0.2, 4000))


def s_reel_tick():
    n = int(0.05 * SR)
    x = np.sin(2 * np.pi * 1250 * t_axis(0.05)) * env_ad(n, 0.0005, 0.008)
    x += bp(noise(0.05), 2500, 3.0) * env_ad(n, 0.0005, 0.003) * 0.5
    return fade(lp(x, 6000), 0.0005, 0.01)


def s_boss_whoosh():
    # deep heavy whoosh for boss attack telegraphs (BossWarn / BossWave / BossGust)
    dur = 0.9
    n = int(dur * SR)
    k = np.arange(n) / n
    cut = 200 + 900 * np.sin(np.pi * k) ** 1.2
    w = bp(noise(dur), cut, 1.2) * np.sin(np.pi * k) ** 1.5
    rumble = lp(noise(dur), 160) * np.sin(np.pi * k) * 2
    return trim_tail(reverb(fade(lp(w, 2500) + rumble, 0.005, 0.05), 0.9, 0.2, 2000))


# ---------------------------------------------------------------- batch 2 (stream G)
# Class signature cues, run stage cues and the crit tick. Short and mid-heavy like the
# first batch (energy above ~300 Hz so phone speakers carry them); each is reseeded from
# its own name (see reseed) so a single --only run is identical to a full run.

def reseed(name):
    global rng
    rng = np.random.default_rng(zlib.crc32(name.encode()))


def metal(freq, dur, decay, ratios=(1, 2.76, 5.4, 8.93), amps=(1, 0.6, 0.35, 0.2)):
    """Inharmonic metal ping (clink): partials that die faster the higher they are."""
    t = t_axis(dur)
    out = np.zeros_like(t)
    for k, (r, a) in enumerate(zip(ratios, amps)):
        out += a * np.sin(2 * np.pi * freq * r * t + k) * np.exp(-t / (decay / (1 + 0.7 * k)))
    return out * np.clip(t / 0.0008, 0, 1)


def plus(*parts):
    """Sum signals of different lengths (shorter ones are padded with silence)."""
    n = max(len(p) for p in parts)
    out = np.zeros(n)
    for p in parts:
        out[: len(p)] += p
    return out


def tick(dur, cutoff, q=2.5, decay=0.004, gain=1.0):
    """A short filtered-noise tick."""
    return bp(noise(dur), cutoff, q) * env_ad(int(dur * SR), 0.0003, decay) * gain


def thump(f0, f1, dur, decay, drive=2.0):
    """Soft pitched thump (kept above phone-speaker rolloff by the saturation)."""
    n = int(dur * SR)
    return soft_clip(sine_sweep(f0, f1, dur, 0.55) * env_ad(n, 0.002, decay), drive)


def horn_voice(m, dur, gain=1.0, cut=1500, detune=1.004):
    """Soft detuned saw voice through a low-pass (brass-ish)."""
    t = t_axis(dur)
    f = note(m)
    ph = np.cumsum(np.full(len(t), f)) / SR
    saw = (2 * (ph % 1.0) - 1) + 0.6 * (2 * ((ph * detune) % 1.0) - 1)
    env = np.clip(t / 0.025, 0, 1) * np.clip((dur - t) / 0.18, 0, 1)
    return lp(saw * env, cut, 1.0) * gain


# --- class cues -----------------------------------------------------------------------

def s_scrap_clatter():
    # Ruckus: a handful of tin bits bouncing off each other, one low thunk under the first
    dur = 0.48
    out = silence(dur)
    hits = [(0.0, 1.0, 1250), (0.045, 0.7, 1830), (0.10, 0.6, 980), (0.155, 0.45, 2100), (0.23, 0.3, 1560), (0.31, 0.18, 2350)]
    for at, g, f in hits:
        f2 = f * (0.93 + 0.14 * rng.random())
        place(out, plus(metal(f2, 0.14, 0.022), tick(0.05, 3200, 2.0, 0.005) * 0.6) * g, at)
    place(out, thump(250, 130, 0.12, 0.03, 2.0) * 0.7, 0.0)
    return fade(lp(out, 7500), 0.001, 0.06)


def s_toast_pop():
    # Toastmaster: spring release "thwoing" and a cork pop, a toaster ding behind it
    dur = 0.42
    t = t_axis(0.3)
    wob = 1 + 0.09 * np.sin(2 * np.pi * 40 * t) * np.exp(-t / 0.1)
    spring = np.sin(sweep_phase(300, 640, len(t), 0.5) * wob) * env_ad(len(t), 0.003, 0.07)
    n = int(0.12 * SR)
    pop = lp(bp(noise(0.12), 950, 1.2), 3500) * env_ad(n, 0.0008, 0.012) * 1.6 + thump(720, 320, 0.12, 0.018, 1.8) * 0.6
    ding = bell(note(96), 0.3, decay=0.09, bright=0.3, ratios=(1, 2.0, 3.01)) * 0.35
    out = mix(dur, (0, spring, 0.8), (0.07, pop, 0.9), (0.09, ding, 0.5))
    return fade(lp(out, 7000), 0.001, 0.07)


def s_bubble():
    # Captain Croak: rubbery "bloop-blip": rising sine glides with a little wobble
    def bloop(f0, f1, d, gain):
        n = int(d * SR)
        ph = sweep_phase(f0, f1, n, 0.6)
        wob = 1 + 0.10 * np.sin(2 * np.pi * 34 * t_axis(d))
        return (np.sin(ph) + 0.28 * np.sin(2 * ph)) * wob * env_ad(n, 0.004, d / 3.2) * gain
    out = mix(0.36, (0, bloop(260, 800, 0.2, 1.0), 1.0), (0.1, bloop(440, 1200, 0.16, 1.0), 0.6))
    return fade(lp(soft_clip(out, 1.3), 5200), 0.001, 0.06)


def s_yarn_pop():
    # Granny Boom: a short fuse sizzle, then a fluffy "pomf"
    nf = int(0.2 * SR)
    k = np.arange(nf) / nf
    crackle = noise(0.2) * (rng.random(nf) < 0.22)
    sizzle = lp(hp(noise(0.2) * 0.5 + crackle * 1.4, 2200), 5200) * (0.35 + 0.65 * k)
    n = int(0.3 * SR)
    pop = thump(430, 170, 0.3, 0.05, 2.4)
    puff = lp(noise(0.3), 1900) * env_ad(n, 0.003, 0.06)
    fluff = bp(noise(0.3), 2300, 1.0) * env_ad(n, 0.01, 0.09) * 0.25
    out = mix(0.52, (0, sizzle, 0.16), (0.2, pop, 0.85), (0.2, puff, 0.7), (0.2, fluff, 1.0))
    return fade(lp(out, 6500), 0.001, 0.08)


def s_dodgeball_thump():
    # Coach Crunch: a rubber ball hitting a floor: thump, slap, a smaller second bounce
    n = int(0.2 * SR)
    body = thump(480, 190, 0.2, 0.05, 2.6)
    slap = lp(bp(noise(0.2), 700, 1.3), 2200) * env_ad(n, 0.0007, 0.01) * 1.2
    again = thump(430, 210, 0.12, 0.035, 2.4) * 0.4
    out = mix(0.3, (0, body, 0.9), (0, slap, 0.6), (0.14, again, 0.8))
    return fade(out, 0.001, 0.05)


def s_dodgeball_whistle():
    # Coach Crunch: a short pea whistle
    dur = 0.32
    t = t_axis(dur)
    f = 2250 + 280 * (t / dur)
    ph = 2 * np.pi * np.cumsum(f) / SR
    trill = 1 + 0.35 * np.sin(2 * np.pi * 34 * t)
    tone = (np.sin(ph) + 0.18 * np.sin(2 * ph)) * trill
    breath = bp(noise(dur), 3100, 1.5) * 0.3
    env = np.clip(t / 0.012, 0, 1) * np.clip((dur - t) / 0.06, 0, 1)
    return fade((tone + breath) * env, 0.001, 0.03)


def s_mop_swoosh():
    # Doug: a wet swish (band-passed noise sweep) with a couple of water crackles
    dur = 0.4
    n = int(dur * SR)
    k = np.arange(n) / n
    cut = 420 + 1300 * np.sin(np.pi * k) ** 1.4
    w = lp(bp(noise(dur), cut, 1.2), 3600) * np.sin(np.pi * k) ** 1.8
    wet = bp(noise(dur) * (rng.random(n) < 0.04), 2600, 1.2) * env_ad(n, 0.01, 0.12) * 4
    return fade(w + wet * 0.35, 0.003, 0.05)


def s_mop_squeak():
    # Doug: rubber on a clean floor: two quick chirps with a fast flutter
    def chirp(f0, f1, d, gain):
        n = int(d * SR)
        t = t_axis(d)
        ph = sweep_phase(f0, f1, n, 0.8) + 0.7 * np.sin(2 * np.pi * 48 * t)
        return (np.sin(ph) + 0.15 * np.sin(2 * ph)) * env_ad(n, 0.004, d / 2.5) * gain
    out = mix(0.28, (0, chirp(1700, 2700, 0.12, 1.0), 1.0), (0.1, chirp(2300, 1500, 0.12, 1.0), 0.8))
    return fade(lp(out, 6500), 0.002, 0.04)


def s_confetti_rattle():
    # Rambozo: a quick rattle of paper poppers (dense, bright ticks that fade)
    dur = 0.34
    out = silence(dur)
    at = 0.0
    while at < 0.26:
        g = (0.55 + 0.45 * rng.random()) * (1 - at / 0.4)
        place(out, tick(0.03, 1700 + 1700 * rng.random(), 2.0, 0.004) * g * 1.6, at)
        at += 0.018 + 0.012 * rng.random()
    n = int(dur * SR)
    paper = lp(hp(noise(dur), 3000), 5600) * env_ad(n, 0.01, 0.1) * 0.05
    return fade(lp(lp(out + paper, 4800), 4800), 0.001, 0.06)


def s_confetti_honk():
    # Rambozo: a bulb-horn "honk" (two detuned reeds, a nasal formant, a little sag)
    dur = 0.36
    t = t_axis(dur)
    f = 395 * (1 - 0.07 * np.clip((t - 0.1) / 0.2, 0, 1))
    ph = np.cumsum(f) / SR
    reed = (2 * (ph % 1.0) - 1) + 0.7 * (2 * ((ph * 1.012) % 1.0) - 1)
    env = np.clip(t / 0.01, 0, 1) * np.clip((0.3 - t) / 0.05, 0, 1)
    honk = (bp(reed, 1100, 1.4) * 1.5 + lp(reed, 900) * 0.5) * env
    return trim_tail(reverb(fade(soft_clip(honk, 1.6), 0.002, 0.05), 0.25, 0.12, 4500))


def s_gym_scrape():
    # Swolverine: a steel gauntlet dragged along a rail: gritty band noise + ringing partials
    dur = 0.5
    n = int(dur * SR)
    k = np.arange(n) / n
    cut = 2400 - 900 * k
    grit = bp(noise(dur), cut, 2.2) * (0.6 + 0.4 * np.sign(np.sin(2 * np.pi * 75 * t_axis(dur))))
    grit *= env_ad(n, 0.01, 0.2) * np.clip((1 - k) / 0.2, 0, 1)
    ring = (metal(1480, dur, 0.16, (1, 1.45, 2.2), (1, 0.6, 0.4)) + metal(2310, dur, 0.1, (1, 1.62), (0.7, 0.4)) * 0.8) * 0.4
    return fade(lp(grit * 1.1 + ring, 6500), 0.002, 0.08)


def s_puck_clack():
    # Crash Cassidy: hard plastic on ice, twice in quick succession
    def clack(g):
        c = plus(metal(1900, 0.06, 0.012, (1, 1.63, 2.9), (1, 0.6, 0.3)), tick(0.05, 3400, 2.0, 0.003) * 0.8)
        k = thump(700, 380, 0.05, 0.012, 1.5) * 0.7
        return plus(c, k) * g
    out = mix(0.2, (0, clack(1.0), 1.0), (0.05, clack(0.6), 1.0))
    return fade(lp(out, 6000), 0.0008, 0.04)


def s_skate_roll():
    # Crash Cassidy: a skate gliding: low wheel rumble with a wobble plus a thin ice hiss
    dur = 0.55
    n = int(dur * SR)
    k = np.arange(n) / n
    t = t_axis(dur)
    rumble = lp(bp(noise(dur), 520, 1.0), 1400) * (0.65 + 0.35 * np.sin(2 * np.pi * 15 * t))
    hiss = lp(hp(noise(dur), 2600), 5600) * 0.035
    env = np.sin(np.pi * np.clip(k, 0, 1)) ** 0.8
    return fade((rumble * 2.2 + hiss) * env, 0.01, 0.1)


def s_glove_thud():
    # Knuckles: a leather glove on a heavy bag
    n = int(0.22 * SR)
    body = thump(500, 170, 0.22, 0.06, 2.8)
    slap = lp(bp(noise(0.22), 1000, 1.2), 2500) * env_ad(n, 0.0006, 0.014) * 2.0
    tch = tick(0.05, 3300, 1.6, 0.006) * 0.35
    return fade(mix(0.24, (0, body, 0.9), (0, slap, 0.65), (0, tch, 1.0)), 0.001, 0.05)


def s_glove_bell():
    # Knuckles: a small boxing-ring bell, two quick strikes
    a = metal(1520, 0.6, 0.28, (1, 2.0, 3.0, 4.2), (1, 0.55, 0.3, 0.15))
    b = metal(1520, 0.5, 0.24, (1, 2.0, 3.0, 4.2), (1, 0.55, 0.3, 0.15))
    x = mix(0.8, (0, a, 0.8), (0.11, b, 0.6))
    return trim_tail(reverb(fade(lp(x, 7500), 0.001, 0.08), 0.5, 0.15, 5000))


def s_shoe_boing():
    # Peter: spring-loaded sneakers: a rising boing whose wobble slows down as it fades
    dur = 0.5
    n = int(dur * SR)
    t = t_axis(dur)
    depth = 0.45 * np.exp(-t / 0.2)
    f = 330 * (0.85 + 0.2 * (1 - np.exp(-t / 0.08))) * (1 + depth * np.sin(2 * np.pi * (22 - 10 * t / dur) * t))
    ph = 2 * np.pi * np.cumsum(f) / SR
    x = (np.sin(ph) + 0.35 * np.sin(2 * ph) + 0.15 * np.sin(3 * ph)) * env_ad(n, 0.004, 0.17)
    return fade(lp(soft_clip(x, 1.5), 5200), 0.001, 0.08)


def s_seed_sprout():
    # Barry: soil pop, a leafy rustle and two rising wooden plinks
    dur = 0.6
    n = int(dur * SR)
    rustle = lp(hp(noise(dur), 2400), 5200) * np.sin(np.pi * np.arange(n) / n) ** 2 * 0.045
    soil = lp(noise(0.12), 700) * env_ad(int(0.12 * SR), 0.002, 0.025) * 1.2
    a = bell(note(79), 0.35, decay=0.08, bright=0.25, ratios=(1, 3.9, 9.2))
    b = bell(note(86), 0.4, decay=0.09, bright=0.25, ratios=(1, 3.9, 9.2))
    x = mix(dur, (0, rustle, 1.0), (0, soil, 0.6), (0.06, a, 0.6), (0.17, b, 0.55))
    return trim_tail(reverb(fade(lp(x, 7000), 0.002, 0.1), 0.4, 0.12, 5000))


# --- run stage cues -------------------------------------------------------------------

def s_beacon_activate():
    # a gong strike, a rising crystal sparkle, a warm chord that blooms and settles
    dur = 2.6
    gong = metal(196, dur, 1.0, (1, 1.59, 2.14, 2.3, 2.65, 3.5), (0.8, 0.8, 0.7, 0.6, 0.45, 0.3))
    gong = lp(gong, 2500)
    sparkle = arp([74, 81, 86, 90, 93, 98], 0.07, 1.7, decay=0.4, bright=0.3)
    p = pad([note(50), note(57), note(62), note(66)], 2.0, attack=0.25, release=1.0, bright=1500)
    kick = thump(240, 90, 0.4, 0.09, 2.4)
    x = mix(dur, (0, gong, 0.55), (0, kick, 0.6), (0.2, sparkle, 0.4), (0.15, p, 0.8))
    return trim_tail(reverb(fade(lp(x, 7000), 0.001, 0.15), 1.8, 0.3, 4000))


def s_beacon_charge():
    # a seamless 2 s hum for the charge: every frequency is a whole number of cycles per loop
    dur = 2.0
    t = t_axis(dur)
    w = 2 * np.pi * t
    pulse = 0.5 + 0.5 * (0.5 + 0.5 * np.sin(2 * w - np.pi / 2)) ** 2
    base = 0.45 * np.sin(220 * w) + np.sin(330 * w + 1.0) + 0.8 * np.sin(440 * w + 2.0) + 0.4 * np.sin(660 * w)
    shim = np.sin(880 * w) * (0.5 + 0.5 * np.sin(0.5 * w)) + 0.6 * np.sin(1320 * w) * (0.5 + 0.5 * np.sin(1.5 * w + 1.0))
    return soft_clip((base * pulse + shim * 0.22) / 2.6, 1.4)


def s_boss_spawn():
    # a swell that sucks the air in, then a dark brass stab on a tritone and a timpani hit
    dur = 3.0
    sw_n = int(0.9 * SR)
    sw_k = np.arange(sw_n) / sw_n
    swell = bp(noise(0.9), 300 * (3500 / 300) ** (sw_k ** 1.3), 1.6) * sw_k ** 2
    stab = mix(dur, (0.0, horn_voice(53, 1.7, 1.0, 1300), 1.0), (0.0, horn_voice(59, 1.7, 0.9, 1300), 1.0), (0.0, horn_voice(65, 1.4, 0.5, 1800), 1.0))
    drum = thump(210, 70, 1.2, 0.22, 2.8)
    crack = lp(noise(0.6), 1500) * env_ad(int(0.6 * SR), 0.002, 0.08)
    x = mix(dur, (0, swell, 0.9), (0.8, stab, 0.7), (0.8, drum, 1.0), (0.8, crack, 0.6))
    return trim_tail(reverb(fade(x, 0.003, 0.3), 2.0, 0.3, 2400))


def s_run_victory():
    # bright "ta-da": a quick rising run, a held major chord with bells, a shimmer on top
    dur = 3.0
    run = arp([60, 64, 67, 72, 76], 0.08, 1.2, decay=0.3, bright=0.3)
    chord = mix(dur, (0.4, horn_voice(72, 2.2, 0.8, 2400), 1.0), (0.4, horn_voice(76, 2.2, 0.6, 2400), 1.0),
                (0.4, horn_voice(79, 2.2, 0.6, 2400), 1.0), (0.4, horn_voice(60, 2.2, 0.5, 1400), 1.0))
    bells = arp([84, 88, 91, 96], 0.09, 2.0, decay=0.6, bright=0.3)
    p = pad([note(60), note(67), note(76)], 2.4, attack=0.15, release=1.2, bright=2000)
    x = mix(dur, (0, run, 0.55), (0, chord, 0.7), (0.4, bells, 0.4), (0.4, p, 0.7))
    return trim_tail(reverb(fade(lp(x, 8000), 0.002, 0.2), 2.0, 0.3, 4500))


def s_run_defeat():
    # a slow, muted fall: three low brass notes stepping down, a dull thud, a long dark tail
    dur = 3.2
    notes = [(0.0, 64, 0.7), (0.55, 62, 0.7), (1.1, 59, 1.8)]
    x = silence(dur)
    for at, m, d in notes:
        place(x, horn_voice(m, d, 0.9, 900, 1.006), at)
        place(x, horn_voice(m - 7, d, 0.35, 800, 1.006), at)
    place(x, thump(260, 80, 1.0, 0.18, 2.6) * 0.8, 1.1)
    t = t_axis(dur)
    after = np.clip(t - 1.1, 0, None)
    sag = lp(np.sin(2 * np.pi * np.cumsum(330 * (0.6 ** (after / 2.0))) / SR), 1400) * np.exp(-after / 0.9) * (t > 1.1) * 0.35
    return trim_tail(reverb(fade(x + sag, 0.004, 0.4), 2.4, 0.35, 2200))


def s_downed():
    # a hero going down: a thump, a falling wobbly tone, a puff of breath
    dur = 0.95
    n = int(dur * SR)
    t = t_axis(dur)
    hit = thump(400, 120, 0.4, 0.09, 2.6)
    f = 900 * (0.33 ** (t / dur))
    ph = 2 * np.pi * np.cumsum(f) / SR
    fall = np.sin(ph + 0.4 * np.sin(2 * np.pi * 7 * t)) * (0.7 + 0.3 * np.sin(2 * np.pi * 9 * t)) * env_ad(n, 0.01, 0.35)
    puff = lp(noise(dur), 1300) * env_ad(n, 0.004, 0.1) * 0.5
    x = mix(dur, (0, hit, 0.9), (0.03, fall, 0.6), (0, puff, 0.7))
    return trim_tail(reverb(fade(lp(x, 4500), 0.001, 0.15), 0.8, 0.2, 2600))


def s_revive_beat():
    # a soft warm pulse for the revive hold (the game re-pitches it up as the ring fills)
    dur = 0.34
    t = t_axis(dur)
    x = (np.sin(2 * np.pi * 440 * t) + 0.3 * np.sin(2 * np.pi * 880 * t) + 0.12 * np.sin(2 * np.pi * 1320 * t)) * env_ad(len(t), 0.012, 0.09)
    return trim_tail(reverb(fade(lp(x, 4500), 0.002, 0.08), 0.4, 0.18, 3500))


def s_chest_buy():
    # coins dropping into the lock, then a latch: ka-chunk
    out = silence(0.8)
    for i, (at, m) in enumerate([(0.0, 91), (0.055, 88), (0.11, 93), (0.17, 90)]):
        place(out, metal(note(m), 0.12, 0.03, (1, 2.42, 4.1), (1, 0.5, 0.25)) * (0.8 - 0.1 * i), at)
    latch = plus(thump(340, 150, 0.22, 0.05, 2.6), tick(0.04, 2200, 3.0, 0.006) * 0.8)
    place(out, latch * 0.9, 0.26)
    place(out, tick(0.03, 3800, 3.0, 0.004) * 0.5, 0.3)
    return trim_tail(reverb(fade(lp(out, 7500), 0.001, 0.1), 0.5, 0.15, 4500))


def s_crit_tick():
    # a small bright "tink" with a quick upward chirp, easy to pick out and short
    dur = 0.16
    cn = int(0.03 * SR)
    chirp = np.sin(sweep_phase(2100, 3400, cn, 0.7)) * env_ad(cn, 0.0006, 0.012)
    ping = metal(2900, dur, 0.035, (1, 2.4, 4.1), (1, 0.4, 0.2))
    x = mix(dur, (0, ping, 0.8), (0, chirp, 0.7), (0, tick(0.02, 5000, 2.0, 0.003), 0.3))
    return fade(lp(x, 8500), 0.0006, 0.04)


NEW_SOUNDS = {
    "ScrapClatter": s_scrap_clatter, "ToastPop": s_toast_pop, "BubbleBloop": s_bubble, "YarnPop": s_yarn_pop,
    "DodgeballThump": s_dodgeball_thump, "DodgeballWhistle": s_dodgeball_whistle, "MopSwoosh": s_mop_swoosh,
    "MopSqueak": s_mop_squeak, "ConfettiRattle": s_confetti_rattle, "ConfettiHonk": s_confetti_honk,
    "GymScrape": s_gym_scrape, "PuckClack": s_puck_clack, "SkateRoll": s_skate_roll, "GloveThud": s_glove_thud,
    "GloveBell": s_glove_bell, "ShoeBoing": s_shoe_boing, "SeedSprout": s_seed_sprout,
    "BeaconActivate": s_beacon_activate, "BeaconCharge": s_beacon_charge, "BossSpawn": s_boss_spawn,
    "RunVictory": s_run_victory, "RunDefeat": s_run_defeat, "Downed": s_downed, "ReviveBeat": s_revive_beat,
    "ChestBuy": s_chest_buy, "CritTick": s_crit_tick,
}
# looped files: written as they are (no tail trim, no fade), see write()
LOOPS = {"BeaconCharge"}


SOUNDS = {
    "Hit": s_hit, "EnemyDeath": s_enemy_death, "GemPickup": s_gem, "LevelUp": s_level_up,
    "Chest": s_chest, "PortalAppear": s_portal, "BossRoar": s_boss_roar, "Click": s_click,
    "Coin": s_coin, "Hurt": s_hurt, "BigKill": s_big_kill, "Explosion": s_explosion,
    "Lightning": s_lightning, "Swing": s_swing, "Heartbeat": s_heartbeat, "Death": s_death,
    "Revive": s_revive, "Item": s_item, "Shrine": s_shrine, "Evolve": s_evolve,
    "Victory": s_victory, "Toggle": s_toggle, "Tip": s_tip, "ReelTick": s_reel_tick,
    "BossSlam": s_boss_slam, "BossWhoosh": s_boss_whoosh,
}
SOUNDS.update(NEW_SOUNDS)


def write(name, x, keep_wav):
    x = x - np.mean(x)
    x = x / (np.max(np.abs(x)) + 1e-9) * 10 ** (-1 / 20)  # peak -1 dBFS; Config sets loudness
    pcm = (x * 32767).astype(np.int16)
    os.makedirs(OUT, exist_ok=True)
    wav = os.path.join(OUT, name + ".wav")
    with wave.open(wav, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    ogg = os.path.join(OUT, name + ".ogg")
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", wav, "-c:a", "libvorbis", "-q:a", "6", ogg], check=True)
    if not keep_wav:
        os.remove(wav)
    rms = 20 * math.log10(np.sqrt(np.mean(x ** 2)) + 1e-9)
    spec = np.abs(np.fft.rfft(x))
    freqs = np.fft.rfftfreq(len(x), 1 / SR)
    centroid = float(np.sum(freqs * spec) / (np.sum(spec) + 1e-9))
    power = spec ** 2
    above = float(np.sum(power[freqs >= 250]) / (np.sum(power) + 1e-12)) * 100  # phone speakers drop < 250 Hz
    harsh = float(np.sum(power[freqs >= 5000]) / (np.sum(power) + 1e-12)) * 100  # hiss above 5 kHz (the first batch is under 6 %)
    print(f"{name:<16} {len(x) / SR:5.2f}s  rms {rms:6.1f} dBFS  centroid {centroid:6.0f} Hz  >250Hz {above:5.1f}%  >5kHz {harsh:5.1f}%  peak {np.max(np.abs(x)):.2f}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--wav", action="store_true", help="keep the .wav next to the .ogg")
    ap.add_argument("--new", action="store_true", help="only the second batch (stream G); the first 26 are already uploaded and a re-render would not match their ids")
    args = ap.parse_args()
    only = {x for x in args.only.split(",") if x}
    if args.new:
        only |= set(NEW_SOUNDS)
    for name, fn in SOUNDS.items():
        if only and name not in only:
            continue
        if name in NEW_SOUNDS:
            reseed(name)  # the second batch is reproducible one by one
        write(name, fn(), args.wav)


if __name__ == "__main__":
    main()
