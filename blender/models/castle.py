"""Castle kit for the menu scene (a dusk courtyard): crenellated walls, round towers, the
gatehouse with its portcullis, wall banners, wall torches, a brazier and the hero's dais.

Same conventions as world.py: origin = ground centre unless noted, front = -Y (Roblox -Z),
cool stone in three tones split by piece (Stone / Trim / Base), shadows on the big pieces.
Walls tile every 12 studs along X; towers (radius ~4.2) cover wall ends.
"""

import math
import random

from swarmkit import register
from style import P

from ._propkit import (TAU, annular_block, box, flame, hull, light_at, loft, prism_xz, prism_yz,
                       ring, roblox_xz, sheet, u_shell, voussoir)
from .world import crown_profile

STONE = {"Stone": P("stone_500"), "Trim": P("stone_400"), "Base": P("stone_600")}


def _stone_pieces(m):
    return (m.piece("Wall", "Stone", shadow=True), m.piece("Trim", "Trim", shadow=True),
            m.piece("Base", "Base", shadow=True))


def face_accents(trim, base, seed, x_min, x_max, rows, y_face, avoid=None, per_row=(1, 2), length=(1.2, 2.2)):
    """Scattered ashlar blocks standing slightly proud of a flat front face at y = y_face.
    rows: list of (z0, z1) courses; avoid(x0, x1, z0, z1) -> True skips a block."""
    rng = random.Random(seed)
    for z0, z1 in rows:
        taken = []
        for _ in range(rng.randint(*per_row)):
            for _try in range(8):
                L = rng.uniform(*length)
                cx = rng.uniform(x_min + L / 2, x_max - L / 2)
                x0, x1 = cx - L / 2, cx + L / 2
                if any(x0 < b + 0.3 and x1 > a - 0.3 for a, b in taken):
                    continue
                if avoid and avoid(x0, x1, z0, z1):
                    continue
                taken.append((x0, x1))
                piece = trim if rng.random() < 0.6 else base
                piece.box((L, 0.2, z1 - z0 - 0.08), loc=(cx, y_face - 0.04, (z0 + z1) / 2), bevel=0.05)
                break


def courses(z0, z1, h):
    out, z = [], z0
    while z + h <= z1 + 1e-6:
        out.append((z, z + h))
        z += h
    return out


# ------------------------------------------------------------------ walls

@register("Castle_Wall", "Castle", "Crenellated wall segment, 12 (X) x 10 x 3, front face = -Y. Tiles every 12 studs.")
def castle_wall(m):
    m.extra["palette"] = dict(STONE)
    m.extra["collider"] = {"kind": "box", "size": [12.0, 3.0], "height": 10}
    m.extra["walkway"] = 8.8  # top of the wall-walk (string course)
    wall, trim, base = _stone_pieces(m)
    W = 6.0
    prism_yz(base, [(-1.5, 0.0), (1.5, 0.0), (1.5, 0.75), (1.3, 1.0), (-1.3, 1.0), (-1.5, 0.75)], -W, W)
    wall.box((2 * W - 0.06, 2.6, 7.6), loc=(0, 0, 4.7), bevel=0.0)  # inset ends: no coplanar faces with the mouldings
    prism_yz(trim, [(-1.3, 8.2), (1.3, 8.2), (1.55, 8.42), (1.55, 8.8), (-1.55, 8.8), (-1.55, 8.42)], -W, W)
    for x in (-4.5, -1.5, 1.5, 4.5):
        wall.box((1.9, 0.9, 1.2), loc=(x, -1.05, 9.4), bevel=0.08, taper=(0.96, 0.92))
        wall.box((1.9, 0.6, 0.7), loc=(x, 1.2, 9.15), bevel=0.06)  # low rear parapet blocks
    face_accents(trim, base, 201, -5.5, 5.5, courses(1.05, 8.15, 0.89), -1.3)


# ------------------------------------------------------------------ towers

