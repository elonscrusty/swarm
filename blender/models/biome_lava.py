"""Lava biome kit: basalt rocks and a column-cluster landmark, a glowing lava pool, charred trees,
obsidian crystals, ember vents, a basalt ruin wall, a brimstone altar landmark and ash piles.

Same conventions as world.py: origin = ground centre, front = -Y (Roblox -Z), colours from the
shared palette (basalt_* darks, ash_* greys, lava_* oranges). Glow stays restrained: Neon only on
small cracks, embers and flames; lava surfaces are SmoothPlastic lava_500 with small Neon hot
spots. Extras: collider on deliberate obstacles only, light at glow cores. Lava_Pool is a flat
walkable hazard visual: the game owns the hazard radius.
"""

import math
import random

from swarmkit import register
from style import P, mix

from ._biomekit import block_wall, flat_patch, pad, rock_points, shard
from ._propkit import TAU, blob_points, cap_of, flame, hull, light_at, loft, ring, roblox_xz

CHAR = mix("wood_900", "basalt_800", 0.5)


def seam(piece, pts, w=0.12, z=0.02, h=0.05):
    """Thin glowing crack along a polyline on the ground."""
    for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
        L = math.hypot(x1 - x0, y1 - y0)
        piece.box((L + w, w, h), loc=((x0 + x1) / 2, (y0 + y1) / 2, z), rot=(0, 0, math.degrees(math.atan2(y1 - y0, x1 - x0))),
                  bevel=0.0)


# ------------------------------------------------------------------ rocks and columns

