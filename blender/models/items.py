"""Projectiles, XP crystals, floor pickups and the treasure chest."""

import math

from swarmkit import register


def rgb(h):
    return tuple(int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))


# ------------------------------------------------------------------ projectiles
# Projectiles are centred on their origin (not on the ground) and fly toward -Y.

@register("Shot_Orb", "Projectiles", "Magic Orb / Twin Orbs (recoloured).")
def shot_orb(m):
    m.extra["palette"] = {"Glow": rgb("a35bff"), "White": rgb("ffffff")}
    core = m.piece("Core", "White", "Neon")
    core.ico(0.45, subdiv=1)
    shell = m.piece("Shell", "Glow", "Neon")
    shell.ico(0.75, subdiv=2)
    ring = m.piece("Ring", "Glow", "Neon", anim="Spin")
    for i in range(6):
        a = i / 6 * math.tau
        ring.box((0.22, 0.22, 0.22), loc=(math.cos(a) * 1.0, math.sin(a) * 1.0, 0), rot=(45, 45, 0), bevel=0.0)


@register("Shot_Knife", "Projectiles", "Throwing knife / Thousand Edge (recoloured).")
def shot_knife(m):
    m.extra["palette"] = {"Metal": rgb("dfe4ee"), "Gold": rgb("f2c14e"), "Wood": rgb("5b3b25")}
    blade = m.piece("Blade", "Metal", "Metal")
    blade.prism([(-0.2, 0.0), (0.2, 0.0), (0.12, 1.3), (0.0, 1.7), (-0.12, 1.3)], 0.07, loc=(0, -0.3, 0), rot=(90, 0, 0))
    guard = m.piece("Guard", "Gold", "Metal")
    guard.box((0.7, 0.14, 0.16), loc=(0, -0.25, 0), bevel=0.03)
    grip = m.piece("Grip", "Wood")
    grip.box((0.18, 0.75, 0.18), loc=(0, 0.2, 0), bevel=0.04)
    grip.ico(0.13, loc=(0, 0.62, 0), subdiv=0)


@register("Shot_Bottle", "Projectiles", "Holy Water / Hellfire bottle (recoloured).")
def shot_bottle(m):
    m.extra["palette"] = {"Glow": rgb("4aa3ff"), "Light": rgb("cfeaff"), "Wood": rgb("9b6b3c")}
    glass = m.piece("Glass", "Light", "Glass")
    glass.ico(0.55, loc=(0, 0, -0.1), subdiv=1)
    glass.cyl(0.2, 0.18, 0.5, seg=6, loc=(0, 0, 0.6))
    liquid = m.piece("Liquid", "Glow", "Neon")
    liquid.ico(0.42, loc=(0, 0, -0.18), subdiv=1)
    cork = m.piece("Cork", "Wood")
    cork.cyl(0.21, 0.2, 0.22, seg=6, loc=(0, 0, 0.92))


@register("Shot_Axe", "Projectiles", "Axe / Death Spiral axe (recoloured).")
def shot_axe(m):
    m.extra["palette"] = {"Metal": rgb("c4cad6"), "Wood": rgb("6b4a2c"), "Dark": rgb("3a3f4c")}
    handle = m.piece("Handle", "Wood")
    handle.box((0.22, 2.4, 0.22), bevel=0.05)
    head = m.piece("Head", "Metal", "Metal")
    head.prism([(0.0, -0.25), (0.0, 0.25), (0.9, 0.7), (1.05, 0.0), (0.9, -0.7)], 0.16, loc=(0.1, -0.95, 0), rot=(90, 0, 0))
    head.prism([(0.0, -0.2), (0.0, 0.2), (-0.55, 0.45), (-0.62, 0.0), (-0.55, -0.45)], 0.16, loc=(-0.1, -0.95, 0), rot=(90, 0, 0))
    band = m.piece("Band", "Dark")
    band.box((0.3, 0.45, 0.3), loc=(0, -0.95, 0), bevel=0.04)


@register("Shot_Boomerang", "Projectiles", "Boomerang / Infinite Return (recoloured).")
def shot_boomerang(m):
    m.extra["palette"] = {"Wood": rgb("cf9a55"), "Accent": rgb("c83a2d")}
    body = m.piece("Body", "Wood")
    paint = m.piece("Paint", "Accent")
    apex = (0.0, -0.6, 0.0)
    for side in (-1, 1):
        d = (side * math.sin(math.radians(50)), math.cos(math.radians(50)), 0)
        mid = (apex[0] + d[0] * 0.8, apex[1] + d[1] * 0.8, 0)
        tip = (apex[0] + d[0] * 1.55, apex[1] + d[1] * 1.55, 0)
        body.box((0.55, 1.75, 0.2), loc=mid, rot=(0, 0, -side * 50), bevel=0.06)
        paint.box((0.58, 0.3, 0.22), loc=tip, rot=(0, 0, -side * 50), bevel=0.04)
    body.ico(0.36, loc=apex, scale=(1, 1, 0.3), subdiv=1)