def tower_body(m, roof):
    wall, trim, base = _stone_pieces(m)
    dark = m.piece("Dark", "Dark")
    n = 16
    loft(base, [ring(n, 4.25, -0.1), ring(n, 4.25, 0.85), ring(n, 4.02, 1.15)])
    loft(wall, [ring(n, 4.0, 1.0), ring(n, 4.0, 12.7)])
    loft(trim, [ring(n, 3.98, 12.0), ring(n, 4.38, 12.75), ring(n, 4.38, 12.95), ring(n, 3.9, 12.95)])
    loft(wall, [ring(n, 4.35, 12.9), ring(n, 4.35, 14.5), ring(n, 3.7, 14.5), ring(n, 3.7, 13.6), (0, 0, 13.6)])
    if not roof:
        for k in range(8):
            a = k * 45 + 22.5
            annular_block(wall, 3.72, 4.38, a - 13.5, a + 13.5, 14.45, 15.9, bevel=0.07)
    # arrow slits on the front (-Y) half, with a lintel and sill on the main one
    for ang, z0, z1 in ((-90, 6.0, 7.6), (-135, 3.2, 4.6), (-45, 9.0, 10.4)):
        a = math.radians(ang)
        cx, cy = math.cos(a) * 4.02, math.sin(a) * 4.02
        dark.box((0.34, 0.12, z1 - z0), loc=(cx, cy, (z0 + z1) / 2), rot=(0, 0, ang + 90), bevel=0.0)
        trim.box((0.8, 0.22, 0.24), loc=(math.cos(a) * 4.06, math.sin(a) * 4.06, z1 + 0.14), rot=(0, 0, ang + 90), bevel=0.0)
        trim.box((0.8, 0.22, 0.2), loc=(math.cos(a) * 4.06, math.sin(a) * 4.06, z0 - 0.12), rot=(0, 0, ang + 90), bevel=0.0)
    # ashlar accents over the front half
    rng = random.Random(211 + roof)
    for z0, z1 in courses(1.25, 11.85, 0.88):
        for _ in range(rng.randint(0, 1) + (1 if z0 < 6 else 0)):
            a = rng.uniform(-165, -15)
            span = rng.uniform(12, 22)
            if any(abs(a - s) < 14 and z0 < sz1 + 0.6 and z1 > sz0 - 0.6 for s, sz0, sz1 in
                   ((-90, 6.0, 7.6), (-135, 3.2, 4.6), (-45, 9.0, 10.4))):
                continue
            annular_block(trim if rng.random() < 0.6 else base, 3.9, 4.1, a - span / 2, a + span / 2,
                          z0 + 0.04, z1 - 0.04, bevel=0.04)
    return wall, trim, base, dark


@register("Castle_Tower", "Castle", "Round tower, radius ~4.2 (parapet 4.4), 16 tall, crenellated top.")
def castle_tower(m):
    m.extra["palette"] = dict(STONE, Dark=P("stone_900"))
    m.extra["collider"] = {"kind": "circle", "radius": 4.25, "height": 16}
    tower_body(m, roof=False)


@register("Castle_TowerRoof", "Castle", "Round tower with a slate cone roof, gold finial and a crimson pennant (~25 tall).")
def castle_tower_roof(m):
    m.extra["palette"] = dict(STONE, Dark=P("stone_900"), Roof=P("slate_600"), RoofTrim=P("slate_400"),
                              Gold=P("gold_500"), Pennant=P("crimson_500"))
    m.extra["collider"] = {"kind": "circle", "radius": 4.25, "height": 16}
    tower_body(m, roof=True)
    n = 16
    roof = m.piece("Roof", "Roof", shadow=True)
    loft(roof, [ring(n, 4.05, 14.25), ring(n, 4.8, 14.25), ring(n, 3.15, 17.6), ring(n, 1.45, 20.7), (0, 0, 23.4)])
    rt = m.piece("RoofTrim", "RoofTrim")
    loft(rt, [ring(n, 4.86, 14.05), ring(n, 4.86, 14.4), ring(n, 4.5, 14.62), ring(n, 4.5, 14.05)])
    gold = m.piece("Finial", "Gold")
    loft(gold, [ring(6, 0.22, 23.0), ring(6, 0.3, 23.35), ring(6, 0.2, 23.6)])
    gold.ico(0.26, loc=(0, 0, 23.85), subdiv=1)
    loft(gold, [ring(4, 0.06, 23.9), ring(4, 0.05, 26.3)])
    pen = m.piece("Pennant", "Pennant")
    prism_xz(pen, [(0.05, 26.15), (1.7, 25.72), (1.15, 25.55), (1.62, 25.36), (0.05, 25.1)], -0.04, 0.04)