@register("Basalt_Rock", "Lava", "Dark basalt boulder with an ash-dusted top, ~4.6 x 2.8. Collider circle.")
def basalt_rock(m):
    m.extra["palette"] = {"Stone": P("basalt_600"), "Stone2": P("basalt_700"), "Ash": P("ash_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 2.0, "height": 2.8}
    main = rock_points(801, 16, 2.1, 1.65, 1.4, -0.2, 0.1, 1.15, floor=-1.2, jitter=0.2)
    hull(m.piece("Rock", "Stone", shadow=True), main)
    side = rock_points(802, 11, 1.0, 0.9, 0.75, 1.5, -0.6, 0.5, floor=-0.6, jitter=0.2)
    hull(m.piece("Rock2", "Stone2", shadow=True), side)
    cap_of(m.piece("Ash", "Ash"), main, plane_co=(-0.3, 0.2, 1.95), plane_no=(-0.2, 0.3, 1.0), grow=1.03, lift=0.02,
           centre=(-0.2, 0.1, 1.15))


@register("Basalt_Column", "Lava", "Landmark cluster of hexagonal basalt columns, 2.5 to 9.5 tall, ~7 x 6, with pale "
          "tops that read from above. Collider circle.")
def basalt_column(m):
    m.extra["palette"] = {"Col": P("basalt_700"), "Col2": P("basalt_600"), "Top": P("basalt_500"), "Ash": P("ash_400")}
    m.extra["collider"] = {"kind": "circle", "radius": 3.0, "height": 9}
    c1 = m.piece("Columns", "Col", shadow=True)
    c2 = m.piece("Columns2", "Col2", shadow=True)
    top = m.piece("Tops", "Top")
    cols = [(0.0, 0.3, 0.85, 9.5), (1.55, 0.6, 0.8, 7.6), (-1.5, 0.9, 0.8, 8.2), (0.8, -1.2, 0.75, 6.2), (-0.75, -1.3, 0.75, 5.0),
            (2.6, -0.8, 0.7, 4.2), (-2.7, -0.4, 0.7, 3.4), (0.3, 2.0, 0.75, 6.8), (2.3, 2.1, 0.65, 3.0), (-2.2, 2.3, 0.65, 4.6),
            (-1.7, -2.6, 0.6, 2.2), (1.9, -2.7, 0.55, 1.6)]
    rng = random.Random(811)
    for k, (x, y, r, h) in enumerate(cols):
        ph = rng.uniform(0, TAU / 6)
        tilt = rng.uniform(-0.12, 0.12)
        pc = c1 if k % 2 == 0 else c2
        loft(pc, [ring(6, r, -0.1, phase=ph, cx=x, cy=y), ring(6, r * 0.97, h - 0.12, phase=ph, cx=x + tilt, cy=y)])
        loft(top, [ring(6, r * 0.97, h - 0.14, phase=ph, cx=x + tilt, cy=y),
                   ring(6, r * 0.88, h + rng.uniform(-0.05, 0.12), phase=ph, cx=x + tilt, cy=y)])
    ash = m.piece("Ash", "Ash")
    for x, y, rx, s in ((-3.2, 1.4, 1.0, 812), (3.2, 0.8, 0.9, 813), (0.2, -3.2, 1.1, 814)):
        hull(ash, [(x + px, y + py, pz - 0.03) for px, py, pz in blob_points(s, 10, rx, rx * 0.7, 0.35, floor=0.0)])


# ------------------------------------------------------------------ hazard and glow props

@register("Lava_Pool", "Lava", "Flat lava pool ~8.6 x 7.8, 0.22 tall: basalt crust rim, molten surface, drifting crust "
          "plates and small Neon hot spots. Hazard visual (hazard radius ~3.6). Walkable decoration; light = centre.")
def lava_pool(m):
    m.extra["palette"] = {"Rim": P("basalt_800"), "Rim2": P("basalt_600"), "Lava": P("lava_500"), "Deep": P("lava_700"),
                          "Crust": P("basalt_700"), "Glow": P("lava_glow")}
    m.extra["light"] = light_at(0, 0, 0.6)
    flat_patch(m.piece("Rim", "Rim"), 0, 0, 4.3, 3.9, -0.03, 0.14, 821, n=15, wobble=0.1, top_scale=0.94)
    flat_patch(m.piece("Lava", "Lava"), 0.1, 0.0, 3.65, 3.25, 0.0, 0.17, 822, n=14, wobble=0.1)
    flat_patch(m.piece("Deep", "Deep"), -0.6, 0.5, 1.4, 1.0, 0.1, 0.18, 823, n=9, wobble=0.18)
    crust = m.piece("Crust", "Crust")
    for x, y, r, s in ((1.2, 1.0, 0.75, 824), (-1.6, -1.1, 0.6, 825), (1.9, -1.0, 0.45, 826), (-0.2, 2.0, 0.5, 827),
                       (0.3, -0.6, 0.38, 828)):
        flat_patch(crust, x, y, r, r * 0.8, 0.12, 0.22, s, n=6, wobble=0.25, top_scale=0.85)
    glow = m.piece("Glow", "Glow", "Neon")
    for x, y, r, s in ((0.0, 0.1, 0.55, 829), (-1.1, 0.9, 0.32, 830), (1.4, -0.2, 0.28, 831)):
        flat_patch(glow, x, y, r, r * 0.8, 0.15, 0.2, s, n=6, wobble=0.2)
    rim2 = m.piece("RimStones", "Rim2")
    for x, y, s, seed in ((-4.0, 1.4, 0.55, 832), (3.7, -2.0, 0.5, 833), (2.9, 2.8, 0.4, 834), (-2.6, -3.1, 0.42, 835)):
        hull(rim2, rock_points(seed, 9, s * 1.2, s, s * 0.8, x, y, s * 0.4, floor=-s * 0.4, jitter=0.22))


@register("Charred_Tree", "Lava", "Dead charred tree ~9 tall with bare forked limbs (reads as a dark star from above) "
          "and a few ember glints. Collider = trunk.")
def charred_tree(m):
    m.extra["palette"] = {"Bark": CHAR, "Bark2": P("basalt_700"), "Ember": P("lava_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 0.9, "height": 8}
    from .world import trunk
    bark = m.piece("Trunk", "Bark", shadow=True)
    trunk(bark, 6.2, 0.7, 0.32, seed=841, sides=6, lean=(0.3, 0.1), flare=0.35, roots=4, root_len=1.0)
    b2 = m.piece("Limbs", "Bark2", shadow=True)
    rng = random.Random(842)
    tips = []
    for k in range(5):
        a = k / 5 * TAU + rng.uniform(-0.3, 0.3)
        z0 = rng.uniform(3.6, 5.8)
        base = (0.3 * (z0 / 6.2) ** 2, 0.1 * (z0 / 6.2) ** 2, z0)
        L = rng.uniform(2.3, 3.2)
        mid = (base[0] + math.cos(a) * L * 0.6, base[1] + math.sin(a) * L * 0.6, z0 + L * 0.55)
        b2.limb(base, mid, 0.24, 0.13, seg=5)
        for da in (-0.45, 0.4):
            tip = (mid[0] + math.cos(a + da) * L * 0.5, mid[1] + math.sin(a + da) * L * 0.5, mid[2] + L * rng.uniform(0.25, 0.5))
            b2.limb(mid, tip, 0.12, 0.02, seg=4)
            tips.append(tip)
    b2.limb((0.3, 0.1, 6.0), (0.5, 0.0, 8.9), 0.22, 0.03, seg=5)
    em = m.piece("Embers", "Ember", "Neon")
    for x, y, z in ((0.55, -0.45, 1.3), (-0.5, -0.35, 2.4), (0.15, -0.6, 3.6)):
        em.box((0.1, 0.08, 0.38), loc=(x, y, z), rot=(0, 12, 0), bevel=0.0)


@register("Obsidian_Crystal", "Lava", "Cluster of black glassy obsidian shards with a small ember core, ~2.8 x 3.2. "
          "Collider circle; light = core.")
def obsidian_crystal(m):
    m.extra["palette"] = {"Base": P("basalt_700"), "Obsidian": P("basalt_900"), "Obsidian2": mix("basalt_800", "slate_600", 0.4),
                          "Glow": P("lava_300")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.3, "height": 3}
    m.extra["light"] = light_at(0.1, -0.35, 0.7)
    hull(m.piece("Base", "Base"), [(x, y, 0.2 + z) for x, y, z in blob_points(851, 14, 1.45, 1.25, 0.45, floor=-0.32)])
    o1 = m.piece("Shards", "Obsidian", "Metal")
    o2 = m.piece("Shards2", "Obsidian2", "Metal")
    shard(o1, (0.0, 0.15, 0.2), 3.0, 0.45, (-6, 5), 12, sides=5)
    shard(o2, (0.65, 0.35, 0.2), 2.0, 0.32, (-18, 24), 40, sides=5)
    shard(o1, (-0.7, 0.3, 0.2), 1.9, 0.32, (-12, -28), 5, sides=5)
    shard(o2, (-0.3, -0.6, 0.2), 1.3, 0.26, (26, -10), 25, sides=5)
    shard(o1, (0.85, -0.45, 0.2), 1.1, 0.24, (22, 30), 15, sides=5)
    shard(m.piece("Glow", "Glow", "Neon"), (0.1, -0.35, 0.3), 0.7, 0.11, (18, 10), 0, sides=5)


@register("Ember_Vent", "Lava", "Small basalt fumarole ~2.8 wide, 1.3 tall, with a glowing mouth, a flame lick and an "
          "ash ring. Collider circle; light = mouth.")
def ember_vent(m):
    m.extra["palette"] = {"Rock": P("basalt_700"), "Ash": P("ash_400"), "Glow": P("lava_300"), "Core": P("lava_glow")}
    m.extra["collider"] = {"kind": "circle", "radius": 1.2, "height": 1.3}
    m.extra["light"] = light_at(0, 0, 1.4)
    rock = m.piece("Cone", "Rock", shadow=True)
    loft(rock, [ring(8, 1.45, -0.05, wobble=0.12, seed=861), ring(8, 0.95, 0.6, phase=0.2, wobble=0.1, seed=862),
                ring(8, 0.55, 1.2, phase=0.4, wobble=0.08, seed=863), ring(8, 0.36, 1.15, phase=0.4), ring(8, 0.3, 0.8, phase=0.4)])
    ash = m.piece("Ash", "Ash")
    for k in range(4):
        a = k / 4 * TAU + 0.5
        x, y = math.cos(a) * 1.6, math.sin(a) * 1.4
        hull(ash, [(x + px, y + py, pz - 0.03) for px, py, pz in blob_points(864 + k, 9, 0.6, 0.45, 0.22, floor=0.0)])
    glow = m.piece("Mouth", "Glow", "Neon")
    loft(glow, [ring(8, 0.32, 0.85, phase=0.4), ring(8, 0.32, 0.95, phase=0.4)])
    core = m.piece("Flame", "Core", "Neon")
    flame(core, (0, 0, 0.95), 0.22, 0.9, seg=4, twist=25, lean=(0.06, 0.02))


# ------------------------------------------------------------------ ruins and landmark

@register("Lava_Ruin_Wall", "Lava", "Broken dark basalt-block wall with ash on the tops and glowing seams at its foot, "
          "8 x 3.5 x 1.4 (length along X). Collider box.")
def lava_ruin_wall(m):
    m.extra["palette"] = {"Stone": P("basalt_600"), "Stone2": P("basalt_500"), "Stone3": P("basalt_700"), "Ash": P("ash_300"),
                          "Glow": P("lava_300")}
    m.extra["collider"] = {"kind": "box", "size": [8.0, 1.4], "height": 3.5}
    tones = [m.piece("Stone", "Stone", shadow=True), m.piece("Stone2", "Stone2", shadow=True),
             m.piece("Stone3", "Stone3", shadow=True)]
    ash = m.piece("Ash", "Ash")

    def standing(x):
        return 4 if x < -2.4 else 3 if x < 0.6 else 2 if x < 2.4 else 1
    block_wall(m, tones, ash, 8.0, 1.4, [0.95, 0.9, 0.85, 0.8], standing, seed=871, cap_chance=0.7, cap_thick=0.12,
               fallen=[((3.15, -1.15, 0.3), (1.1, 0.8, 0.62), (6, -8, 28)), ((1.9, 1.15, 0.24), (0.85, 0.7, 0.5), (0, 10, -16))])
    glow = m.piece("Seams", "Glow", "Neon")
    seam(glow, [(-3.8, -0.95), (-2.4, -0.8), (-1.6, -1.15), (-0.2, -0.9)])
    seam(glow, [(1.0, 0.85), (2.2, 1.05), (3.6, 0.8)], w=0.1)


@register("Brimstone_Altar", "Lava", "Landmark brimstone altar ~8.6 wide: two-step octagonal basalt dais with glowing lava "
          "channels, four curved obsidian horns, a gold-rimmed fire bowl with a big flame. Front = -Y. Collider = the "
          "bowl pedestal and the horns; light = flame.")
def brimstone_altar(m):
    m.extra["palette"] = {"Base": P("basalt_700"), "Base2": P("basalt_600"), "Horn": P("basalt_900"), "Gold": P("gold_500"),
                          "Iron": P("steel_800"), "Glow": P("lava_300"), "Flame": P("fx_fire"), "Core": P("lava_glow"),
                          "Ash": P("ash_400")}
    horns = [(math.cos(math.radians(45 + 90 * k)) * 3.4, math.sin(math.radians(45 + 90 * k)) * 3.4) for k in range(4)]
    m.extra["collider"] = {"kind": "multi", "shapes": [{"kind": "circle", "radius": 1.4, "height": 4,
                                                        "offset": roblox_xz(0, 0)}] +
                           [{"kind": "circle", "radius": 0.6, "height": 4, "offset": roblox_xz(x, y)} for x, y in horns]}
    m.extra["light"] = light_at(0, 0, 4.0)
    m.extra["top"] = 0.95
    ph = TAU / 16
    base = m.piece("Dais", "Base", shadow=True)
    base2 = m.piece("Dais2", "Base2", shadow=True)
    loft(base, [ring(8, 4.6, -0.05, phase=ph), ring(8, 4.6, 0.45, phase=ph), ring(8, 4.45, 0.52, phase=ph)])
    loft(base2, [ring(8, 3.5, 0.45, phase=ph), ring(8, 3.5, 0.92, phase=ph), ring(8, 3.38, 0.98, phase=ph)])
    # lava channels: thin glowing grooves running from the bowl to the dais edge (front and sides)
    glow = m.piece("Channels", "Glow", "Neon")
    for k in range(8):
        a = math.radians(k * 45 + 22.5)
        r0, r1 = 1.4, 3.35
        glow.box((r1 - r0, 0.16, 0.06), loc=(math.cos(a) * (r0 + r1) / 2, math.sin(a) * (r0 + r1) / 2, 0.99),
                 rot=(0, 0, math.degrees(a)), bevel=0.0)
    gold = m.piece("Gold", "Gold")
    loft(gold, [ring(8, 3.52, 0.8, phase=ph), ring(8, 3.52, 0.9, phase=ph)])
    # pedestal and bowl
    loft(base2, [ring(8, 1.25, 0.95, phase=ph), ring(8, 1.0, 1.4, phase=ph), ring(8, 0.7, 2.4, phase=ph), ring(8, 0.9, 2.6, phase=ph)])
    iron = m.piece("Bowl", "Iron", "Metal")
    loft(iron, [ring(8, 0.8, 2.55, phase=ph), ring(8, 1.4, 3.0, phase=ph), ring(8, 1.55, 3.25, phase=ph),
                ring(8, 1.35, 3.25, phase=ph), ring(8, 1.05, 3.0, phase=ph)])
    loft(gold, [ring(8, 1.58, 3.18, phase=ph), ring(8, 1.6, 3.3, phase=ph), ring(8, 1.4, 3.32, phase=ph)])
    fl = m.piece("Flame", "Flame", "Neon")
    flame(fl, (0, 0, 2.9), 0.75, 2.2, seg=5, lean=(0.08, -0.04))
    flame(fl, (0.45, 0.25, 2.95), 0.4, 1.3, seg=4, twist=40, lean=(0.2, 0.08))
    flame(fl, (-0.45, -0.2, 2.95), 0.4, 1.4, seg=4, twist=-30, lean=(-0.18, -0.06))
    flame(fl, (0.05, 0.5, 2.95), 0.36, 1.1, seg=4, twist=15, lean=(0.0, 0.18))
    flame(m.piece("FlameCore", "Core", "Neon"), (0, 0, 3.0), 0.36, 2.3, seg=4, twist=20, lean=(0.05, 0.0))
    # four curved obsidian horns at the diagonals, curling inward
    horn = m.piece("Horns", "Horn", "Metal")
    for x, y in horns:
        d = math.hypot(x, y)
        ix, iy = -x / d, -y / d
        pts = [(x, y, 0.4), (x - ix * 0.15, y - iy * 0.15, 1.8), (x + ix * 0.15, y + iy * 0.15, 3.0), (x + ix * 0.85, y + iy * 0.85, 3.9)]
        for (p, q), (r0, r1) in zip(zip(pts, pts[1:]), ((0.55, 0.42), (0.42, 0.26), (0.26, 0.02))):
            horn.limb(p, q, r0, r1, seg=6)
    ash = m.piece("Ash", "Ash")
    pad(ash, -4.0, -2.9, -1.2, 0.6, 0.48, 881, thick=0.1, inset=0.1)
    pad(ash, 2.8, 4.0, 0.3, 1.6, 0.48, 882, thick=0.1, inset=0.1)


@register("Ash_Pile", "Lava", "Grey ash heap with charcoal chunks and two tiny embers, ~3 x 2.2 x 0.9. Decoration "
          "(no collider).")
def ash_pile(m):
    m.extra["palette"] = {"Ash": P("ash_400"), "Ash2": P("ash_300"), "Char": P("basalt_900"), "Ember": P("lava_300")}
    ash = m.piece("Ash", "Ash")
    ash2 = m.piece("Ash2", "Ash2")
    for x, y, rx, ry, h, seed in ((0.0, 0.0, 1.2, 0.95, 0.75, 891), (1.0, 0.45, 0.8, 0.7, 0.5, 896), (-1.05, -0.3, 0.75, 0.6, 0.42, 897)):
        pts = [(x + px, y + py, pz - 0.03) for px, py, pz in blob_points(seed, 14, rx, ry, h, jitter=0.18, floor=0.0)]
        hull(ash, pts)
        cap_of(ash2, pts, plane_co=(x, y, h * 0.6), plane_no=(0.3, -0.3, 1.0), grow=1.03, lift=0.01, centre=(x, y, h * 0.3))
    ch = m.piece("Char", "Char")
    for x, y, s, seed in ((1.3, -0.6, 0.3, 892), (-1.2, 0.5, 0.25, 893), (0.4, 0.9, 0.22, 894), (-0.6, -0.95, 0.2, 895)):
        hull(ch, rock_points(seed, 8, s * 1.4, s, s * 0.7, x, y, s * 0.4, floor=-s * 0.4))
    em = m.piece("Embers", "Ember", "Neon")
    em.ico(0.09, loc=(1.25, -0.75, 0.32), subdiv=0)
    em.ico(0.08, loc=(-0.25, -0.75, 0.62), subdiv=0)