@register("Shot_Stinger", "Projectiles", "Boss stinger orb.")
def shot_stinger(m):
    m.extra["palette"] = {"Glow": rgb("ff5a1e"), "Dark": rgb("2a1a1a")}
    core = m.piece("Core", "Glow", "Neon")
    core.ico(0.8, subdiv=1)
    spikes = m.piece("Spikes", "Dark", anim="Spin")
    for i in range(6):
        a = i / 6 * math.tau
        spikes.spike(0.2, 0.7, seg=4, base=(math.cos(a) * 0.6, math.sin(a) * 0.6, 0), direction=(math.cos(a), math.sin(a), 0))


# ------------------------------------------------------------------ XP crystals

@register("Crystal", "Pickups", "XP crystal (scaled and recoloured per gem size).")
def crystal(m):
    m.extra["palette"] = {"Glow": rgb("b05bff"), "Light": rgb("e6c9ff")}
    c = m.piece("Crystal", "Glow", "Neon")
    c.cyl(0.35, 0.0, 0.7, seg=5, loc=(0, 0, 0.95))
    c.cyl(0.0, 0.35, 0.5, seg=5, loc=(0, 0, 0.35), rot=(0, 0, 36))
    shine = m.piece("Shine", "Light", "Glass")
    shine.cyl(0.42, 0.42, 0.06, seg=5, loc=(0, 0, 0.6))


# ------------------------------------------------------------------ floor pickups

@register("Pickup_Chicken", "Pickups", "Roast chicken: heals.")
def chicken(m):
    m.extra["palette"] = {"Base": rgb("c4762e"), "Light": rgb("f6eedd"), "Dark": rgb("8a4a1c")}
    meat = m.piece("Meat", "Base")
    meat.ico(0.9, loc=(0, 0, 0.75), scale=(1.2, 1, 0.85), subdiv=1)
    crisp = m.piece("Crisp", "Dark")
    crisp.ico(0.55, loc=(0.3, -0.2, 1.25), scale=(1.2, 1, 0.5), subdiv=1)
    bone = m.piece("Bone", "Light")
    bone.limb((-0.8, 0, 0.8), (-1.7, 0, 1.2), 0.15, 0.13, seg=6)
    bone.ico(0.22, loc=(-1.75, 0.1, 1.25), subdiv=1)
    bone.ico(0.22, loc=(-1.75, -0.12, 1.2), subdiv=1)


@register("Pickup_Magnet", "Pickups", "Magnet: pulls every crystal.")
def magnet(m):
    m.extra["palette"] = {"Accent": rgb("e0302a"), "Metal": rgb("dfe4ee")}
    body = m.piece("Body", "Accent")
    body.box((1.8, 0.6, 0.55), loc=(0, 0, 0.35), bevel=0.12)
    for x in (-0.65, 0.65):
        body.box((0.55, 0.6, 1.2), loc=(x, 0, 1.15), bevel=0.1)
    tips = m.piece("Tips", "Metal", "Metal")
    for x in (-0.65, 0.65):
        tips.box((0.58, 0.63, 0.4), loc=(x, 0, 1.9), bevel=0.06)


@register("Pickup_Bomb", "Pickups", "Bomb: clears the screen.")
def bomb(m):
    m.extra["palette"] = {"Dark": rgb("24242c"), "Metal": rgb("8a8f9c"), "Glow": rgb("ffb52b"), "Wood": rgb("a2804f")}
    body = m.piece("Body", "Dark", "Metal")
    body.ico(0.9, loc=(0, 0, 0.9), subdiv=2)
    cap = m.piece("Cap", "Metal", "Metal")
    cap.cyl(0.32, 0.3, 0.3, seg=6, loc=(0, 0, 1.85))
    fuse = m.piece("Fuse", "Wood")
    fuse.chain([(0, 0, 1.95), (0.15, 0, 2.3), (0.35, 0, 2.45)], [0.07, 0.06, 0.05], seg=4)
    spark = m.piece("Spark", "Glow", "Neon", anim="Flicker")
    spark.ico(0.2, loc=(0.4, 0, 2.5), subdiv=0)


@register("Chest", "Pickups", "Elite treasure chest.")
def chest(m):
    m.extra["palette"] = {"Wood": rgb("8a5530"), "Gold": rgb("f2c14e"), "Glow": rgb("ffe27a"), "Dark": rgb("4a2c18")}
    box = m.piece("Box", "Wood")
    box.box((3.0, 2.0, 1.5), loc=(0, 0, 0.8), bevel=0.1)
    lid = m.piece("Lid", "Wood", anim="Jaw", pivot=(0, 1.0, 1.6))
    lid.box((3.05, 2.05, 0.7), loc=(0, 0, 1.95), taper=(0.92, 0.8), bevel=0.15)
    bands = m.piece("Bands", "Gold", "Metal")
    for x in (-1.15, 1.15):
        bands.box((0.25, 2.1, 1.6), loc=(x, 0, 0.8), bevel=0.04)
    for x in (-1.15, 1.15):
        bands.box((0.27, 2.1, 0.7), loc=(x, 0, 1.95), taper=(1, 0.8), bevel=0.05)
    lock = m.piece("Lock", "Glow", "Neon")
    lock.box((0.5, 0.18, 0.6), loc=(0, -1.06, 1.45), bevel=0.06)