# ------------------------------------------------------------------ gatehouse

@register("Castle_Gate", "Castle", "Gatehouse 12 x 13 x 4 with an arched passage (5.2 wide), a raised dark iron "
          "portcullis and a warm-lit doorway. Front = -Y.")
def castle_gate(m):
    m.extra["palette"] = dict(STONE, Dark=P("stone_800"), Iron=P("steel_800"), Warm=P("gold_600"), Flame=P("fx_fire"))
    m.extra["collider"] = {"kind": "box", "size": [12.0, 4.0], "height": 13}
    m.extra["light"] = light_at(0, 0.6, 3.0)  # warm PointLight inside the passage
    m.extra["walkway"] = 10.9
    wall, trim, base = _stone_pieces(m)
    dark = m.piece("Dark", "Dark")
    iron = m.piece("Portcullis", "Iron", "Metal")
    warm = m.piece("Doorway", "Warm")
    lamps = m.piece("Lamps", "Flame", "Neon")
    R, S, D = 2.6, 4.6, 1.8  # arch radius, springline, half depth
    arc_pts = [(math.cos(math.radians(a)) * R, S + math.sin(math.radians(a)) * R) for a in range(180, -1, -12)]
    outline = [(-6.0, 0.0), (-R, 0.0)] + arc_pts + [(R, 0.0), (6.0, 0.0), (6.0, 10.5), (-6.0, 10.5)]
    prism_xz(wall, outline, -D, D)
    # plinth either side of the passage, string course, merlons (front) and a low rear parapet
    for sx in (-1, 1):
        base.box((3.42, 4.1, 1.0), loc=(sx * 4.33, 0, 0.48), bevel=0.08)
    prism_yz(trim, [(-1.8, 10.0), (1.8, 10.0), (2.05, 10.25), (2.05, 10.9), (-2.05, 10.9), (-2.05, 10.25)], -6.1, 6.1)
    for x in (-4.5, -1.5, 1.5, 4.5):
        wall.box((1.9, 0.95, 1.85), loc=(x, -1.55, 11.8), bevel=0.08, taper=(0.96, 0.92))
    wall.box((12.0, 0.6, 0.75), loc=(0, 1.7, 11.25), bevel=0.0)  # low rear parapet
    # voussoir ring and jamb quoins on the front face
    for k in range(9):
        a0, a1 = 180 - k * 20, 180 - (k + 1) * 20
        key = k == 4
        piece = trim if k % 2 == 0 else base
        voussoir(piece, 0, S, R - 0.02, R + (1.25 if key else 0.95), a0 - 0.7, a1 + 0.7,
                 -D - (0.24 if key else 0.16), -D + 0.12, bevel=0.06)
    for sx in (-1, 1):
        for z0, z1, w in ((1.0, 2.25, 1.05), (2.25, 3.45, 0.8), (3.45, 4.6, 1.05)):
            piece = trim if (z0 > 2 and z0 < 3) else base
            piece.box((w, 0.3, z1 - z0 - 0.08), loc=(sx * (R + w / 2), -D - 0.04, (z0 + z1) / 2), bevel=0.03 if z0 > 2 and z0 < 3 else 0.0)
    def near_arch_or_slit(x0, x1, z0, z1):
        arch = (min(abs(x0), abs(x1)) < R + 1.4 or x0 < 0 < x1) and z0 < S + R + 1.5
        slit = any(x0 < sx * 4.4 + 0.5 and x1 > sx * 4.4 - 0.5 for sx in (-1, 1)) and z0 < 8.9 and z1 > 7.1
        return arch or slit
    face_accents(trim, base, 221, -5.6, 5.6, courses(4.9, 9.9, 0.84), -D, avoid=near_arch_or_slit,
                 per_row=(0, 1), length=(1.1, 1.9))
    # passage: dark lining, warm doorway at the back, two small lamps
    inner = [(-R + 0.04, 0.0), (-R + 0.04, S)] + [(math.cos(math.radians(a)) * (R - 0.04), S + math.sin(math.radians(a)) * (R - 0.04))
                                                   for a in range(168, 0, -12)] + [(R - 0.04, S), (R - 0.04, 0.0)]
    outer = [(-R - 0.06, 0.0), (-R - 0.06, S)] + [(math.cos(math.radians(a)) * (R + 0.06), S + math.sin(math.radians(a)) * (R + 0.06))
                                                  for a in range(168, 0, -12)] + [(R + 0.06, S), (R + 0.06, 0.0)]
    u_shell(dark, inner, outer, -D + 0.01, D - 0.01)
    door = [(-R + 0.05, 0.0), (-R + 0.05, S)] + [(math.cos(math.radians(a)) * (R - 0.05), S + math.sin(math.radians(a)) * (R - 0.05))
                                                 for a in range(168, 0, -12)] + [(R - 0.05, S), (R - 0.05, 0.0)]
    prism_xz(warm, door, D - 0.3, D - 0.1)
    for sx in (-1, 1):
        x = sx * (R - 0.18)
        iron.box((0.1, 0.36, 0.5), loc=(sx * (R - 0.06), 0.9, 3.0), bevel=0.0)
        loft(iron, [ring(5, 0.08, 3.05, cx=x, cy=0.9), ring(5, 0.17, 3.3, cx=x, cy=0.9), ring(5, 0.12, 3.32, cx=x, cy=0.9)])
        flame(lamps, (x, 0.9, 3.2), 0.13, 0.45, seg=4)
    # portcullis, raised to 2.4 studs, set 0.7 behind the front face
    py = -D + 0.75
    for x in (-2.2, -1.32, -0.44, 0.44, 1.32, 2.2):
        top = S + math.sqrt(max(0.0, R * R - x * x)) + 0.5
        iron.box((0.17, 0.17, top - 2.75), loc=(x, py, (top + 2.75) / 2), bevel=0.0)
        iron.spike(0.1, 0.42, seg=4, base=(x, py, 2.8), direction=(0, 0, -1))
    for z in (3.25, 4.35, 5.45, 6.5):
        half = R if z <= S else math.sqrt(max(0.0, R * R - (z - S) ** 2))
        iron.box((2 * half + 0.5, 0.13, 0.15), loc=(0, py, z), bevel=0.0)
    iron.box((2 * R + 0.5, 0.2, 0.24), loc=(0, py, 2.86), bevel=0.0)
    # arrow slits beside the arch
    for sx in (-1, 1):
        dark.box((0.32, 0.1, 1.45), loc=(sx * 4.4, -D - 0.03, 8.0), bevel=0.0)


