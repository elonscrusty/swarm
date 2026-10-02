"""Event props: timed-challenge brazier and ground ring, the guarded-reward altar and the
bargain shrine.

Same conventions as world.py: origin = ground centre, front = -Y (Roblox -Z), stone in three
tones split by piece, colours from style.P. Slots the game recolours by state:
  Challenge_Brazier  Runes (rune ring + face runes) and Flame / FlameCore (Neon):
                     idle / active / done / failed
  Challenge_Ring     Runes (inlaid ticks) and Glow (four small Neon markers)
  Shrine_Bargain     Sigil (crimson plate) and Glow (offering ember)
Extras (meshes/catalog.json): collider, light, top (surface height a prop sits on).
"""

import math
import random

from swarmkit import register
from style import P

from ._biomekit import pad
from ._propkit import (TAU, annular_block, blob_points, flame, hull, light_at, loft, prism_xz, ring, roblox_xz,
                       sheet)
from .world import crown_plate


def oct_ring(w, d, z, c=0.18, cx=0.0, cy=0.0):
    hw, hd = w / 2, d / 2
    pts = [(-hw + c, -hd, z), (hw - c, -hd, z), (hw, -hd + c, z), (hw, hd - c, z),
           (hw - c, hd, z), (-hw + c, hd, z), (-hw, hd - c, z), (-hw, -hd + c, z)]
    return [(x + cx, y + cy, zz) for x, y, zz in pts]


# ------------------------------------------------------------------ challenge brazier

@register("Challenge_Brazier", "Events", "Timed-challenge marker: chamfered stone obelisk on a two-step plinth with a "
          "floating gold rune ring and a fire bowl, ~3 x 6.4. Recolour Runes and Flame/FlameCore per state "
          "(idle, active, done, failed). Collider circle; light = flame.")
