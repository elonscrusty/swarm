"""Synthesize SWARM's original sound effects (numpy only) into art/audio/<Name>.ogg.

    python3 tools/synth_sfx.py [--only A,B] [--wav]

Everything here is generated from sine/noise oscillators, filters and a small
algorithmic reverb, so the files are original and free to upload. Deterministic (seeded).
Upload with tools/upload_audio.py; the slot -> file mapping is in docs/AUDIO.md.

Style: warm fantasy, not chiptune. Frequent sounds (Hit, EnemyDeath, GemPickup, Coin,
Click) are short, low-passed and soft-edged; rare rewards (LevelUp, Chest, Evolve,
PortalAppear, BossRoar) are longer, richer and carry a reverb tail.
"""

import argparse
import math
import os
import subprocess
import wave

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
    body = sine_sweep(210, 85, 0.14, 0.6) * env_ad(int(0.14 * SR), 0.002, 0.035)
    knock = lp(bp(noise(0.14), 900, 1.5), 2500) * env_ad(int(0.14 * SR), 0.001, 0.012)
    return fade(body * 0.9 + knock * 0.5, 0.001, 0.03)


def s_enemy_death():
    # muffled "poof": noise through a closing low-pass + a small low pop
    n = int(0.32 * SR)
    cut = 2600 * (380 / 2600) ** (np.arange(n) / n)
    puff = lp(noise(0.32), cut, 0.9) * env_ad(n, 0.004, 0.07)
    pop = sine_sweep(160, 55, 0.32, 0.5) * env_ad(n, 0.002, 0.05)
    return fade(puff * 0.8 + pop * 0.7, 0.001, 0.05)


def s_big_kill():
    n = int(0.9 * SR)
    sub = sine_sweep(95, 38, 0.9, 0.5) * env_ad(n, 0.003, 0.16)
    cut = 1400 * (180 / 1400) ** (np.arange(n) / n)
    rumble = lp(noise(0.9), cut, 0.8) * env_ad(n, 0.004, 0.18)
    x = soft_clip(sub * 1.0 + rumble * 0.6, 1.4)
    return trim_tail(reverb(x, 0.8, 0.18, 1500))


def s_explosion():
    n = int(1.1 * SR)
    cut = 3200 * (160 / 3200) ** ((np.arange(n) / n) ** 0.6)
    blast = lp(noise(1.1), cut, 0.8) * env_ad(n, 0.003, 0.22)
    sub = sine_sweep(80, 32, 1.1, 0.5) * env_ad(n, 0.002, 0.2)
    x = soft_clip(blast * 0.9 + sub * 0.9, 1.6)
    return trim_tail(reverb(x, 1.0, 0.2, 1800))


def s_lightning():
    # crackle: sparse filtered noise bursts over a quick downward zap, mellowed
    dur = 0.45
    n = int(dur * SR)
    cr = noise(dur) * (rng.random(n) < 0.08)
    cr = bp(cr, 2400, 1.2) * env_ad(n, 0.001, 0.09) * 3
    zap = sine_sweep(1400, 180, dur, 0.4) * env_ad(n, 0.001, 0.05) * 0.4
    body = lp(noise(dur), 900) * env_ad(n, 0.002, 0.08) * 0.6
    return trim_tail(reverb(fade(cr + zap + body, 0.001, 0.05), 0.6, 0.15, 3000))


def s_swing():
    # airy whoosh: band-pass sweep up then down, bell-shaped envelope
    dur = 0.26
    n = int(dur * SR)
    k = np.arange(n) / n
    cut = 500 + 1600 * np.sin(np.pi * k) ** 1.5
    w = bp(noise(dur), cut, 1.4) * np.sin(np.pi * k) ** 2
    return fade(w, 0.002, 0.02)


def s_hurt():
    n = int(0.32 * SR)
    punch = sine_sweep(170, 60, 0.32, 0.5) * env_ad(n, 0.002, 0.06)
    crunch = lp(noise(0.32), 1300) * env_ad(n, 0.001, 0.03)
    grunt = lp(np.sign(np.sin(sweep_phase(120, 85, n))), 700) * env_ad(n, 0.01, 0.07) * 0.35
    return fade(soft_clip(punch + crunch * 0.7 + grunt, 1.3), 0.001, 0.05)


def s_heartbeat():
    def thump():
        n = int(0.16 * SR)
        return lp(sine_sweep(75, 42, 0.16, 0.5) * env_ad(n, 0.006, 0.045), 300)
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
    thud = sine_sweep(90, 40, dur, 0.3) * env_ad(len(t), 0.002, 0.12)
    return trim_tail(reverb(out + thud * 0.8, 1.6, 0.3, 2500))


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
    sub = sine_sweep(70, 28, 1.2, 0.4) * env_ad(n, 0.002, 0.25)
    cut = 1800 * (120 / 1800) ** ((np.arange(n) / n) ** 0.5)
    crack = lp(noise(1.2), cut) * env_ad(n, 0.002, 0.12)
    x = soft_clip(sub + crack * 0.8, 1.8)
    return trim_tail(reverb(x, 1.3, 0.22, 1500))


def s_evolve():
    # transformation: swelling shimmer + upward two-octave run + a bright chord
    dur = 2.0
    run = arp([60, 64, 67, 72, 76, 79, 84], 0.06, dur, decay=0.35, bright=0.3)
    p = pad([note(48), note(60), note(64), note(67)], dur, attack=0.5, release=1.0, bright=2200)
    n = int(dur * SR)
    k = np.arange(n) / n
    shimmer = bp(noise(dur), 3000 + 3000 * k, 6.0) * np.clip(k / 0.4, 0, 1) * np.clip((1 - k) / 0.5, 0, 1) * 0.5
    x = mix(dur, (0, run, 0.45), (0, p, 0.9), (0, shimmer, 0.5))
    return trim_tail(reverb(fade(lp(x, 8000), 0.005, 0.15), 2.0, 0.35, 5000))


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
    return trim_tail(reverb(fade(w + rumble, 0.005, 0.05), 0.9, 0.2, 2000))


SOUNDS = {
    "Hit": s_hit, "EnemyDeath": s_enemy_death, "GemPickup": s_gem, "LevelUp": s_level_up,
    "Chest": s_chest, "PortalAppear": s_portal, "BossRoar": s_boss_roar, "Click": s_click,
    "Coin": s_coin, "Hurt": s_hurt, "BigKill": s_big_kill, "Explosion": s_explosion,
    "Lightning": s_lightning, "Swing": s_swing, "Heartbeat": s_heartbeat, "Death": s_death,
    "Revive": s_revive, "Item": s_item, "Shrine": s_shrine, "Evolve": s_evolve,
    "Victory": s_victory, "Toggle": s_toggle, "Tip": s_tip, "ReelTick": s_reel_tick,
    "BossSlam": s_boss_slam, "BossWhoosh": s_boss_whoosh,
}


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
    print(f"{name:<13} {len(x) / SR:5.2f}s  rms {rms:6.1f} dBFS  centroid {centroid:6.0f} Hz")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--wav", action="store_true", help="keep the .wav next to the .ogg")
    args = ap.parse_args()
    only = {x for x in args.only.split(",") if x}
    for name, fn in SOUNDS.items():
        if only and name not in only:
            continue
        write(name, fn(), args.wav)


if __name__ == "__main__":
    main()