# ------------------------------------------------------------------ banners and fire

@register("Castle_Banner", "Castle", "Hanging wall banner 2.6 x 6, crimson with a gold crown. Origin = top centre of "
          "the cloth on the wall face; it hangs down (-Z) and stands 0.25 off the wall toward -Y.")
def castle_banner(m):
    m.extra["palette"] = {"Cloth": P("crimson_600"), "Gold": P("gold_500"), "Iron": P("steel_700")}
    m.extra["anchor"] = "top centre of the cloth, on the wall face"
    cloth = m.piece("Cloth", "Cloth")
    gold = m.piece("Gold", "Gold")
    rod = m.piece("Rod", "Iron", "Metal")
    hw, y0 = 1.3, -0.15
    xs = [-hw + 2 * hw * i / 8 for i in range(9)]

    def tail(x):
        return -6.0 + 0.8 * min(1.0, abs(x) / hw)

    def wave(x):
        return 0.035 * math.sin(x * 3.1)
    sheet(cloth, xs, lambda x: -0.02, tail, wave, 0.1, y0=y0)
    sheet(gold, xs, lambda x: -0.32, lambda x: -0.56, wave, 0.14, y0=y0)
    sheet(gold, xs, lambda x: tail(x) + 0.44, lambda x: tail(x) + 0.24, wave, 0.14, y0=y0)
    prof = [(x, -2.75 + z) for x, z in crown_profile(1.35, 1.1)]
    prism_xz(gold, prof, y0 - 0.16, y0 + 0.02)
    gold.ico(0.13, loc=(0, y0, -6.05), subdiv=1)
    for x in (-1.6, 1.6):
        gold.ico(0.12, loc=(x, y0, 0.08), subdiv=1)
    loft(rod, [[(x, y0 + math.cos(a) * 0.065, 0.08 + math.sin(a) * 0.065) for a in (i / 6 * TAU for i in range(6))] for x in (-1.5, 1.5)])
    for x in (-1.0, 1.0):
        rod.box((0.1, 0.2, 0.1), loc=(x, -0.08, 0.08), bevel=0.0)