def challenge_brazier(m):
    m.extra["palette"] = {"Base": P("stone_600"), "Stone": P("stone_500"), "Trim": P("stone_400"),
                          "Iron": P("steel_700"), "Runes": P("gold_500"), "Flame": P("fx_fire"), "Core": P("gold_300"),
                          "Moss": P("moss_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.5, "height": 6}
    m.extra["light"] = light_at(0, 0, 5.75)
    base = m.piece("Plinth", "Base", shadow=True)
    base.box((3.0, 3.0, 0.45), loc=(0, 0, 0.18), bevel=0.09)
    base.box((2.3, 2.3, 0.4), loc=(0, 0, 0.6), bevel=0.08)
    stone = m.piece("Shaft", "Stone", shadow=True)
    loft(stone, [oct_ring(1.6, 1.6, 0.78, c=0.26), oct_ring(1.5, 1.5, 2.0, c=0.24), oct_ring(1.28, 1.28, 4.35, c=0.2)])
    trim = m.piece("Trim", "Trim", shadow=True)
    loft(trim, [oct_ring(1.85, 1.85, 0.78, c=0.3), oct_ring(1.85, 1.85, 1.02, c=0.3), oct_ring(1.68, 1.68, 1.1, c=0.28)])
    loft(trim, [oct_ring(1.5, 1.5, 4.3, c=0.24), oct_ring(1.72, 1.72, 4.42, c=0.28), oct_ring(1.72, 1.72, 4.62, c=0.28),
                oct_ring(1.3, 1.3, 4.7, c=0.22)])
    # fire bowl
    iron = m.piece("Bowl", "Iron", "Metal")
    n = 8
    loft(iron, [ring(n, 0.5, 4.62, phase=TAU / 16), ring(n, 0.95, 5.05, phase=TAU / 16), ring(n, 1.08, 5.3, phase=TAU / 16),
                ring(n, 0.92, 5.3, phase=TAU / 16), ring(n, 0.7, 5.08, phase=TAU / 16)])
    for k in range(4):
        a = k * TAU / 4 + TAU / 8
        iron.spike(0.08, 0.32, seg=3, base=(math.cos(a) * 1.0, math.sin(a) * 1.0, 5.25),
                   direction=(math.cos(a) * 0.35, math.sin(a) * 0.35, 1))
    # rune ring: 12 curved gold segments floating round the shaft, plus carved runes on each face
    runes = m.piece("Runes", "Runes")
    for k in range(12):
        a0, a1 = k * 30 + 4, (k + 1) * 30 - 4
        annular_block(runes, 1.12, 1.32, a0, a1, 2.55, 2.75, bevel=0.0, mid=True)
    for k in range(4):  # four little hangers tie the ring to the shaft
        a = math.radians(k * 90 + 45)
        runes.box((0.42, 0.08, 0.08), loc=(math.cos(a) * 0.98, math.sin(a) * 0.98, 2.65), rot=(0, 0, k * 90 + 45), bevel=0.0)
    for k in range(4):  # rune glyph on each face (vertical bar with two ticks)
        a = k * 90
        rad = math.radians(a - 90)
        fx, fy = math.cos(rad), math.sin(rad)
        face = 0.73 + 0.02
        cx, cy = fx * face, fy * face
        runes.box((0.12, 0.08, 0.7) if fy else (0.08, 0.12, 0.7), loc=(cx, cy, 3.5), bevel=0.0)
        for dz, side in ((0.15, 1), (-0.12, -1)):
            off = 0.13 * side
            runes.box((0.22, 0.08, 0.09) if fy else (0.08, 0.22, 0.09),
                      loc=(cx + (off if fy else 0), cy + (0 if fy else off), 3.5 + dz), bevel=0.0)
    for k in range(4):  # gold corner studs on the upper plinth
        a = math.radians(k * 90 + 45)
        runes.box((0.22, 0.22, 0.08), loc=(math.cos(a) * 1.35, math.sin(a) * 1.35, 0.83), rot=(0, 0, 45), bevel=0.0)
    fl = m.piece("Flame", "Flame", "Neon")
    flame(fl, (0, 0, 5.0), 0.55, 1.55, seg=5, lean=(0.05, -0.03))
    flame(fl, (0.3, 0.15, 5.05), 0.28, 0.85, seg=4, twist=40, lean=(0.15, 0.06))
    flame(fl, (-0.28, -0.12, 5.05), 0.28, 0.9, seg=4, twist=-30, lean=(-0.12, -0.05))
    flame(fl, (0.05, 0.32, 5.05), 0.24, 0.7, seg=4, twist=15, lean=(0.0, 0.12))
    core = m.piece("FlameCore", "Core", "Neon")
    flame(core, (0, 0, 5.1), 0.24, 1.45, seg=4, twist=20, lean=(0.04, 0.0))
    moss = m.piece("Moss", "Moss")
    pad(moss, 0.55, 1.4, -1.45, -0.7, 0.38, 501, thick=0.1, inset=0.06)
    pad(moss, -1.42, -0.6, 0.6, 1.45, 0.38, 502, thick=0.1, inset=0.06)


# ------------------------------------------------------------------ challenge ring

@register("Challenge_Ring", "Events", "Flat ring of inlaid curved stones marking a 24-stud challenge circle (radius 12 "
          "to the stone centre line, 1.1 wide, 0.18 tall) with gold rune ticks and four small Neon markers at the "
          "compass points. Walkable decoration (no collider). Recolour Runes / Glow per state.")
def challenge_ring(m):
    m.extra["palette"] = {"Stone": P("stone_400"), "Stone2": P("stone_500"), "Runes": P("gold_500"),
                          "Marker": P("stone_600"), "Glow": P("gold_300")}
    m.extra["top"] = 0.18
    R0, R1 = 11.45, 12.55
    s1 = m.piece("Stones", "Stone")
    s2 = m.piece("Stones2", "Stone2")
    runes = m.piece("Runes", "Runes")
    rng = random.Random(511)
    n = 28
    step = 360 / n
    for k in range(n):
        a0, a1 = k * step + 0.9, (k + 1) * step - 0.9
        if k % 7 == 0:
            continue  # gaps where the compass markers stand
        h = 0.14 + rng.uniform(-0.02, 0.03)
        annular_block(s1 if k % 3 else s2, R0 + rng.uniform(-0.05, 0.05), R1 + rng.uniform(-0.05, 0.05), a0, a1, -0.04, h,
                      bevel=0.0, mid=True)
        if k % 2 == 1:
            am = (a0 + a1) / 2
            annular_block(runes, (R0 + R1) / 2 - 0.32, (R0 + R1) / 2 + 0.32, am - 1.0, am + 1.0, h - 0.02, h + 0.03,
                          bevel=0.0)
    mk = m.piece("Markers", "Marker")
    glow = m.piece("Glow", "Glow", "Neon")
    for k in range(4):
        am = math.radians(k * 7 * step + step / 2)
        cx, cy = math.cos(am) * (R0 + R1) / 2, math.sin(am) * (R0 + R1) / 2
        rot = math.degrees(am)
        mk.box((1.25, 1.25, 0.26), loc=(cx, cy, 0.09), rot=(0, 0, rot + 45), bevel=0.06)
        runes.box((0.85, 0.85, 0.06), loc=(cx, cy, 0.25), rot=(0, 0, rot + 45), bevel=0.0)
        loft(glow, [ring(4, 0.26, 0.26, phase=math.radians(rot), cx=cx, cy=cy),
                    ring(4, 0.18, 0.34, phase=math.radians(rot), cx=cx, cy=cy)])


# ------------------------------------------------------------------ guarded altar

@register("Guard_Altar", "Events", "Ruined two-step stone altar ~6.4 x 5.6 for the guarded reward chest (chest sits on "
          "the top at the origin, top = 0.9), broken back pillars and a crimson banner with a gold crown on a pole "
          "behind. Front = -Y. Collider = the pillars and the pole only (the platform is a walkable step).")
def guard_altar(m):
    m.extra["palette"] = {"Base": P("stone_600"), "Stone": P("stone_500"), "Stone2": P("stone_400"),
                          "Gold": P("gold_500"), "Cloth": P("crimson_600"), "Wood": P("wood_600"), "Moss": P("moss_400")}
    m.extra["top"] = 0.9
    m.extra["collider"] = {"kind": "multi", "shapes": [
        {"kind": "circle", "radius": 0.85, "height": 3, "offset": roblox_xz(-2.75, 2.25)},
        {"kind": "circle", "radius": 0.85, "height": 2, "offset": roblox_xz(2.75, 2.25)},
        {"kind": "circle", "radius": 0.4, "height": 7, "offset": roblox_xz(0, 2.85)},
    ]}
    rng = random.Random(521)
    base = m.piece("Base", "Base", shadow=True)
    st = m.piece("Stone", "Stone", shadow=True)
    st2 = m.piece("Stone2", "Stone2", shadow=True)
    gold = m.piece("Gold", "Gold")
    moss = m.piece("Moss", "Moss")
    # lower tier: a ring of big slabs, the front-right corner slab knocked askew
    for (x, y, sx, sy, broken) in ((-2.2, -2.15, 2.0, 1.2, False), (0.0, -2.15, 2.3, 1.2, False), (2.25, -2.3, 1.9, 1.05, True),
                                   (-2.45, 0.0, 1.5, 3.0, False), (2.45, 0.05, 1.5, 3.0, False),
                                   (-1.6, 2.2, 3.2, 1.2, False), (1.6, 2.2, 3.2, 1.2, False), (0, 0, 3.4, 3.0, False)):
        rot = (rng.uniform(-1, 1), rng.uniform(-1, 1), rng.uniform(-1.5, 1.5))
        h = 0.48
        z = 0.2
        if broken:
            rot = (6, -9, 14)
            z = 0.12
        base.box((sx - 0.06, sy - 0.06, h), loc=(x, y, z), rot=rot, bevel=0.08)
    # upper tier: four slabs with a gold inlaid border band at the front
    for k, (x, y, sx, sy) in enumerate(((-1.05, -0.8, 2.1, 1.6), (1.05, -0.8, 2.1, 1.6), (-1.05, 0.8, 2.1, 1.6),
                                         (1.05, 0.8, 2.1, 1.6))):
        (st if k in (0, 3) else st2).box((sx - 0.06, sy - 0.06, 0.46), loc=(x, y, 0.66),
                                         rot=(rng.uniform(-0.8, 0.8), rng.uniform(-0.8, 0.8), rng.uniform(-1, 1)), bevel=0.08)
    gold.box((3.6, 0.07, 0.12), loc=(0, -1.63, 0.7), bevel=0.0)
    for x in (-2.06, 2.06):
        gold.box((0.26, 0.26, 0.08), loc=(x, -1.55, 0.92), rot=(0, 0, 45), bevel=0.0)
    # back pillars, broken at two heights
    for x, hgt, seed in ((-2.75, 3.0, 522), (2.75, 1.9, 523)):
        y = 2.25
        st2.box((1.5, 1.5, 0.35), loc=(x, y, 0.55), bevel=0.07)
        r = random.Random(seed)
        top = ring(8, 0.55, hgt, phase=0.2, cx=x, cy=y, zfn=lambda a, i: 0.32 * math.cos(a - 1.0) + r.uniform(-0.1, 0.1))
        loft(st, [ring(8, 0.6, 0.7, phase=0.2, cx=x, cy=y), ring(8, 0.56, hgt - 0.6, phase=0.2, cx=x, cy=y), top])
        gold.box((1.24, 1.24, 0.1), loc=(x, y, 1.25), rot=(0, 0, 22.5), bevel=0.0)
        pts = [p for p in top] + [(px, py, hgt - 0.5) for px, py, _ in ring(8, 0.55, 0, phase=0.2, cx=x, cy=y)]
        from ._propkit import cap_of
        cap_of(moss, pts, plane_co=(x, y, hgt + 0.08), plane_no=(0.3, 0.2, 1.0), grow=1.06, lift=0.02,
               centre=(x, y, hgt - 0.2))
    # banner pole and crimson cloth facing -Y
    wood = m.piece("Pole", "Wood")
    px, py = 0.0, 2.85
    loft(wood, [ring(6, 0.2, -0.1, cx=px, cy=py), ring(6, 0.16, 6.9, cx=px, cy=py)])
    wood.box((2.6, 0.2, 0.2), loc=(px, py, 6.45), bevel=0.04)
    loft(gold, [(px, py, 7.5), ring(4, 0.16, 7.1, phase=math.radians(45), cx=px, cy=py),
                ring(4, 0.12, 6.85, phase=math.radians(45), cx=px, cy=py)])
    for x in (-1.35, 1.35):
        gold.ico(0.12, loc=(px + x, py, 6.45), subdiv=1)
    cloth = m.piece("Banner", "Cloth")
    w, top_z, length, y0 = 2.1, 6.3, 3.6, py - 0.13
    xs = [px - w / 2 + w * i / 6 for i in range(7)]

    def tail(x):
        return top_z - length + 0.5 * (1 - min(1.0, abs(x - px) / (w / 2)))

    def wave(x):
        return 0.05 * math.sin(x * 2.6)
    sheet(cloth, xs, lambda x: top_z, tail, wave, 0.1, y0=y0)
    sheet(gold, xs, lambda x: top_z - 0.2, lambda x: top_z - 0.4, wave, 0.14, y0=y0)
    for side in (-1, 1):
        crown_plate(gold, px, 4.45, y0 - side * 0.02, 0.85, 0.7, depth=0.14, outward=side)
    # moss and rubble
    pad(moss, -3.1, -2.2, -1.2, 0.4, 0.44, 524, thick=0.1, inset=0.08)
    pad(moss, 0.5, 1.5, 1.8, 2.7, 0.44, 525, thick=0.1, inset=0.08)
    pad(moss, -1.9, -0.9, 0.3, 1.3, 0.89, 526, thick=0.08, inset=0.1)
    hull(st2, [(3.55 + x, -1.9 + y, 0.25 + z) for x, y, z in blob_points(527, 10, 0.5, 0.4, 0.3, floor=-0.26)])
    hull(base, [(-3.6 + x, 1.3 + y, 0.2 + z) for x, y, z in blob_points(528, 10, 0.42, 0.36, 0.26, floor=-0.22)])


# ------------------------------------------------------------------ bargain shrine

@register("Shrine_Bargain", "Events", "Bargain shrine (benefit + trade-off): weathered, chipped standing stone on a "
          "cracked plinth with a crimson sigil plate and a gold balance-scale emblem, plus a small offering dish with "
          "a crimson ember. ~3 x 5 x 2.2. Front = -Y. Recolour Sigil / Glow. Collider box; light = ember.")
def shrine_bargain(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Stone2": P("stone_600"), "Base": P("stone_700"), "Sigil": P("crimson_600"),
                          "Gold": P("gold_500"), "Moss": P("moss_400"), "Glow": P("crimson_300"), "Iron": P("steel_700")}
    m.extra["collider"] = {"kind": "box", "size": [3.0, 2.2], "height": 5}
    m.extra["light"] = light_at(0.95, -1.05, 0.95)
    base = m.piece("Plinth", "Base", shadow=True)
    base.box((1.6, 2.1, 0.45), loc=(-0.72, 0, 0.18), rot=(0, 0, 1.5), bevel=0.08)
    base.box((1.35, 2.1, 0.45), loc=(0.82, 0.02, 0.16), rot=(1.5, -2, -2), bevel=0.08)  # cracked in two
    base.box((2.2, 1.45, 0.36), loc=(0, 0.08, 0.56), bevel=0.07)
    stone = m.piece("Stone", "Stone", shadow=True)
    # broken top: the last course is sheared off on a slant (high on the left)
    top = [(x, y, 4.15 - 0.42 * x + 0.08 * y) for x, y, _ in oct_ring(1.22, 0.74, 0, c=0.26)]
    rings = [oct_ring(1.62, 0.95, 0.7), oct_ring(1.58, 0.92, 2.1), oct_ring(1.4, 0.84, 3.4)]
    loft(stone, rings + [top])
    s2 = m.piece("Chip", "Stone2", shadow=True)
    # the sheared-off chunk lies at the foot
    s2.box((0.75, 0.6, 0.5), loc=(1.7, -0.5, 0.25), rot=(8, -14, 30), bevel=0.07)
    hull(s2, [(-1.75 + x, 0.55 + y, 0.18 + z) for x, y, z in blob_points(531, 10, 0.32, 0.28, 0.22, floor=-0.2)])
    moss = m.piece("Moss", "Moss")
    from ._propkit import cap_of
    cap_of(moss, rings[2] + top, plane_co=(-0.1, 0, 4.25), plane_no=(-0.25, 0.1, 1.0), grow=1.05, lift=0.02,
           centre=(0, 0, 3.9))
    # a dark crack running down from the broken top, past the sigil
    crack = [(0.5, 3.95), (0.38, 3.6), (0.47, 3.35), (0.6, 3.05)]
    for (x0, z0), (x1, z1) in zip(crack, crack[1:]):
        L = math.hypot(x1 - x0, z1 - z0)
        ang = math.degrees(math.atan2(z1 - z0, x1 - x0))
        base.box((L + 0.06, 0.06, 0.07), loc=((x0 + x1) / 2, -0.445 + (3.5 - (z0 + z1) / 2) * 0.0, (z0 + z1) / 2),
                 rot=(0, -ang, 0), bevel=0.0)
    # crimson sigil disc sunk into the front face with a gold rim and balance scales
    zc = 2.75
    face = -0.46 + (zc - 2.1) * (0.04 / 1.45)
    yb, yf = face + 0.015, face - 0.05
    sig = m.piece("Sigil", "Sigil")
    prism_xz(sig, [(math.cos(i / 12 * TAU) * 0.5, zc + math.sin(i / 12 * TAU) * 0.5) for i in range(12)], yf, yb)
    gold = m.piece("Gold", "Gold")
    yg0, yg1 = yf - 0.03, yb - 0.02
    for i in range(12):
        a0, a1 = i / 12 * TAU, (i + 1) / 12 * TAU
        pts = []
        for a in (a0, a1):
            for r in (0.5, 0.6):
                for yy in (yb, yf - 0.02):
                    pts.append((math.cos(a) * r, yy, zc + math.sin(a) * r))
        hull(gold, pts)
    gold.box((0.07, yg1 - yg0, 0.56), loc=(0, (yg0 + yg1) / 2, zc - 0.02), bevel=0.0)       # post
    gold.box((0.62, yg1 - yg0, 0.06), loc=(0, (yg0 + yg1) / 2, zc + 0.2), rot=(0, -8, 0), bevel=0.0)  # tilted beam
    prism_xz(gold, [(-0.08, zc + 0.28), (0.08, zc + 0.28), (0.0, zc + 0.38)], yg0, yg1)
    for x, z in ((-0.29, zc + 0.24), (0.29, zc + 0.16)):  # pans hang from the beam ends
        gold.box((0.03, yg1 - yg0, 0.22), loc=(x, (yg0 + yg1) / 2, z - 0.11), bevel=0.0)
        prism_xz(gold, [(x - 0.15, z - 0.24), (x + 0.15, z - 0.24), (x + 0.09, z - 0.32), (x - 0.09, z - 0.32)], yg0, yg1)
    gold.box((0.3, yg1 - yg0, 0.05), loc=(0, (yg0 + yg1) / 2, zc - 0.3), bevel=0.0)
    # gold band on the plinth front
    gold.box((1.4, 0.06, 0.12), loc=(0, -0.66, 0.6), bevel=0.0)
    # offering dish with a small crimson ember
    iron = m.piece("Dish", "Iron", "Metal")
    dx, dy = 0.95, -1.05
    loft(iron, [ring(6, 0.14, 0.0, cx=dx, cy=dy), ring(6, 0.1, 0.5, cx=dx, cy=dy), ring(6, 0.32, 0.72, cx=dx, cy=dy),
                ring(6, 0.38, 0.82, cx=dx, cy=dy), ring(6, 0.3, 0.8, cx=dx, cy=dy)])
    glow = m.piece("Glow", "Glow", "Neon")
    flame(glow, (dx, dy, 0.74), 0.17, 0.42, seg=4, lean=(0.02, 0.0))