@register("Torch_Wall", "Castle", "Wall sconce torch. Origin = wall mount point (back plate on the wall); it "
          "projects toward -Y and the flame sits ~1.2 above the origin.")
def torch_wall(m):
    m.extra["palette"] = {"Iron": P("steel_700"), "Wood": P("wood_500"), "Wrap": P("leather_700"),
                          "Flame": P("fx_fire"), "Core": P("gold_300")}
    m.extra["light"] = light_at(0, -0.82, 1.3)
    iron = m.piece("Iron", "Iron", "Metal")
    iron.box((0.4, 0.08, 0.8), loc=(0, -0.04, 0), bevel=0.02)
    iron.limb((0, -0.06, -0.22), (0, -0.66, 0.02), 0.05, 0.05, seg=4)
    loft(iron, [ring(6, 0.15, 0.06, cx=0, cy=-0.7), ring(6, 0.15, 0.24, cx=0, cy=-0.7)])
    stick = m.piece("Stick", "Wood")
    stick.limb((0, -0.64, -0.4), (0, -0.8, 0.72), 0.07, 0.1, seg=6)
    wrap = m.piece("Wrap", "Wrap")
    loft(wrap, [ring(6, 0.12, 0.62, cx=0, cy=-0.79), ring(6, 0.16, 0.74, cx=0, cy=-0.79), ring(6, 0.14, 0.96, cx=0, cy=-0.8)])
    fl = m.piece("Flame", "Flame", "Neon")
    flame(fl, (0, -0.8, 0.88), 0.27, 0.85, seg=5, lean=(0.0, -0.04))
    flame(fl, (0.1, -0.74, 0.9), 0.14, 0.5, seg=4, twist=40, lean=(0.08, 0.0))
    flame(fl, (-0.1, -0.86, 0.9), 0.14, 0.55, seg=4, twist=-30, lean=(-0.06, -0.03))
    core = m.piece("FlameCore", "Core", "Neon")
    flame(core, (0, -0.8, 0.95), 0.13, 0.95, seg=4, twist=20)


@register("Brazier", "Castle", "Iron fire bowl on a stone pedestal, ~2 x 3.6, with a flame. Collider circle.")
def brazier(m):
    m.extra["palette"] = {"Stone": P("stone_500"), "Base": P("stone_600"), "Iron": P("steel_700"),
                          "Flame": P("fx_fire"), "Core": P("gold_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.95, "height": 3}
    m.extra["light"] = light_at(0, 0, 3.3)
    ped = m.piece("Pedestal", "Stone", shadow=True)
    base = m.piece("PedestalTrim", "Base", shadow=True)
    q = math.radians(22.5)
    loft(base, [ring(8, 0.98, 0.0, phase=q), ring(8, 0.98, 0.3, phase=q), ring(8, 0.8, 0.45, phase=q)])
    loft(ped, [ring(8, 0.62, 0.4, phase=q), ring(8, 0.56, 1.95, phase=q)])
    loft(base, [ring(8, 0.62, 1.88, phase=q), ring(8, 0.86, 2.08, phase=q), ring(8, 0.86, 2.28, phase=q), ring(8, 0.5, 2.28, phase=q)])
    bowl = m.piece("Bowl", "Iron", "Metal")
    n = 10
    loft(bowl, [ring(n, 0.42, 2.25), ring(n, 0.82, 2.45), ring(n, 1.0, 2.78), ring(n, 1.04, 2.9),
                ring(n, 0.9, 2.9), ring(n, 0.55, 2.66)])
    for k in range(5):
        a = k / 5 * TAU + 0.3
        bowl.spike(0.08, 0.3, seg=3, base=(math.cos(a) * 0.98, math.sin(a) * 0.98, 2.86),
                   direction=(math.cos(a) * 0.35, math.sin(a) * 0.35, 1))
    hull(bowl, [(x, y, 2.7 + z) for x, y, z in
                [(math.cos(a) * 0.82, math.sin(a) * 0.82, 0.0) for a in (i / 7 * TAU for i in range(7))]
                + [(0.25, 0.1, 0.22), (-0.2, -0.15, 0.18), (0.05, 0.3, 0.16)]])  # coals
    fl = m.piece("Flame", "Flame", "Neon")
    flame(fl, (0, 0, 2.75), 0.55, 1.05, seg=6, lean=(0.04, -0.04))
    for k in range(4):
        a = k / 4 * TAU + 0.6
        flame(fl, (math.cos(a) * 0.42, math.sin(a) * 0.42, 2.78), 0.24, 0.62, seg=4, twist=35 * (1 if k % 2 else -1),
              lean=(math.cos(a) * 0.12, math.sin(a) * 0.12))
    core = m.piece("FlameCore", "Core", "Neon")
    flame(core, (0, 0, 2.8), 0.26, 1.2, seg=5, twist=25)


# ------------------------------------------------------------------ dais

@register("Dais", "Castle", "Round two-step stone dais, ~11 diameter. Top surface at 1.2 (extra 'top'); lower step "
          "tread at 0.6. Gold inlay ring on the top.")
def dais(m):
    m.extra["palette"] = {"Core": P("stone_700"), "Rim": P("stone_500"), "Rim2": P("stone_600"), "Rim3": P("stone_400"),
                          "Top": P("stone_300"), "Inlay": P("gold_500")}
    m.extra["top"] = 1.2
    m.extra["step"] = 0.6
    m.extra["collider"] = {"kind": "circle", "radius": 5.5, "height": 1.2}
    core = m.piece("Core", "Core")
    rims = (m.piece("Rim", "Rim", shadow=True), m.piece("Rim2", "Rim2", shadow=True), m.piece("Rim3", "Rim3", shadow=True))
    top = m.piece("Top", "Top")
    inlay = m.piece("Inlay", "Inlay")
    rng = random.Random(231)
    loft(core, [ring(16, 4.28, -0.1), ring(16, 4.28, 0.58)])
    loft(core, [ring(16, 3.3, 0.5), ring(16, 3.3, 1.15)])
    for (r_in, r_out, z0, z1, count, phase, pick) in ((4.2, 5.5, -0.05, 0.6, 12, 0.0, (0, 1)),
                                                       (3.25, 4.35, 0.58, 1.2, 10, 9.0, (2, 0))):
        span = 360 / count
        for k in range(count):
            a0 = phase + k * span + 0.8
            a1 = phase + (k + 1) * span - 0.8
            piece = rims[pick[0]] if (k % 2 == 0) != (rng.random() < 0.2) else rims[pick[1]]
            annular_block(piece, r_in, r_out + rng.uniform(-0.03, 0.03), a0, a1, z0, z1 + rng.uniform(-0.02, 0.0),
                          bevel=0.07)
    loft(top, [ring(24, 3.36, 1.0), ring(24, 3.36, 1.19)])
    loft(inlay, [ring(20, 2.62, 1.17), ring(20, 2.62, 1.215), ring(20, 2.38, 1.215), ring(20, 2.38, 1.17)], loop=True)
    for k in range(4):
        a = k * TAU / 4 + TAU / 8
        x, y = math.cos(a) * 2.5, math.sin(a) * 2.5
        loft(inlay, [ring(4, 0.24, 1.17, cx=x, cy=y, phase=a), ring(4, 0.24, 1.23, cx=x, cy=y, phase=a)])
